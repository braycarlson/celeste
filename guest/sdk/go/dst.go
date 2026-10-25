package dst

import (
    "encoding/binary"
    "errors"
    "fmt"
    "hash/crc32"
    "os"
    "os/exec"
    "runtime"
    "strconv"
    "strings"
    "syscall"
    "time"
)

const (
    agent_module      = "dst.agent"
    console_path      = "/dev/console"
    control_event_due = 5
    control_event_wait = 3
    control_port       = 0x505
    control_power_loss = 1
    control_ready      = 2
    details_separator  = " | "
    draw_latch         = 1
    draw_port          = 0x5e0
    entropy_path       = "/dev/urandom"
    event_magic        = 0x31544e5645545344
    event_port         = 0x510
    event_words        = 22
    guidance_port      = 0x5f4
    lock_path          = "/dev/shm/dst-draw"
    message_max        = 1024
    oom_immune_text    = "-1000"
    oom_path           = "/proc/self/oom_score_adj"
    port_path          = "/dev/port"
    quiet_path         = "/dev/shm/dst-quiet"
    quiet_poll         = 50 * time.Millisecond
    quiet_polls_max    = 12000
    reseed_crng        = 0x5207
    seed_port          = 0x508
)

const Err_event_magic event_error = "the event ports read a magic that is not the contract's"
const Err_event_field event_error = "an event field is out of its enumeration"

type Event struct {
    Words [event_words]uint64
}

type Kind int

const (
    Kind_always Kind = iota
    Kind_maximize
    Kind_reachable
    Kind_sometimes
    Kind_unreachable
)

type Reporter struct {
    seen map[string]bool
}

type event_error string

func (kind Kind) name() string {
    switch kind {
    case Kind_always:
        return "always"
    case Kind_maximize:
        return "maximize"
    case Kind_reachable:
        return "reachable"
    case Kind_sometimes:
        return "sometimes"
    case Kind_unreachable:
        return "unreachable"
    default:
        panic("unreachable: unexpected property kind")
    }
}

func (failure event_error) Error() string {
    return string(failure)
}

func (event Event) Kind() uint64 {
    return event.Words[0]
}

func (event Event) Delay_ns() uint64 {
    return event.Words[1]
}

func (event Event) Render() (string, error) {
    var text strings.Builder

    for index, name := range event_fields() {
        word := event.Words[index]
        separator := " "

        if index == 0 {
            separator = ""
        }

        names := event_names(name)

        switch {
        case names != nil:
            if word >= uint64(len(names)) {
                return "", fmt.Errorf("%w: %s=%d", Err_event_field, name, word)
            }

            fmt.Fprintf(&text, "%s%s=%s", separator, name, names[word])
        case event_signed(index):
            fmt.Fprintf(&text, "%s%s=%d", separator, name, int64(word))
        default:
            fmt.Fprintf(&text, "%s%s=%d", separator, name, word)
        }
    }

    return text.String(), nil
}

func (reporter *Reporter) report(line string) error {
    if reporter.seen == nil {
        reporter.seen = make(map[string]bool, 64)
    }

    if reporter.seen[line] {
        return nil
    }

    if err := Console(line); err != nil {
        return err
    }

    reporter.seen[line] = true

    return nil
}

func (reporter *Reporter) Always(condition bool, message string, details string) error {
    outcome := "FAIL"
    suffix := details

    if condition {
        outcome = "PASS"
        suffix = ""
    }

    return reporter.report(line_build("DST ALWAYS ", outcome, message, suffix))
}

func (reporter *Reporter) Eventually(condition bool, message string, details string) error {
    if err := reporter.Always(condition, message, details); err != nil {
        return err
    }

    if condition {
        return Console("DST EVENTUALLY PASS")
    }

    return Console("DST EVENTUALLY FAIL")
}

func (reporter *Reporter) Never(message string, details string) error {
    return reporter.report(line_build("DST UNREACHABLE ", "", message, details))
}

func (reporter *Reporter) Reachable(message string) error {
    return reporter.report(line_build("DST REACHABLE ", "", message, ""))
}

func (reporter *Reporter) Sometimes(condition bool, message string) error {
    if !condition {
        return nil
    }

    return reporter.report(line_build("DST SOMETIMES ", "", message, ""))
}

func directions() []string {
    return []string{"both", "requests", "replies"}
}

func event_fields() [event_words]string {
    return [event_words]string{
        "kind",
        "delay_ns",
        "duration_ns",
        "target",
        "choice",
        "restart",
        "restart_delay_ns",
        "clock_jump_ns",
        "clock_slew_ppm",
        "disk_full_slack_kib",
        "memory_immune",
        "memory_kills",
        "network_delay_ns",
        "network_direction",
        "network_jitter_ns",
        "network_link",
        "network_loss_permille",
        "network_peers",
        "network_reorder_permille",
        "pause_tree",
        "thread_choice",
        "throttle_permille",
    }
}

