const std = @import("std");

const docker = @import("docker");
const dst = @import("dst");

const assert = std.debug.assert;
const linux = std.os.linux;
const Io = std.Io;

const api = docker.api;
const model = docker.model;

const Client = docker.Client;

const Context = struct {
    client: *Client,
    exec: [exec_id_bytes_max]u8,
    exec_length: u32,
    failures: u64,
    io: Io,
    observed: Observed,
    output: [output_bytes_max]u8,
    output_length: u32,
    reporter: dst.Reporter,
    scratch: [archive_bytes_max]u8,
};

const Observed = struct {
    archive_sized: ?bool = null,
    exec_exact: ?bool = null,
    exec_unclean: bool = false,
    logs_exact: ?bool = null,
    ran: bool = false,
    streams_ended: bool = true,
};

const Plan = struct {
    content_length: u32,
    fill: u8,
    service: bool,
};

const archive_bytes_max = 64 * 1024;
const check_argument = "check";
const content_bytes_max = 4096;
const daemon_poll_ms = 100;
const daemon_polls_max = 600;
const eventually_attempts_max = 256;
const eventually_margin_ns = std.time.ns_per_s;
const eventually_retry_ms = 250;
const exec_id_bytes_max = 128;
const frames_max = 1024;
const home_default = "/root";
const host_default = "unix:///var/run/docker.sock";
const image_archive_bytes_max = 16 << 20;
const image_archive_path = "/opt/project/busybox.tar";
const image_reference = image_repository ++ ":" ++ image_tag;
const image_repository = "dst/busybox";
const image_tag = "1";
const iterations_min = 4;
const iterations_spread = 12;
const line_max = 256;
const log_path = "/var/lib/docker-zig/log";
const log_size_max = 16 * 1024;
const message_archive = "an archived file reports the size it was written with";
const message_exec = "an exec that exits cleanly returns exactly the output it printed";
const message_exec_unclean = "an exec ended without exiting cleanly";
const message_failure = "a request failed while the faults were active";
const message_failures = "the most failed requests in one run";
const message_idle = "the client is idle after every request";
const message_limits = "every response the daemon finishes parses within the client's limits";
const message_live = "the daemon runs a container after the faults stop";
const message_logs = "a finished container's logs hold what it printed";
const message_ran = "a container ran to completion";
const message_ready = "the workload reached ready";
const message_restart = "the daemon answers after a power loss";
const message_streams = "every stream ends within its bound";
const messages_max = 4096;
const name_bytes_max = 64;
const output_bytes_max = 4096;

const properties = [_]dst.Property{
    .{ .kind = .always, .message = message_archive },
    .{ .kind = .always, .message = message_exec },
    .{ .kind = .always, .message = message_idle },
    .{ .kind = .always, .message = message_limits },
    .{ .kind = .always, .message = message_live },
    .{ .kind = .always, .message = message_logs },
    .{ .kind = .always, .message = message_restart },
    .{ .kind = .always, .message = message_streams },
    .{ .kind = .maximize, .message = message_failures },
    .{ .kind = .reachable, .message = message_ready },
    .{ .kind = .sometimes, .message = message_exec_unclean },
    .{ .kind = .sometimes, .message = message_failure },
    .{ .kind = .sometimes, .message = message_ran },
};

const uuid_format = "00000000-0000-4000-8000-0000000000{d:0>2}";

fn acknowledge(uuid: []const u8) !void {
    var record: [line_max]u8 = undefined;
    const line = try std.mem.print(&record, "{s}\n", .{uuid});

    assert(uuid.len == 36);

    linux.sync();

    try file_append(log_path, line);
    try dst.ack(uuid);
}

fn archive_build(context: *Context, file_name: []const u8, plan: *const Plan) ![]const u8 {
    var writer: Io.Writer = .fixed(&context.scratch);
    var tar: std.tar.Writer = .{ .prefix = "", .underlying_writer = &writer };
    var content: [content_bytes_max]u8 = undefined;

    assert(file_name.len > 0);
    assert(plan.content_length <= content_bytes_max);

    @memset(content[0..plan.content_length], plan.fill);

    try tar.writeFileBytes(file_name, content[0..plan.content_length], .{
        .mode = 0o644,
        .mtime = 0,
    });

    try tar.finishPedantically();

    const result = writer.buffered();

    assert(result.len % 512 == 0);

    return result;
}

