const std = @import("std");

const ports = @import("ports");

const assert = std.debug.assert;
const linux = std.os.linux;
const Writer = std.Io.Writer;

pub const Error = error{
    AgentFailed,
    ConsoleFailed,
    EventMagic,
    EventField,
    PortFailed,
};

pub const Event = extern struct {
    magic: u64,
    kind: u64,
    delay_ns: u64,
    duration_ns: u64,
    target: u64,
    choice: u64,
    restart: u64,
    restart_delay_ns: u64,
    clock_jump_ns: i64,
    clock_slew_ppm: i64,
    disk_full_slack_kib: u64,
    memory_immune: u64,
    memory_kills: u64,
    network_delay_ns: u64,
    network_direction: u64,
    network_jitter_ns: u64,
    network_link: u64,
    network_loss_permille: u64,
    network_peers: u64,
    network_reorder_permille: u64,
    pause_tree: u64,
    thread_choice: u64,
    throttle_permille: u64,

    pub fn render(event: *const Event, writer: *Writer) (Error || Writer.Error)!void {
        const fields = @typeInfo(Event).@"struct".field_names;

        assert(event.magic == event_magic);
        assert(std.mem.eql(u8, fields[0], "magic"));

        inline for (fields[1..], 0..) |name, index| {
            const value = @field(event, name);
            const separator = if (index == 0) "" else " ";
            const names: ?[]const []const u8 = comptime event_names(name);

            if (names) |table| {
                if (value >= table.len) return error.EventField;

                try writer.print("{s}{s}={s}", .{ separator, name, table[value] });
            } else {
                try writer.print("{s}{s}={d}", .{ separator, name, value });
            }
        }
    }
};

pub const Kind = enum {
    always,
    maximize,
    reachable,
    sometimes,
    @"unreachable",
};

pub const Property = struct {
    kind: Kind,
    message: []const u8,
};

pub const Ready = struct {
    agent: bool = true,
};

pub const Reporter = struct {
    count: u32 = 0,
    keys: [reported_max]u64 = undefined,

    fn report(reporter: *Reporter, line: []const u8) Error!void {
        const key = std.hash.Wyhash.hash(0, line);

        assert(reporter.count <= reported_max);

        for (reporter.keys[0..reporter.count]) |seen| {
            if (seen == key) return;
        }

        if (reporter.count < reported_max) {
            reporter.keys[reporter.count] = key;
            reporter.count += 1;
        }

        try console(line);
    }

    pub fn always(
        reporter: *Reporter,
        condition: bool,
        message: []const u8,
        details: []const u8,
    ) Error!void {
        var buffer: [line_max]u8 = undefined;
        const outcome = if (condition) "PASS" else "FAIL";
        const suffix = if (condition) "" else details;
        const line = try line_build(&buffer, "DST ALWAYS ", outcome, message, suffix);

        try reporter.report(line);
    }

    pub fn eventually(
        reporter: *Reporter,
        condition: bool,
        message: []const u8,
        details: []const u8,
    ) Error!void {
        try reporter.always(condition, message, details);
        try console(if (condition) "DST EVENTUALLY PASS" else "DST EVENTUALLY FAIL");
    }

    pub fn never(reporter: *Reporter, message: []const u8, details: []const u8) Error!void {
        var buffer: [line_max]u8 = undefined;
        const line = try line_build(&buffer, "DST UNREACHABLE ", "", message, details);

        try reporter.report(line);
    }

    pub fn reachable(reporter: *Reporter, message: []const u8) Error!void {
        var buffer: [line_max]u8 = undefined;
        const line = try line_build(&buffer, "DST REACHABLE ", "", message, "");

        try reporter.report(line);
    }

    pub fn sometimes(reporter: *Reporter, condition: bool, message: []const u8) Error!void {
        var buffer: [line_max]u8 = undefined;

        if (!condition) return;

        const line = try line_build(&buffer, "DST SOMETIMES ", "", message, "");

        try reporter.report(line);
    }
};

pub const event_magic = 0x31544e5645545344;
pub const line_max = 2048;
pub const word_bits = 64;
const agent_argv = [_:null]?[*:0]const u8{ "python3", "-m", "dst.agent" };
const agent_path = "/usr/bin/python3";
const console_path = "/dev/console";
const details_separator = " | ";
const directions = [_][]const u8{ "both", "requests", "replies" };
const entropy_path = "/dev/urandom";