func event_names(name string) []string {
    switch name {
    case "kind":
        return kinds()
    case "target":
        return targets()
    case "network_direction":
        return directions()
    case "network_link":
        return links()
    default:
        return nil
    }
}

func event_read(command byte) (Event, error) {
    var bytes [(event_words + 1) * 8]byte
    var event Event

    if err := exchange(control_port, command, event_port, bytes[:]); err != nil {
        return event, err
    }

    magic := binary.LittleEndian.Uint64(bytes[:8])

    if magic != event_magic {
        return event, fmt.Errorf("%w: %#x", Err_event_magic, magic)
    }

    for index := range event.Words {
        start := (index + 1) * 8

        event.Words[index] = binary.LittleEndian.Uint64(bytes[start : start+8])
    }

    return event, nil
}

func event_signed(index int) bool {
    switch index {
    case 7, 8:
        return true
    default:
        return false
    }
}

func exchange(command_port int64, command byte, read_port int64, out []byte) (err error) {
    lock, err := lock_take()
    if err != nil {
        return err
    }
    defer func() {
        err = errors.Join(err, lock_drop(lock))
    }()

    port, err := os.OpenFile(port_path, os.O_RDWR, 0)
    if err != nil {
        return err
    }
    defer func() {
        err = errors.Join(err, port.Close())
    }()

    if _, err := port.WriteAt([]byte{command}, command_port); err != nil {
        return err
    }

    if _, err := port.ReadAt(out, read_port); err != nil {
        return err
    }

    return nil
}

func kinds() []string {
    return []string{
        "none",
        "clock_jump",
        "clock_slew",
        "disk_full",
        "kill",
        "memory",
        "network",
        "pause",
        "thread_pause",
        "throttle",
    }
}

func line_build(prefix string, outcome string, message string, details string) string {
    var line strings.Builder

    line.WriteString(prefix)

    if outcome != "" {
        line.WriteString(outcome)
        line.WriteByte(' ')
    }

    line.WriteString(message_clean(message))

    if details != "" {
        line.WriteString(details_separator)
        line.WriteString(details)
    }

    return line.String()
}

func links() []string {
    return []string{"none", "postgres", "rabbitmq", "redis"}
}

func lock_drop(lock int) error {
    return errors.Join(syscall.Flock(lock, syscall.LOCK_UN), syscall.Close(lock))
}

func lock_take() (int, error) {
    lock, err := syscall.Open(lock_path, syscall.O_RDWR|syscall.O_CREAT|syscall.O_CLOEXEC, 0o666)
    if err != nil {
        return -1, fmt.Errorf("open %s: %w", lock_path, err)
    }

    if err := syscall.Flock(lock, syscall.LOCK_EX); err != nil {
        return -1, errors.Join(err, syscall.Close(lock))
    }

    return lock, nil
}

func message_clean(message string) string {
    joined := strings.Join(strings.Fields(message), " ")

    if len(joined) > message_max {
        panic("a message holds at most 1024 bytes")
    }

    return strings.ReplaceAll(joined, "|", "/")
}

func targets() []string {
    return []string{
        "none",
        "celery_worker",
        "gunicorn_worker",
        "postgres_backend",
        "postmaster",
        "rabbitmq",
        "redis_server",
        "workload",
        "containerd",
        "dockerd",
    }
}

func write_locked(port_first int64, bytes []byte) (err error) {
    lock, err := lock_take()
    if err != nil {
        return err
    }
    defer func() {
        err = errors.Join(err, lock_drop(lock))
    }()

    port, err := os.OpenFile(port_path, os.O_WRONLY, 0)
    if err != nil {
        return err
    }
    defer func() {
        err = errors.Join(err, port.Close())
    }()

    _, err = port.WriteAt(bytes, port_first)

    return err
}

func Ack(identifier string) error {
    return Console("DST ACK " + identifier)
}

func Agent_spawn() error {
    agent := exec.Command("python3", "-m", agent_module)

    agent.Stdout = os.Stdout
    agent.Stderr = os.Stderr

    return agent.Start()
}

func Below(limit uint64) (uint64, error) {
    word, err := Random()
    if err != nil {
        return 0, err
    }

    return Word_below(word, limit), nil
}

func Boolean() (bool, error) {
    word, err := Random()
    if err != nil {
        return false, err
    }

    return Word_boolean(word), nil
}

func Checked() error {
    return Console("DST CHECK DONE")
}

func Console(line string) (err error) {
    Coverage_scan()

    console, err := os.OpenFile(console_path, os.O_WRONLY|syscall.O_NOCTTY, 0)
    if err != nil {
        return err
    }
    defer func() {
        err = errors.Join(err, console.Close())
    }()

    _, err = console.WriteString(line + "\n")

    return err
}