fn batch_exercise(context: *Context, name: []const u8, token: []const u8) docker.Error!void {
    const client = context.client;
    var waited: model.ContainerWaitResponse = undefined;

    assert(name.len > 0);
    assert(token.len > 0);

    try container_create(context, name, &.{ "echo", token });
    try api.container_start(client, name, &.{});
    try api.container_wait(client, name, &.{}, &waited);

    context.observed.ran = waited.status_code == 0;

    var logs = try api.container_logs(client, name, &.{ .stdout = true });
    const ended = frames_drain(context, docker.FrameStream, &logs);

    logs.close();

    if (!try ended) context.observed.streams_ended = false;
    if (context.observed.ran) context.observed.logs_exact = output_echoes(context, token);

    try api.container_delete(client, name, &.{ .force = true });
}

fn check(context: *Context) !void {
    var buffer: [log_size_max]u8 = undefined;
    var name_buffer: [name_bytes_max]u8 = undefined;
    var inspected: model.ContainerInspectResponse = undefined;

    assert(context.client.phase == .idle);
    assert(context.failures == 0);

    const up = daemon_wait(context);
    const held = file_read(log_path, &buffer) catch "";
    var lines = std.mem.splitScalar(u8, held, '\n');

    try context.reporter.always(up, message_restart, "");

    for (0..log_size_max + 2) |_| {
        const uuid = lines.next() orelse break;
        if (uuid.len == 0) continue;
        if (!up) continue;

        const name = try std.mem.print(&name_buffer, "dst-{s}", .{uuid});

        api.container_inspect(context.client, name, &.{}, &inspected) catch |err| {
            try failure_report(context, err, name);

            continue;
        };

        try dst.present(uuid);
    } else unreachable;

    try dst.checked();
}

fn container_create(
    context: *Context,
    name: []const u8,
    command: []const []const u8,
) docker.Error!void {
    var created: model.ContainerCreateResponse = undefined;

    assert(name.len > 0);
    assert(command.len > 0);

    const body: model.ContainerCreateBody = .{
        .command = command,
        .host_config = .{ .network_mode = "none" },
        .image = image_reference,
    };

    try api.container_create(context.client, &.{ .name = name }, &body, &created);
}

fn daemon_wait(context: *Context) bool {
    var ping: docker.Ping = undefined;

    assert(context.client.phase == .idle);

    for (0..daemon_polls_max) |_| {
        api.system_ping(context.client, &ping) catch |err| switch (err) {
            error.ConnectFailed, error.ReadFailed => {
                context.io.sleep(.fromMilliseconds(daemon_poll_ms), .awake) catch return false;

                continue;
            },
            else => return false,
        };

        context.client.version_negotiate(&ping) catch return false;

        return true;
    }

    return false;
}

fn eventually_attempt(context: *Context, attempt: u64) !bool {
    var name_buffer: [name_bytes_max]u8 = undefined;
    var ping: docker.Ping = undefined;
    const name = try std.mem.print(&name_buffer, "dst-eventually-{d}", .{attempt});

    assert(context.client.phase == .idle);
    assert(attempt < eventually_attempts_max);

    context.observed = .{};

    api.system_ping(context.client, &ping) catch |err| {
        try failure_report(context, err, "eventually ping");

        return false;
    };

    batch_exercise(context, name, "eventually") catch |err| {
        try failure_report(context, err, "eventually");

        return false;
    };

    return context.observed.logs_exact orelse false;
}

fn eventually_run(context: *Context, environ_map: *const std.process.Environ.Map) !void {
    var line_buffer: [line_max]u8 = undefined;
    const budget_ns = dst.eventually_ns(environ_map);

    assert(context.client.phase == .idle);
    assert(environ_map.count() > 0);

    if (budget_ns == 0) return;

    const quiet = dst.quiet_wait();
    const start_ns = Io.Clock.awake.now(context.io).nanoseconds;
    const deadline_ns = start_ns + budget_ns -| eventually_margin_ns;
    var live = false;

    for (0..eventually_attempts_max) |attempt| {
        if (!quiet) break;
        if (Io.Clock.awake.now(context.io).nanoseconds >= deadline_ns) break;

        live = try eventually_attempt(context, attempt);

        if (live) break;

        try context.io.sleep(.fromMilliseconds(eventually_retry_ms), .awake);
    }

    const elapsed_ns = Io.Clock.awake.now(context.io).nanoseconds - start_ns;
    const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);

    const line = try std.mem.print(&line_buffer, "docker-zig: eventually {s} after {d} ms", .{
        if (live) "live" else "down",
        elapsed_ms,
    });

    const detail = if (quiet) "never served a container" else "never quiet";

    try dst.console(line);
    try context.reporter.eventually(live, message_live, detail);
}