const kinds = [_][]const u8{
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
};

const links = [_][]const u8{ "none", "postgres", "rabbitmq", "redis" };
const lock_ex = 2;
const lock_path = "/dev/shm/dst-draw";
const lock_un = 8;
const message_max = 1024;
const oom_immune_text = "-1000";
const oom_path = "/proc/self/oom_score_adj";
const port_path = "/dev/port";
const quiet_path = "/dev/shm/dst-quiet";
const quiet_poll_ns = 50 * std.time.ns_per_ms;
const quiet_polls_max = 12_000;
const reported_max = 256;
const reseed_crng = 0x5207;

const targets = [_][]const u8{
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
};

comptime {
    assert(@sizeOf(Event) == 23 * 8);
    assert(@sizeOf(Event) <= ports.event_block_size);
    assert(line_max > message_max + 64);
}

fn event_names(comptime name: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, name, "kind")) return &kinds;
    if (std.mem.eql(u8, name, "target")) return &targets;
    if (std.mem.eql(u8, name, "network_direction")) return &directions;
    if (std.mem.eql(u8, name, "network_link")) return &links;
    return null;
}

fn event_read(command: u8) Error!Event {
    var bytes: [@sizeOf(Event)]u8 = undefined;

    try exchange(ports.control, command, ports.event_first, &bytes);

    const event = std.mem.bytesToValue(Event, &bytes);
    if (event.magic != event_magic) return error.EventMagic;
    return event;
}

fn exchange(command_port: u16, command: u8, read_port: u16, out: []u8) Error!void {
    assert(out.len > 0);
    assert(out.len <= ports.event_block_size);

    const lock = try lock_take();
    defer lock_drop(lock);

    const port = try file_open(port_path, .{ .ACCMODE = .RDWR }, 0);
    defer _ = linux.close(port);

    try port_pwrite(port, &.{command}, command_port);
    try port_pread(port, out, read_port);
}

fn file_open(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) Error!linux.fd_t {
    const rc = linux.open(path, flags, mode);
    if (linux.errno(rc) != .SUCCESS) return error.PortFailed;
    return @intCast(rc);
}

fn file_write(fd: linux.fd_t, bytes: []const u8) Error!void {
    const rc = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(rc) != .SUCCESS) return error.PortFailed;
    if (rc != bytes.len) return error.PortFailed;
}

fn line_build(
    buffer: *[line_max]u8,
    prefix: []const u8,
    outcome: []const u8,
    message: []const u8,
    details: []const u8,
) Error![]const u8 {
    var writer: Writer = .fixed(buffer);

    assert(prefix.len > 0);

    writer.writeAll(prefix) catch return error.ConsoleFailed;

    if (outcome.len > 0) {
        writer.writeAll(outcome) catch return error.ConsoleFailed;
        writer.writeByte(' ') catch return error.ConsoleFailed;
    }

    try message_write(&writer, message);

    if (details.len > 0) {
        writer.writeAll(details_separator) catch return error.ConsoleFailed;
        writer.writeAll(details) catch return error.ConsoleFailed;
    }

    return writer.buffered();
}

fn lock_drop(lock: linux.fd_t) void {
    _ = linux.flock(lock, lock_un);
    _ = linux.close(lock);
}

fn lock_take() Error!linux.fd_t {
    const lock = try file_open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o666);
    errdefer _ = linux.close(lock);

    const rc = linux.flock(lock, lock_ex);
    if (linux.errno(rc) != .SUCCESS) return error.PortFailed;
    return lock;
}

fn message_write(writer: *Writer, message: []const u8) Error!void {
    var pending_space = false;
    var written: usize = 0;

    assert(message.len <= message_max);

    for (message) |byte| {
        const space = std.ascii.isWhitespace(byte);

        if (space) {
            pending_space = written > 0;

            continue;
        }

        if (pending_space) writer.writeByte(' ') catch return error.ConsoleFailed;

        const clean: u8 = if (byte == '|') '/' else byte;

        writer.writeByte(clean) catch return error.ConsoleFailed;

        pending_space = false;
        written += 1;
    }

    assert(written <= message.len);
}

fn port_pread(port: linux.fd_t, out: []u8, offset: u16) Error!void {
    const rc = linux.pread(port, out.ptr, out.len, offset);
    if (linux.errno(rc) != .SUCCESS) return error.PortFailed;
    if (rc != out.len) return error.PortFailed;
}

