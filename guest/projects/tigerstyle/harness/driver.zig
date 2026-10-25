const std = @import("std");

const dst = @import("dst");

const assert = std.debug.assert;
const linux = std.os.linux;
const Io = std.Io;
const Writer = std.Io.Writer;

const Check = struct {
    code: u8,
    findings: u32,
    stdout: []u8,
};

const binary = "/opt/project/bin/tigerstyle-lsp";
const check_argument = "check";

const corpus_files = [_][]const u8{
    "cache.zig",
    "cli.zig",
    "config.zig",
    "document.zig",
    "format.zig",
    "grammar.zig",
    "lex.zig",
    "lint.zig",
};

const iterations_min = 4;
const iterations_spread = 13;
const line_max = 256;
const log_path = "/var/lib/tigerstyle/log";
const log_size_max = 4096;
const message_cache = "a warm cache after a crash reports what a cold run reports";
const message_exit = "the checker exits with findings or with none";
const message_findings = "the most findings in one check";
const message_none = "a check found nothing";
const message_ready = "the workload reached ready";
const output_max = 16 << 20;
const probe_fill: [120]u8 = @splat('x');
const probe_line = "// " ++ probe_fill ++ "\n";

const properties = [_]dst.Property{
    .{ .kind = .always, .message = message_cache },
    .{ .kind = .always, .message = message_exit },
    .{ .kind = .maximize, .message = message_findings },
    .{ .kind = .reachable, .message = message_ready },
    .{ .kind = .sometimes, .message = message_none },
};

const uuid_format = "00000000-0000-4000-8000-0000000000{d:0>2}";
const work_path = "/var/lib/tigerstyle/work";

fn check(gpa: std.mem.Allocator, io: Io, environ_map: *const std.process.Environ.Map) !void {
    var buffer: [log_size_max]u8 = undefined;
    var details: [line_max]u8 = undefined;
    var reporter: dst.Reporter = .{};
    const held = file_read(log_path, &buffer) catch "";
    var lines = std.mem.splitScalar(u8, held, '\n');

    for (0..log_size_max + 2) |_| {
        const line = lines.next() orelse break;
        const space = std.mem.findScalar(u8, line, ' ') orelse continue;

        try dst.present(line[0..space]);
    } else unreachable;

    const warm = try check_run(gpa, io, environ_map, false);
    defer gpa.free(warm.stdout);

    const cold = try check_run(gpa, io, environ_map, true);
    defer gpa.free(cold.stdout);

    const same = std.mem.eql(u8, warm.stdout, cold.stdout);

    const detail = try std.mem.print(&details, "{{\"warm\": {d}, \"cold\": {d}}}", .{
        warm.findings,
        cold.findings,
    });

    try reporter.always(same, message_cache, detail);
    try reporter.always(warm.code <= 1, message_exit, "");
    try reporter.always(cold.code <= 1, message_exit, "");
    try dst.checked();
}

fn check_run(
    gpa: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    cold: bool,
) !Check {
    var map = try environ_map.clone(gpa);
    defer map.deinit();

    if (cold) try map.put("TIGERSTYLE_NO_CACHE", "1");

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ binary, "check", "--format", "concise", "." },
        .cwd = .{ .path = work_path },
        .environ_map = &map,
        .stderr_limit = .limited(output_max),
        .stdout_limit = .limited(output_max),
    });

    defer gpa.free(result.stderr);

    const code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 255,
    };

    const findings: u32 = @intCast(std.mem.count(u8, result.stdout, "\n"));
    return .{ .code = code, .findings = findings, .stdout = result.stdout };
}

fn file_append(path: [*:0]const u8, bytes: []const u8, durable: bool) !void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true };
    const rc = linux.open(path, flags, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;

    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    const written = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
    if (written != bytes.len) return error.WriteFailed;
    if (!durable) return;
    if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.SyncFailed;
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

fn iteration_run(
    gpa: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    reporter: *dst.Reporter,
    iteration: u64,
) !void {
    var path_buffer: [line_max]u8 = undefined;
    var record: [line_max]u8 = undefined;
    var identifier: [line_max]u8 = undefined;
    const file = corpus_files[try dst.below(corpus_files.len)];
    const path = try std.mem.printSentinel(&path_buffer, "{s}/{s}", .{ work_path, file }, 0);

    assert(iteration >= 1);
    assert(iteration <= iterations_min + iterations_spread);

    try file_append(path, probe_line, false);

    const checked = try check_run(gpa, io, environ_map, false);
    defer gpa.free(checked.stdout);

    const uuid = try std.mem.print(&identifier, uuid_format, .{iteration});

    const line = try std.mem.print(&record, "{s} {d} {d}\n", .{
        uuid,
        checked.findings,
        checked.code,
    });

    try reporter.always(checked.code <= 1, message_exit, "");
    try reporter.sometimes(checked.findings == 0, message_none);
    try dst.maximize(message_findings, checked.findings);
    try file_append(log_path, line, true);
    try dst.ack(uuid);
}

fn run(gpa: std.mem.Allocator, io: Io, init: std.process.Init) !void {
    var reporter: dst.Reporter = .{};

    try dst.declare(&properties);

    _ = try dst.ready(init.minimal.environ, .{});

    try reporter.reachable(message_ready);

    const iterations = iterations_min + try dst.below(iterations_spread);

    for (1..iterations + 1) |iteration| {
        iteration_run(gpa, io, init.environ_map, &reporter, iteration) catch |err| switch (err) {
            error.OpenFailed, error.SyncFailed, error.WriteFailed => {
                var buffer: [line_max]u8 = undefined;
                const line = try std.mem.print(&buffer, "DST FAULT unavailable {t}", .{err});

                try dst.console(line);

                break;
            },
            else => return err,
        };
    }

    try dst.power_loss();
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const checking = args.len > 1 and std.mem.eql(u8, args[1], check_argument);
    if (checking) return check(init.gpa, init.io, init.environ_map);

    try run(init.gpa, init.io, init);
}