fn exec_exercise(context: *Context, name: []const u8, token: []const u8) docker.Error!void {
    var created: model.IDResponse = undefined;

    assert(name.len > 0);
    assert(token.len > 0);

    const configuration: model.ExecConfig = .{
        .attach_stderr = true,
        .attach_stdout = true,
        .command = &.{ "echo", token },
    };

    try api.exec_create(context.client, name, &configuration, &created);

    const id = created.id orelse return error.ResponseInvalid;
    if (id.len > exec_id_bytes_max) return error.ResponseTooLarge;

    @memcpy(context.exec[0..id.len], id);
    context.exec_length = @intCast(id.len);

    const exec = context.exec[0..context.exec_length];
    var hijack = try api.exec_start(context.client, exec, &.{ .detach = false, .tty = false });
    const ended = frames_drain(context, docker.Hijack, &hijack);

    hijack.close();

    if (!try ended) context.observed.streams_ended = false;

    var inspected: model.ExecInspectResponse = undefined;

    try api.exec_inspect(context.client, exec, &inspected);

    const exited = !(inspected.running orelse true);
    const clean = exited and (inspected.exit_code orelse -1) == 0;

    if (clean) {
        context.observed.exec_exact = output_echoes(context, token);
    } else {
        context.observed.exec_unclean = true;
    }
}

fn failure_record(context: *Context, err: docker.Error, operation: []const u8) !void {
    context.failures += 1;

    try context.reporter.sometimes(true, message_failure);
    const parsed = err != error.ResponseInvalid and err != error.ResponseTooLarge;

    try context.reporter.always(parsed, message_limits, operation);
    try failure_report(context, err, operation);
}

fn failure_report(context: *const Context, err: docker.Error, operation: []const u8) !void {
    var buffer: [line_max]u8 = undefined;
    const diagnostic = &context.client.diagnostic;
    const message = diagnostic.message.slice();
    const shown = message[0..@min(message.len, line_max / 2)];

    const line = try std.mem.print(&buffer, "docker-zig: {s} failed: {t} {d} {s}", .{
        operation,
        err,
        diagnostic.status,
        shown,
    });

    try dst.console(line);
}