fn port_pwrite(port: linux.fd_t, bytes: []const u8, offset: u16) Error!void {
    const rc = linux.pwrite(port, bytes.ptr, bytes.len, offset);
    if (linux.errno(rc) != .SUCCESS) return error.PortFailed;
    if (rc != bytes.len) return error.PortFailed;
}

fn write_locked(port_first: u16, bytes: []const u8) Error!void {
    assert(bytes.len > 0);

    const lock = try lock_take();
    defer lock_drop(lock);

    const port = try file_open(port_path, .{ .ACCMODE = .WRONLY }, 0);
    defer _ = linux.close(port);

    try port_pwrite(port, bytes, port_first);
}

pub fn ack(identifier: []const u8) Error!void {
    var buffer: [line_max]u8 = undefined;

    const line = std.mem.print(&buffer, "DST ACK {s}", .{identifier}) catch {
        return error.ConsoleFailed;
    };

    try console(line);
}

pub fn agent_spawn(environ: std.process.Environ) Error!void {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.AgentFailed;
    if (pid != 0) return;

    _ = linux.execve(agent_path, &agent_argv, environ.block.slice.ptr);

    linux.exit(127);
}

pub fn below(limit: u64) Error!u64 {
    assert(limit > 0);

    return word_below(try random(), limit);
}

pub fn boolean() Error!bool {
    return word_boolean(try random());
}

pub fn checked() Error!void {
    try console("DST CHECK DONE");
}

pub fn console(line: []const u8) Error!void {
    var buffer: [line_max + 1]u8 = undefined;

    assert(line.len > 0);

    if (line.len > line_max) return error.ConsoleFailed;

    @memcpy(buffer[0..line.len], line);

    buffer[line.len] = '\n';

    const fd = try file_open(console_path, .{ .ACCMODE = .WRONLY, .NOCTTY = true }, 0);
    defer _ = linux.close(fd);

    file_write(fd, buffer[0 .. line.len + 1]) catch return error.ConsoleFailed;
}

pub fn control(command: u8) Error!void {
    const port = try file_open(port_path, .{ .ACCMODE = .WRONLY }, 0);
    defer _ = linux.close(port);

    try port_pwrite(port, &.{command}, ports.control);
}

pub fn cpus_count() u32 {
    var set: linux.cpu_set_t = @splat(0);
    var count: u32 = 0;

    const rc = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (linux.errno(rc) != .SUCCESS) return 1;

    for (set) |word| count += @popCount(word);

    return @max(count, 1);
}

pub fn declare(properties: []const Property) Error!void {
    var buffer: [line_max]u8 = undefined;

    assert(properties.len > 0);

    for (properties) |property| {
        const kind = @tagName(property.kind);
        const line = try line_build(&buffer, "DST DECLARE ", kind, property.message, "");

        try console(line);
    }
}

pub fn entropy_mix(value: u64) Error!void {
    var bytes: [8]u8 = undefined;

    std.mem.writeInt(u64, &bytes, value, .little);

    const pool = try file_open(entropy_path, .{ .ACCMODE = .WRONLY }, 0);
    defer _ = linux.close(pool);

    try file_write(pool, &bytes);

    const rc = linux.ioctl(pool, reseed_crng, 0);
    if (linux.errno(rc) != .SUCCESS) return error.PortFailed;
}

pub fn event_due() Error!Event {
    return event_read(ports.control_event_due);
}

pub fn event_wait() Error!u64 {
    const event = try event_read(ports.control_event_wait);
    return event.delay_ns;
}

pub fn eventually_ns(environ_map: *const std.process.Environ.Map) u64 {
    const text = environ_map.get("DST_EVENTUALLY_NS") orelse return 0;
    return std.fmt.parseInt(u64, text, 10) catch 0;
}

pub fn maximize(message: []const u8, value: u64) Error!void {
    var cleaned: [line_max]u8 = undefined;
    var writer: Writer = .fixed(&cleaned);
    var bytes: [ports.guidance_count]u8 = undefined;

    try message_write(&writer, message);

    const crc = std.hash.Crc32.hash(writer.buffered());

    std.mem.writeInt(u32, bytes[0..4], crc, .little);
    std.mem.writeInt(u64, bytes[4..12], value, .little);

    try write_locked(ports.guidance_first, &bytes);
}