func Control(command byte) (err error) {
    port, err := os.OpenFile(port_path, os.O_WRONLY, 0)
    if err != nil {
        return err
    }
    defer func() {
        err = errors.Join(err, port.Close())
    }()

    _, err = port.WriteAt([]byte{command}, control_port)

    return err
}

func Cpus_count() int {
    return max(runtime.NumCPU(), 1)
}

func Declare(properties map[string]Kind, order []string) error {
    for _, message := range order {
        kind, declared := properties[message]

        if !declared {
            panic("a declared message must be in the property table")
        }

        if err := Console(line_build("DST DECLARE ", kind.name(), message, "")); err != nil {
            return err
        }
    }

    return nil
}

func Entropy_mix(value uint64) (err error) {
    pool, err := os.OpenFile(entropy_path, os.O_WRONLY, 0)
    if err != nil {
        return err
    }
    defer func() {
        err = errors.Join(err, pool.Close())
    }()

    var bytes [8]byte

    binary.LittleEndian.PutUint64(bytes[:], value)

    if _, err := pool.Write(bytes[:]); err != nil {
        return err
    }

    _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, pool.Fd(), reseed_crng, 0)

    if errno != 0 {
        return errno
    }

    return nil
}

func Event_due() (Event, error) {
    return event_read(control_event_due)
}

func Event_wait() (uint64, error) {
    event, err := event_read(control_event_wait)
    if err != nil {
        return 0, err
    }

    return event.Delay_ns(), nil
}

func Eventually_ns() uint64 {
    value, err := strconv.ParseUint(os.Getenv("DST_EVENTUALLY_NS"), 10, 64)
    if err != nil {
        return 0
    }

    return value
}

func Maximize(message string, value uint64) error {
    var bytes [12]byte

    binary.LittleEndian.PutUint32(bytes[:4], crc32.ChecksumIEEE([]byte(message_clean(message))))
    binary.LittleEndian.PutUint64(bytes[4:], value)

    return write_locked(guidance_port, bytes[:])
}

func Oom_immune() error {
    return os.WriteFile(oom_path, []byte(oom_immune_text), 0o644)
}

func Power_loss() error {
    return Control(control_power_loss)
}

func Present(identifier string) error {
    return Console("DST PRESENT " + identifier)
}

func Quiet_wait() bool {
    for poll := 0; poll < quiet_polls_max; poll++ {
        if _, err := os.Stat(quiet_path); err == nil {
            return true
        }

        time.Sleep(quiet_poll)
    }

    return false
}

func Random() (uint64, error) {
    var bytes [8]byte

    Coverage_scan()

    if err := exchange(draw_port, draw_latch, draw_port+1, bytes[:]); err != nil {
        return 0, err
    }

    return binary.LittleEndian.Uint64(bytes[:]), nil
}

func Ready(agent bool) (uint64, error) {
    if err := Console(fmt.Sprintf("DST CPUS %d", Cpus_count())); err != nil {
        return 0, err
    }

    if err := Control(control_ready); err != nil {
        return 0, err
    }

    run_seed, err := Seed()
    if err != nil {
        return 0, err
    }

    if err := Entropy_mix(run_seed); err != nil {
        return 0, err
    }

    if err := Oom_immune(); err != nil {
        return 0, err
    }

    if agent {
        if err := Agent_spawn(); err != nil {
            return 0, err
        }
    }

    return run_seed, nil
}

func Seed() (value uint64, err error) {
    var bytes [8]byte

    port, err := os.OpenFile(port_path, os.O_RDONLY, 0)
    if err != nil {
        return 0, err
    }
    defer func() {
        err = errors.Join(err, port.Close())
    }()

    if _, err := port.ReadAt(bytes[:], seed_port); err != nil {
        return 0, err
    }

    return binary.LittleEndian.Uint64(bytes[:]), nil
}

func Word_below(word uint64, limit uint64) uint64 {
    if limit == 0 {
        panic("a draw below zero has no value to return")
    }

    high, _ := multiply_high(word, limit)

    if high >= limit {
        panic("a mapped word must stay below its limit")
    }

    return high
}

func Word_boolean(word uint64) bool {
    return word>>63 == 1
}

func multiply_high(a uint64, b uint64) (uint64, uint64) {
    a_low := a & 0xffffffff
    a_high := a >> 32
    b_low := b & 0xffffffff
    b_high := b >> 32
    low_low := a_low * b_low
    low_high := a_low * b_high
    high_low := a_high * b_low
    high_high := a_high * b_high
    middle := (low_low >> 32) + (low_high & 0xffffffff) + (high_low & 0xffffffff)
    high := high_high + (low_high >> 32) + (high_low >> 32) + (middle >> 32)
    low := (middle << 32) | (low_low & 0xffffffff)

    return high, low
}