fn file_append(path: [*:0]const u8, bytes: []const u8) !void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true };
    const rc = linux.open(path, flags, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;

    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    const written = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
    if (written != bytes.len) return error.WriteFailed;
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

fn frames_drain(context: *Context, comptime Stream: type, frames: *Stream) docker.Error!bool {
    var buffer: [output_bytes_max]u8 = undefined;

    comptime assert(@hasDecl(Stream, "next"));
    assert(context.client.phase == .streaming or context.client.phase == .hijacked);

    context.output_length = 0;

    for (0..frames_max) |_| {
        const frame = switch (try frames.next(&buffer)) {
            .end => return true,
            .frame => |frame| frame,
        };

        if (frame.kind != .stdout) continue;

        const room = output_bytes_max - context.output_length;
        const count: u32 = @intCast(@min(room, frame.bytes.len));

        @memcpy(context.output[context.output_length..][0..count], frame.bytes[0..count]);
        context.output_length += count;

        assert(context.output_length <= output_bytes_max);
    }

    return false;
}

fn image_import(gpa: std.mem.Allocator, context: *Context) !void {
    assert(context.client.phase == .idle);
    assert(image_repository.len > 0);

    const limit: Io.Limit = .limited(image_archive_bytes_max);
    const archive = try Io.Dir.cwd().readFileAlloc(context.io, image_archive_path, gpa, limit);
    defer gpa.free(archive);

    var reader: Io.Reader = .fixed(archive);
    var message: model.CreateImageInfo = undefined;
    const upload: docker.Upload = .{ .content_length = archive.len, .reader = &reader };

    const query: api.ImageCreateQuery = .{
        .from_source = "-",
        .repository = image_repository,
        .tag = image_tag,
    };

    var messages = try api.image_create(context.client, &query, &.{}, &upload);
    defer messages.close();

    for (0..messages_max) |_| {
        if (!try messages.next(&message)) return;
    }

    return error.ImportUnfinished;
}

fn iteration_run(context: *Context, iteration: u64) !void {
    var name_buffer: [name_bytes_max]u8 = undefined;
    var token_buffer: [line_max]u8 = undefined;
    var uuid_buffer: [line_max]u8 = undefined;
    const token = try std.mem.print(&token_buffer, "docker-zig {d}", .{iteration});

    assert(iteration >= 1);
    assert(iteration < iterations_min + iterations_spread);

    const plan: Plan = .{
        .content_length = @intCast(try dst.below(content_bytes_max + 1)),
        .fill = @intCast(try dst.below(256)),
        .service = try dst.boolean(),
    };

    context.observed = .{};

    if (!plan.service) {
        const name = try std.mem.print(&name_buffer, "dst-batch-{d}", .{iteration});
        const outcome = batch_exercise(context, name, token);

        try observed_report(context, "batch");

        return outcome catch |err| failure_record(context, err, "batch");
    }

    const uuid = try std.mem.print(&uuid_buffer, uuid_format, .{iteration});
    const name = try std.mem.print(&name_buffer, "dst-{s}", .{uuid});

    if (container_create(context, name, &.{ "sleep", "600" })) |_| {
        try acknowledge(uuid);
    } else |err| {
        try observed_report(context, "create");

        return failure_record(context, err, "create");
    }

    const outcome = service_exercise(context, name, token, &plan);

    try observed_report(context, "service");

    return outcome catch |err| failure_record(context, err, "service");
}

fn observed_report(context: *Context, operation: []const u8) !void {
    const observed = &context.observed;
    const reporter = &context.reporter;
    const detail = context.output[0..@min(context.output_length, line_max)];

    assert(operation.len > 0);
    assert(context.output_length <= output_bytes_max);

    try reporter.always(context.client.phase == .idle, message_idle, operation);
    try reporter.always(observed.streams_ended, message_streams, operation);
    try reporter.sometimes(observed.ran, message_ran);
    try reporter.sometimes(observed.exec_unclean, message_exec_unclean);

    if (observed.archive_sized) |sized| try reporter.always(sized, message_archive, operation);
    if (observed.exec_exact) |exact| try reporter.always(exact, message_exec, detail);
    if (observed.logs_exact) |exact| try reporter.always(exact, message_logs, detail);
}

fn output_echoes(context: *const Context, token: []const u8) bool {
    assert(token.len > 0);
    assert(token.len < output_bytes_max);

    if (context.output_length != token.len + 1) return false;
    if (context.output[token.len] != '\n') return false;
    return std.mem.eql(u8, context.output[0..token.len], token);
}

fn run(gpa: std.mem.Allocator, context: *Context, init: std.process.Init) !void {
    assert(context.client.phase == .idle);
    assert(context.failures == 0);

    try dst.declare(&properties);

    if (!daemon_wait(context)) return error.DaemonUnavailable;

    try image_import(gpa, context);

    _ = try dst.ready(init.minimal.environ, .{});

    try context.reporter.reachable(message_ready);

    const iterations = iterations_min + try dst.below(iterations_spread);

    for (1..iterations + 1) |iteration| {
        iteration_run(context, iteration) catch |err| switch (err) {
            error.OpenFailed, error.SyncFailed, error.WriteFailed => {
                var buffer: [line_max]u8 = undefined;
                const line = try std.mem.print(&buffer, "DST FAULT unavailable {t}", .{err});

                try dst.console(line);

                break;
            },
            else => return err,
        };
    }

    try dst.maximize(message_failures, context.failures);
    try eventually_run(context, init.environ_map);
    try dst.power_loss();
}

fn service_exercise(
    context: *Context,
    name: []const u8,
    token: []const u8,
    plan: *const Plan,
) docker.Error!void {
    var file_buffer: [name_bytes_max]u8 = undefined;
    var path_buffer: [name_bytes_max]u8 = undefined;
    var stat: docker.PathStat = undefined;

    assert(name.len > 0);
    assert(plan.content_length <= content_bytes_max);

    try api.container_start(context.client, name, &.{});
    try exec_exercise(context, name, token);

    const file_name = std.mem.print(&file_buffer, "payload-{d}.txt", .{
        plan.content_length,
    }) catch return error.RequestTooLarge;

    const path = std.mem.print(&path_buffer, "/tmp/{s}", .{file_name}) catch {
        return error.RequestTooLarge;
    };

    const tar = archive_build(context, file_name, plan) catch return error.RequestTooLarge;
    var reader: Io.Reader = .fixed(tar);
    const upload: docker.Upload = .{ .content_length = tar.len, .reader = &reader };

    try api.container_archive_put(context.client, name, &.{ .path = "/tmp" }, &upload);
    try api.container_archive_information(context.client, name, &.{ .path = path }, &stat);

    context.observed.archive_sized = stat.size == plan.content_length;

    try api.container_kill(context.client, name, &.{ .signal = "KILL" });
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const checking = args.len > 1 and std.mem.eql(u8, args[1], check_argument);
    const environ_map = init.environ_map;
    const context = try init.gpa.create(Context);
    defer init.gpa.destroy(context);

    const client = try init.gpa.create(Client);
    defer init.gpa.destroy(client);

    context.* = .{
        .client = client,
        .exec = undefined,
        .exec_length = 0,
        .failures = 0,
        .io = init.io,
        .observed = .{},
        .output = undefined,
        .output_length = 0,
        .reporter = .{},
        .scratch = undefined,
    };

    try client.init(init.io, &.{
        .docker_config = null,
        .docker_context = null,
        .docker_host = environ_map.get("DOCKER_HOST") orelse host_default,
        .docker_tls_verify = null,
        .home = environ_map.get("HOME") orelse home_default,
    });

    if (checking) return check(context);

    try run(init.gpa, context, init);
}