pub fn oom_immune() Error!void {
    const adjustment = try file_open(oom_path, .{ .ACCMODE = .WRONLY }, 0);
    defer _ = linux.close(adjustment);

    try file_write(adjustment, oom_immune_text);
}

pub fn power_loss() Error!void {
    try control(ports.control_power_loss);
}

pub fn present(identifier: []const u8) Error!void {
    var buffer: [line_max]u8 = undefined;

    const line = std.mem.print(&buffer, "DST PRESENT {s}", .{identifier}) catch {
        return error.ConsoleFailed;
    };

    try console(line);
}

pub fn quiet_wait() bool {
    const pause: linux.timespec = .{ .sec = 0, .nsec = quiet_poll_ns };

    for (0..quiet_polls_max) |_| {
        const rc = linux.access(quiet_path, 0);
        if (linux.errno(rc) == .SUCCESS) return true;

        _ = linux.nanosleep(&pause, null);
    }

    return false;
}

pub fn random() Error!u64 {
    var bytes: [ports.word_bytes]u8 = undefined;

    try exchange(ports.draw_first, ports.draw_latch, ports.draw_first + 1, &bytes);

    return std.mem.readInt(u64, &bytes, .little);
}

pub fn ready(environ: std.process.Environ, options: Ready) Error!u64 {
    var buffer: [line_max]u8 = undefined;

    const cpus = std.mem.print(&buffer, "DST CPUS {d}", .{cpus_count()}) catch {
        return error.ConsoleFailed;
    };

    try console(cpus);
    try control(ports.control_ready);

    const run_seed = try seed();

    try entropy_mix(run_seed);
    try oom_immune();

    if (options.agent) try agent_spawn(environ);

    return run_seed;
}

pub fn seed() Error!u64 {
    var bytes: [ports.word_bytes]u8 = undefined;

    const port = try file_open(port_path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(port);

    try port_pread(port, &bytes, ports.seed_first);

    return std.mem.readInt(u64, &bytes, .little);
}

pub fn word_below(word: u64, limit: u64) u64 {
    const product = @as(u128, word) * limit;
    const value: u64 = @intCast(product >> 64);

    assert(limit > 0);
    assert(value < limit);

    return value;
}

pub fn word_boolean(word: u64) bool {
    return word >> (word_bits - 1) == 1;
}

test "a word maps below a limit monotonically and the minimal word maps to zero" {
    try std.testing.expectEqual(0, word_below(0, 10));
    try std.testing.expectEqual(9, word_below(std.math.maxInt(u64), 10));
    try std.testing.expectEqual(5, word_below(1 << 63, 10));
    try std.testing.expect(!word_boolean(0));
    try std.testing.expect(word_boolean(1 << 63));

    var previous: u64 = 0;

    for (0..64) |shift| {
        const value = word_below(@as(u64, 1) << @intCast(shift), 1000);

        try std.testing.expect(value >= previous);

        previous = value;
    }
}

test "a message collapses whitespace and loses its separators" {
    var buffer: [line_max]u8 = undefined;
    const line = try line_build(&buffer, "DST ALWAYS ", "FAIL", "  money |\tis\n conserved ", "{}");

    try std.testing.expectEqualStrings("DST ALWAYS FAIL money / is conserved | {}", line);
}

test "an event block renders its enumerated fields by name and rejects an unknown one" {
    var event: Event = std.mem.zeroes(Event);
    var buffer: [line_max]u8 = undefined;
    var writer: Writer = .fixed(&buffer);

    event.magic = event_magic;
    event.kind = 4;
    event.target = 6;
    event.clock_jump_ns = -5;

    try event.render(&writer);

    const rendered = writer.buffered();
    const head = "kind=kill delay_ns=0 duration_ns=0 target=redis_server";
    const starts = std.mem.startsWith(u8, rendered, head);
    const jump = std.mem.find(u8, rendered, " clock_jump_ns=-5 ") != null;
    const ends = std.mem.endsWith(u8, rendered, " throttle_permille=0");

    try std.testing.expect(starts);
    try std.testing.expect(jump);
    try std.testing.expect(ends);

    event.kind = kinds.len;

    var rejected: Writer = .fixed(&buffer);

    try std.testing.expectError(error.EventField, event.render(&rejected));
}
