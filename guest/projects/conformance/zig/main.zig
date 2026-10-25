const std = @import("std");

const dst = @import("dst");

const assert = std.debug.assert;
const linux = std.os.linux;
const Writer = std.Io.Writer;

const acks_count = 8;
const acks_path = "/var/lib/conformance/acks";
const acks_size_max = 4096;
const check_argument = "check";
const draw_limit = 10;
const draws_count = 64;
const events_max = 64;
const identifier_length = 36;
const live_message = "the guest is live after the faults stop";

const properties = [_]dst.Property{
    .{ .kind = .always, .message = "every draw is below its limit" },
    .{ .kind = .always, .message = live_message },
    .{ .kind = .maximize, .message = "the largest draw" },
    .{ .kind = .reachable, .message = "the guest reached ready" },
    .{ .kind = .sometimes, .message = "a coin came up heads" },
    .{ .kind = .@"unreachable", .message = "a draw reached its limit" },
};

fn acks_write() !void {
    var bytes: [acks_count * (identifier_length + 1)]u8 = undefined;
    var writer: Writer = .fixed(&bytes);

    for (0..acks_count) |index| {
        try writer.print("00000000-0000-4000-8000-0000000000{d:0>2}\n", .{index + 1});
    }

    const written = writer.buffered();
    const fd = try file_create(acks_path);
    defer _ = linux.close(fd);

    try file_write(fd, written);

    if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.SyncFailed;

    var lines = std.mem.splitScalar(u8, written, '\n');

    for (0..acks_count + 2) |_| {
        const line = lines.next() orelse break;
        if (line.len == 0) continue;

        try dst.ack(line);
    } else unreachable;
}

fn check() !void {
    var bytes: [acks_size_max]u8 = undefined;
    const held = file_read(acks_path, &bytes) catch "";
    var lines = std.mem.splitScalar(u8, held, '\n');

    for (0..acks_size_max + 2) |_| {
        const line = lines.next() orelse break;
        if (line.len != identifier_length) continue;

        try dst.present(line);
    } else unreachable;

    try dst.checked();
}

fn draws(reporter: *dst.Reporter) !void {
    var buffer: [dst.line_max]u8 = undefined;
    var largest: u64 = 0;

    for (0..draws_count) |_| {
        const word = try dst.random();
        const value = dst.word_below(word, draw_limit);
        const line = try std.mem.print(&buffer, "DST DRAWS 0 {x}", .{word});

        try dst.console(line);
        try reporter.always(value < draw_limit, "every draw is below its limit", "");
        try reporter.sometimes(dst.word_boolean(word), "a coin came up heads");

        if (value >= draw_limit) try reporter.never("a draw reached its limit", "");

        if (word > largest) {
            largest = word;

            try dst.maximize("the largest draw", word);
        }
    }

    assert(largest > 0);
}

fn events() !void {
    var buffer: [dst.line_max]u8 = undefined;

    for (0..events_max) |_| {
        const delay_ns = try dst.event_wait();

        sleep(delay_ns);

        const event = try dst.event_due();
        if (event.kind == 0) break;

        var writer: Writer = .fixed(&buffer);

        try writer.writeAll("DST EVENT ");
        try event.render(&writer);
        try writer.writeAll(" END");
        try dst.console(writer.buffered());
    } else return error.TooManyEvents;
}

fn file_create(path: [*:0]const u8) !linux.fd_t {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const rc = linux.open(path, flags, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    return @intCast(rc);
}

fn file_read(path: [*:0]const u8, buffer: []u8) ![]const u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;

    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    const count = linux.read(fd, buffer.ptr, buffer.len);
    if (linux.errno(count) != .SUCCESS) return error.ReadFailed;
    return buffer[0..count];
}

fn file_write(fd: linux.fd_t, bytes: []const u8) !void {
    const rc = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    if (rc != bytes.len) return error.WriteFailed;
}

fn run(init: std.process.Init) !void {
    var buffer: [dst.line_max]u8 = undefined;
    var reporter: dst.Reporter = .{};

    try dst.declare(&properties);

    const seed = try dst.ready(init.minimal.environ, .{ .agent = false });
    const line = try std.mem.print(&buffer, "DST SEED {x}", .{seed});

    try dst.console(line);
    try reporter.reachable("the guest reached ready");
    try draws(&reporter);
    try acks_write();
    try events();

    if (dst.eventually_ns(init.environ_map) > 0) {
        const quiet = dst.quiet_wait();

        try reporter.eventually(quiet, live_message, "");
    }

    try dst.power_loss();
}

fn sleep(delay_ns: u64) void {
    const pause: linux.timespec = .{
        .sec = @intCast(delay_ns / std.time.ns_per_s),
        .nsec = @intCast(delay_ns % std.time.ns_per_s),
    };

    _ = linux.nanosleep(&pause, null);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const checking = args.len > 1 and std.mem.eql(u8, args[1], check_argument);
    if (checking) return check();

    try run(init);
}
