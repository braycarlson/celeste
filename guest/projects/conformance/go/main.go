package main

import (
    "bufio"
    "errors"
    "fmt"
    "os"
    "strings"
    "time"

    "dst"
)

const (
    acks_count        = 8
    acks_path         = "/var/lib/conformance/acks"
    draw_limit        = 10
    draws_count       = 64
    events_max        = 64
    identifier_length = 36
    live_message      = "the guest is live after the faults stop"
)

func acks_present(file *os.File) (err error) {
    defer func() {
        err = errors.Join(err, file.Close())
    }()

    scanner := bufio.NewScanner(file)

    for count := 0; count < acks_count; count++ {
        if !scanner.Scan() {
            return scanner.Err()
        }

        line := scanner.Text()

        if len(line) != identifier_length {
            continue
        }

        if err := dst.Present(line); err != nil {
            return err
        }
    }

    return nil
}

func acks_write() error {
    var text strings.Builder

    for index := 1; index <= acks_count; index++ {
        fmt.Fprintf(&text, "00000000-0000-4000-8000-0000000000%02d\n", index)
    }

    file, err := os.OpenFile(acks_path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
    if err != nil {
        return err
    }

    if _, err := file.WriteString(text.String()); err != nil {
        return err
    }

    if err := file.Sync(); err != nil {
        return err
    }

    if err := file.Close(); err != nil {
        return err
    }

    for _, line := range strings.Split(strings.TrimSpace(text.String()), "\n") {
        if err := dst.Ack(line); err != nil {
            return err
        }
    }

    return nil
}

func check() error {
    file, err := os.Open(acks_path)
    if err == nil {
        if err := acks_present(file); err != nil {
            return err
        }
    }

    return dst.Checked()
}

func draws(reporter *dst.Reporter) error {
    var largest uint64

    for count := 0; count < draws_count; count++ {
        word, err := dst.Random()
        if err != nil {
            return err
        }

        value := dst.Word_below(word, draw_limit)
        below := value < draw_limit

        if err := dst.Console(fmt.Sprintf("DST DRAWS 0 %x", word)); err != nil {
            return err
        }

        if err := reporter.Always(below, "every draw is below its limit", ""); err != nil {
            return err
        }

        if err := reporter.Sometimes(dst.Word_boolean(word), "a coin came up heads"); err != nil {
            return err
        }

        if value >= draw_limit {
            if err := reporter.Never("a draw reached its limit", ""); err != nil {
                return err
            }
        }

        if word > largest {
            largest = word

            if err := dst.Maximize("the largest draw", word); err != nil {
                return err
            }
        }
    }

    if largest == 0 {
        panic("sixty-four draws cannot all be zero")
    }

    return nil
}

func events() error {
    for count := 0; count < events_max; count++ {
        delay_ns, err := dst.Event_wait()
        if err != nil {
            return err
        }

        time.Sleep(time.Duration(delay_ns))

        event, err := dst.Event_due()
        if err != nil {
            return err
        }

        if event.Kind() == 0 {
            return nil
        }

        rendered, err := event.Render()
        if err != nil {
            return err
        }

        if err := dst.Console("DST EVENT " + rendered + " END"); err != nil {
            return err
        }
    }

    return fmt.Errorf("the timeline served more than %d events", events_max)
}

func properties_declare() error {
    properties := map[string]dst.Kind{
        "every draw is below its limit": dst.Kind_always,
        live_message:                    dst.Kind_always,
        "the largest draw":              dst.Kind_maximize,
        "the guest reached ready":       dst.Kind_reachable,
        "a coin came up heads":          dst.Kind_sometimes,
        "a draw reached its limit":      dst.Kind_unreachable,
    }

    order := []string{
        "every draw is below its limit",
        live_message,
        "the largest draw",
        "the guest reached ready",
        "a coin came up heads",
        "a draw reached its limit",
    }

    return dst.Declare(properties, order)
}

func run() error {
    var reporter dst.Reporter

    if err := properties_declare(); err != nil {
        return err
    }

    seed, err := dst.Ready(false)
    if err != nil {
        return err
    }

    if err := dst.Console(fmt.Sprintf("DST SEED %x", seed)); err != nil {
        return err
    }

    if err := reporter.Reachable("the guest reached ready"); err != nil {
        return err
    }

    if err := draws(&reporter); err != nil {
        return err
    }

    if err := acks_write(); err != nil {
        return err
    }

    if err := events(); err != nil {
        return err
    }

    if dst.Eventually_ns() > 0 {
        if err := reporter.Eventually(dst.Quiet_wait(), live_message, ""); err != nil {
            return err
        }
    }

    return dst.Power_loss()
}

func main() {
    var err error
    mode := ""

    if len(os.Args) > 1 {
        mode = os.Args[1]
    }

    if mode == "check" {
        err = check()
    } else {
        err = run()
    }

    if err != nil {
        fmt.Fprintln(os.Stderr, err)
        os.Exit(1)
    }
}
