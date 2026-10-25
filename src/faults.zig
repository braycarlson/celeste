const std = @import("std");

const choices = @import("choices.zig");
const snapshot = @import("snapshot.zig");

const assert = std.debug.assert;
const word_below = choices.word_below;
const word_boolean = choices.word_boolean;

const ForkPoint = snapshot.ForkPoint;
const Stream = choices.Stream;
const Writer = std.Io.Writer;

pub const Faults = struct {
    branch_ps: u32 = branch_ps_default,
    disk: Disk = .{},
    roster: Roster = .services,
    script: []const Event = &.{},
    weights: Weights = .{},

    pub fn describe(faults: *const Faults, writer: *Writer) Writer.Error!void {
        assert(faults.valid());

        try faults.disk.describe(writer);

        if (faults.branch_ps != branch_ps_default) {
            try writer.print("; cpu {d} ps per branch", .{faults.branch_ps});
        }

        if (faults.weights.total() > 0) try faults.weights.describe(writer);
        if (faults.roster != .services) try writer.print("; roster {t}", .{faults.roster});
        if (faults.script.len > 0) try writer.print("; script of {d} events", .{faults.script.len});
    }

    pub fn idle(faults: *const Faults) bool {
        if (faults.branch_ps != branch_ps_default) return false;
        if (faults.script.len > 0) return false;
        if (faults.weights.total() > 0) return false;
        return std.meta.eql(faults.disk, Disk{});
    }

    pub fn swarm(stream: *Stream, window_ns: u64, families: Families) Faults {
        assert(window_ns > 0);
        assert(window_ns <= swarm_window_ns_max);

        const position = stream.position;
        var disk = swarm_disk(stream, window_ns);
        var weights: Weights = .{};

        inline for (@typeInfo(Weights).@"struct".field_names) |name| {
            const on = stream.boolean();
            const weight: u8 = @intCast(1 + stream.below(weight_max));

            if (@field(families, name)) @field(weights, name) = if (on) weight else 0;
        }

        const modulated = stream.boolean() and families.cpu;
        const exponent: u32 = @intCast(stream.at_most(swarm_rate_exponent_max));
        const rate = if (modulated) swarm_rate(exponent) else branch_ps_default;

        if (!families.disk_errors) {
            disk.error_delay_ns = 0;
            disk.error_duration_ns = 0;
            disk.error_read_permille = 0;
            disk.error_write_permille = 0;
        }

        if (!families.disk_latency) {
            disk.latency_ns_max = 0;
            disk.persist_permille = permille;
            disk.stall_ns = 0;
            disk.stall_permille = 0;
        }

        const faults: Faults = .{ .branch_ps = rate, .disk = disk, .weights = weights };

        assert(faults.valid());
        assert(stream.position - position == swarm_words);

        return faults;
    }

    pub fn valid(faults: *const Faults) bool {
        const disk = faults.disk;
        if (!std.math.isPowerOfTwo(disk.atomic_sectors)) return false;
        if (disk.atomic_sectors > atomic_sectors_max) return false;
        if (disk.persist_permille > permille) return false;
        if (disk.stall_permille > permille) return false;
        if (disk.error_read_permille > permille) return false;
        if (disk.error_write_permille > permille) return false;
        if (faults.branch_ps < branch_ps_min) return false;
        if (faults.branch_ps > branch_ps_max) return false;
        if (faults.script.len > events_max) return false;

        inline for (@typeInfo(Weights).@"struct".field_names) |name| {
            if (@field(faults.weights, name) > weight_max) return false;
        }

        for (faults.script, 0..) |*event, index| {
            if (event.kind == .none) return false;
            if (!event.valid()) return false;
            if (index == 0) continue;
            if (event.delay_ns < faults.script[index - 1].delay_ns) return false;
        }

        return true;
    }
};

pub const Disk = struct {
    atomic_sectors: u32 = atomic_sectors_default,
    error_delay_ns: u64 = 0,
    error_duration_ns: u64 = 0,
    error_read_permille: u16 = 0,
    error_write_permille: u16 = 0,
    latency_ns_max: u64 = 0,
    persist_permille: u16 = permille,
    stall_ns: u64 = 0,
    stall_permille: u16 = 0,

    fn describe(disk: *const Disk, writer: *Writer) Writer.Error!void {
        assert(disk.persist_permille <= permille);
        assert(disk.stall_permille <= permille);

        try writer.print("disk latency {d} ns, stall {d}/1000 of {d} ns, persist {d}/1000", .{
            disk.latency_ns_max,
            disk.stall_permille,
            disk.stall_ns,
            disk.persist_permille,
        });

        if (!disk.errors()) return;

        try writer.print(", errors read {d}/1000 write {d}/1000 for {d} ns after {d} ns", .{
            disk.error_read_permille,
            disk.error_write_permille,
            disk.error_duration_ns,
            disk.error_delay_ns,
        });
    }

    pub fn errors(disk: *const Disk) bool {
        return disk.error_read_permille > 0 or disk.error_write_permille > 0;
    }
};

pub const Event = extern struct {
    magic: u64 = event_magic,
    kind: EventKind = .none,
    delay_ns: u64 = 0,
    duration_ns: u64 = 0,
    target: KillTarget = .none,
    choice: u64 = 0,
    restart: u64 = 0,
    restart_delay_ns: u64 = 0,
    clock_jump_ns: i64 = 0,
    clock_slew_ppm: i64 = 0,
    disk_full_slack_kib: u64 = 0,
    memory_immune: u64 = 0,
    memory_kills: u64 = 0,
    network_delay_ns: u64 = 0,
    network_direction: Direction = .both,
    network_jitter_ns: u64 = 0,
    network_link: Link = .none,
    network_loss_permille: u64 = 0,
    network_peers: u64 = 0,
    network_reorder_permille: u64 = 0,
    pause_tree: u64 = 0,
    thread_choice: u64 = 0,
    throttle_permille: u64 = 0,

    fn describe_network(event: *const Event, writer: *Writer) Writer.Error!void {
        assert(event.kind == .network);
        assert(event.network_link != .none);

        try writer.print(" {t} {t} delay {d} ns jitter {d} ns loss {d}/1000 peers {x}" ++
            " reorder {d}/1000 for {d} ns", .{
            event.network_link,
            event.network_direction,
            event.network_delay_ns,
            event.network_jitter_ns,
            event.network_loss_permille,
            event.network_peers,
            event.network_reorder_permille,
            event.duration_ns,
        });
    }

    pub fn describe(event: *const Event, writer: *Writer) Writer.Error!void {
        assert(event.valid());
        assert(event.kind != .none);

        try writer.print("{t} after {d} ns", .{ event.kind, event.delay_ns });

        switch (event.kind) {
            .none => unreachable,
            .clock_jump => try writer.print(" by {d} ns", .{event.clock_jump_ns}),
            .clock_slew => try writer.print(" at {d} ppm for {d} ns", .{
                event.clock_slew_ppm,
                event.duration_ns,
            }),
            .disk_full => try writer.print(" leaving {d} KiB", .{event.disk_full_slack_kib}),
            .kill => try writer.print(" {t} #{d}, restart {d} after {d} ns", .{
                event.target,
                event.choice,
                event.restart,
                event.restart_delay_ns,
            }),
            .memory => try writer.print(" until {d} kills, immune {d}, for {d} ns", .{
                event.memory_kills,
                event.memory_immune,
                event.duration_ns,
            }),
            .network => try event.describe_network(writer),
            .pause => try writer.print(" {t} #{d}, tree {d}, for {d} ns", .{
                event.target,
                event.choice,
                event.pause_tree,
                event.duration_ns,
            }),
            .thread_pause => try writer.print(" {t} #{d} thread #{d} for {d} ns", .{
                event.target,
                event.choice,
                event.thread_choice,
                event.duration_ns,
            }),
            .throttle => try writer.print(" {t} #{d} to {d}/1000 for {d} ns", .{
                event.target,
                event.choice,
                event.throttle_permille,
                event.duration_ns,
            }),
        }
    }

    pub fn render(event: *const Event, writer: *Writer) Writer.Error!void {
        const fields = @typeInfo(Event).@"struct".field_names;

        assert(event.magic == event_magic);
        assert(std.mem.eql(u8, fields[0], "magic"));

        inline for (fields[1..], 0..) |name, index| {
            const value = @field(event, name);
            const separator = if (index == 0) "" else " ";

            switch (@TypeOf(value)) {
                Direction, EventKind, KillTarget, Link => {
                    try writer.print("{s}{s}={t}", .{ separator, name, value });
                },
                else => try writer.print("{s}{s}={d}", .{ separator, name, value }),
            }
        }
    }

    pub fn valid(event: *const Event) bool {
        if (event.magic != event_magic) return false;
        if (event.restart > 1) return false;
        if (event.memory_immune > 1) return false;
        if (event.memory_kills > kills_max) return false;
        if (event.network_loss_permille > permille) return false;
        if (event.network_reorder_permille > permille) return false;
        if (@abs(event.clock_slew_ppm) > slew_ppm_max) return false;

        if (event.network_delay_ns == 0) {
            if (event.network_jitter_ns + event.network_reorder_permille > 0) return false;
        }

        if (event.network_peers > peers_mask) return false;

        if (event.network_loss_permille < permille) {
            if (event.network_peers != 0) return false;
        }

        if (event.restart == 1) {
            if (!event.target.restartable()) return false;
        }

        if (event.pause_tree > 1) return false;
        if (event.throttle_permille > permille) return false;

        return switch (event.kind) {
            .kill => event.target != .none and event.target != .workload,
            .network => event.network_link != .none,
            .pause, .thread_pause => event.target != .none,
            .throttle => event.target != .none and event.throttle_permille > 0,
            .none, .clock_jump, .clock_slew, .disk_full, .memory => true,
        };
    }
};

pub const Direction = enum(u64) {
    both,
    requests,
    replies,
};

pub const EventKind = enum(u64) {
    none,
    clock_jump,
    clock_slew,
    disk_full,
    kill,
    memory,
    network,
    pause,
    thread_pause,
    throttle,
};

pub const Families = struct {
    clock: bool = true,
    cpu: bool = true,
    disk_errors: bool = true,
    disk_full: bool = true,
    disk_latency: bool = true,
    kill: bool = true,
    memory: bool = true,
    network: bool = true,
    pause: bool = true,
    thread_pause: bool = true,
    throttle: bool = true,
};

pub const KillTarget = enum(u64) {
    none,
    celery_worker,
    gunicorn_worker,
    postgres_backend,
    postmaster,
    rabbitmq,
    redis_server,
    workload,
    containerd,
    dockerd,

    fn restartable(target: KillTarget) bool {
        return switch (target) {
            .postmaster, .rabbitmq, .redis_server => true,
            .none,
            .celery_worker,
            .containerd,
            .dockerd,
            .gunicorn_worker,
            .postgres_backend,
            .workload,
            => false,
        };
    }
};

pub const Roster = enum {
    docker,
    services,

    fn targets(roster: Roster) []const KillTarget {
        const result: []const KillTarget = switch (roster) {
            .docker => &docker_targets,
            .services => &kill_targets,
        };

        assert(result.len > 0);

        return result;
    }
};

pub const Link = enum(u64) {
    none,
    postgres,
    rabbitmq,
    redis,
};

pub const Timeline = struct {
    asks: u32 = 0,
    count: u32 = 0,
    dropped: u32 = 0,
    events: [events_max]Event = undefined,
    faults: Faults = .{},
    points: [events_max]ForkPoint = undefined,
    ready_ns: u64 = 0,
    script_next: u32 = 0,
    served: Event = .{},
    waited_ns: u64 = 0,
    window_ns: u64 = 0,

    fn draw(timeline: *Timeline, stream: *Stream, now_ns: u64) void {
        var words: [event_words - 1]u64 = undefined;

        assert(timeline.served.kind == .none);

        for (&words) |*word| word.* = stream.word();

        if (timeline.remaining(now_ns) == 0) return;

        event_decode(&words, &timeline.faults.weights, timeline.faults.roster, &timeline.served);
    }

    fn remaining(timeline: *const Timeline, now_ns: u64) u64 {
        assert(now_ns >= timeline.ready_ns);

        return (timeline.ready_ns + timeline.window_ns) -| now_ns;
    }

    fn script_delay(timeline: *const Timeline, now_ns: u64) u64 {
        const script = timeline.faults.script;

        assert(script.len > 0);
        assert(timeline.script_next <= script.len);

        if (timeline.script_next == script.len) return timeline.remaining(now_ns);
        return (timeline.ready_ns + script[timeline.script_next].delay_ns) -| now_ns;
    }

    fn script_serve(timeline: *Timeline) void {
        const script = timeline.faults.script;

        assert(script.len > 0);
        assert(timeline.script_next <= script.len);

        if (timeline.script_next == script.len) return;

        timeline.served = script[timeline.script_next];
        timeline.script_next += 1;

        assert(timeline.served.kind != .none);
    }

    pub fn arm(timeline: *Timeline, faults: *const Faults, window_ns: u64) void {
        assert(faults.valid());
        assert(window_ns > 0);

        timeline.asks = 0;
        timeline.count = 0;
        timeline.dropped = 0;
        timeline.faults = faults.*;
        timeline.script_next = 0;
        timeline.served = .{};
        timeline.waited_ns = 0;
        timeline.window_ns = window_ns;
    }

    pub fn due(
        timeline: *Timeline,
        stream: *Stream,
        now_ns: u64,
        point: *const ForkPoint,
    ) void {
        assert(timeline.count <= events_max);
        assert(point.exits > 0);

        timeline.asks += 1;
        timeline.served = .{};

        if (timeline.faults.script.len > 0) {
            timeline.script_serve();
        } else {
            timeline.draw(stream, now_ns);
        }

        if (timeline.served.kind == .none) {
            timeline.served.delay_ns = timeline.remaining(now_ns);

            return;
        }

        timeline.served.delay_ns = timeline.waited_ns;

        if (timeline.count == events_max) {
            timeline.dropped += 1;
            timeline.served = .{};

            return;
        }

        timeline.events[timeline.count] = timeline.served;
        timeline.points[timeline.count] = point.*;
        timeline.count += 1;

        assert(timeline.served.valid());
    }

    pub fn wait(timeline: *Timeline, stream: *Stream, now_ns: u64) void {
        const remaining_ns = timeline.remaining(now_ns);
        const delay_ns_max = @min(remaining_ns, timeline.window_ns / event_gap_divisor);
        const word = stream.word();
        const scripted = timeline.faults.script.len > 0;

        timeline.asks += 1;
        timeline.served = .{};

        timeline.waited_ns = if (scripted) timeline.script_delay(now_ns) else word_below(
            word,
            delay_ns_max + 1,
        );

        timeline.served.delay_ns = timeline.waited_ns;

        if (!scripted) assert(timeline.waited_ns <= remaining_ns);
        assert(timeline.served.kind == .none);
    }
};

pub const Weights = struct {
    clock: u8 = 0,
    disk_full: u8 = 0,
    kill: u8 = 0,
    memory: u8 = 0,
    network: u8 = 0,
    pause: u8 = 0,
    thread_pause: u8 = 0,
    throttle: u8 = 0,

    fn describe(weights: *const Weights, writer: *Writer) Writer.Error!void {
        assert(weights.total() > 0);

        try writer.print("; event weights clock {d} disk_full {d} kill {d} memory {d}" ++
            " network {d} pause {d} thread_pause {d} throttle {d}", .{
            weights.clock,
            weights.disk_full,
            weights.kill,
            weights.memory,
            weights.network,
            weights.pause,
            weights.thread_pause,
            weights.throttle,
        });
    }

    fn total(weights: *const Weights) u32 {
        var sum: u32 = 0;

        inline for (@typeInfo(Weights).@"struct".field_names) |name| sum += @field(weights, name);

        assert(sum <= weight_max * @typeInfo(Weights).@"struct".field_names.len);

        return sum;
    }
};

const Family = enum {
    clock,
    disk_full,
    kill,
    memory,
    network,
    pause,
    thread_pause,
    throttle,
};

pub const atomic_sectors_default = 8;
pub const branch_ps_default = 1000;
pub const branch_ps_max = 10_000;
pub const branch_ps_min = 100;
pub const event_gap_divisor = 4;
pub const event_magic = 0x31544e5645545344;
pub const event_words = 10;
pub const events_max = 64;
pub const peers_mask = 0xff;
pub const permille = 1000;
pub const weight_max = 4;
const atomic_sectors_max = 64;
const kills_max = 8;
const slew_ppm_max = 1_000_000;
const swarm_error_permille_max = 20;
const swarm_hold_ns_max = 2 * std.time.ns_per_s;
const swarm_jump_ns_max = 120 * std.time.ns_per_s;
const swarm_kills_max = 3;
const swarm_latency_ns_max = 2_000_000;
const swarm_loss_permille_max = 100;
const swarm_network_delay_ns_max = 20 * std.time.ns_per_ms;
const swarm_partition_ns_max = 10 * std.time.ns_per_s;
const swarm_pause_ns_max = 10 * std.time.ns_per_s;
const swarm_rate_exponent_max = 4000;
const swarm_rate_floor_ps = 250;
const swarm_reorder_permille_max = 250;
const swarm_restart_ns_max = 2 * std.time.ns_per_s;
const swarm_slack_kib_max = 4096;
const swarm_slew_ns_max = 2 * std.time.ns_per_s;
const swarm_slew_ppm_max = 100_000;
const swarm_stall_ns_max = 100_000_000;
const swarm_stall_permille_max = 50;
const swarm_throttle_permille_max = 200;
const swarm_throttle_permille_min = 10;
const swarm_window_ns_max = 3600 * std.time.ns_per_s;
const swarm_words = swarm_disk_picks * 2 + 3 + @typeInfo(Weights).@"struct".field_names.len * 2 + 2;
const swarm_disk_picks = 6;
const docker_targets = [_]KillTarget{ .containerd, .dockerd };
const target_count = kill_targets.len + docker_targets.len + 2;

const kill_targets = [_]KillTarget{
    .celery_worker,
    .gunicorn_worker,
    .postgres_backend,
    .postmaster,
    .rabbitmq,
    .redis_server,
};

const directions = [_]Direction{ .both, .requests, .replies };
const links = [_]Link{ .postgres, .rabbitmq, .redis };

comptime {
    assert(@sizeOf(Event) == @typeInfo(Event).@"struct".field_names.len * 8);
    assert(swarm_kills_max <= kills_max);
    assert(swarm_slew_ppm_max <= slew_ppm_max);
    assert(swarm_error_permille_max <= permille);
    assert(target_count == @typeInfo(KillTarget).@"enum".field_names.len);
    assert(swarm_rate_floor_ps >= branch_ps_min);
    assert(swarm_rate_floor_ps << (swarm_rate_exponent_max / 1000) <= branch_ps_max);
    assert(swarm_throttle_permille_min > 0);
    assert(links.len + 1 == @typeInfo(Link).@"enum".field_names.len);
    assert(event_words == 2 + 8);
    assert(@import("builtin").target.cpu.arch.endian() == .little);
}

fn event_decode(
    words: *const [event_words - 1]u64,
    weights: *const Weights,
    roster: Roster,
    event: *Event,
) void {
    const total = weights.total();
    const targets = roster.targets();
    const parameters = words[1..];

    event.* = .{};

    if (total == 0) return;

    const slot = word_below(words[0], total + 1);
    if (slot == 0) return;

    switch (weights_family(weights, @intCast(slot - 1))) {
        .clock => event_decode_clock(parameters, event),
        .disk_full => {
            event.kind = .disk_full;
            event.disk_full_slack_kib = word_below(parameters[0], swarm_slack_kib_max + 1);
        },
        .kill => event_decode_kill(parameters, targets, event),
        .memory => {
            event.kind = .memory;
            event.memory_kills = word_below(parameters[0], swarm_kills_max + 1);
            event.memory_immune = @intFromBool(word_boolean(parameters[1]));
            event.duration_ns = word_below(parameters[2], swarm_hold_ns_max + 1);
        },
        .network => event_decode_network(parameters, event),
        .pause, .thread_pause, .throttle => |family| {
            event_decode_stop(family, parameters, targets, event);
        },
    }

    assert(event.kind != .none);
    assert(event.delay_ns == 0);
}

fn event_decode_clock(parameters: *const [event_words - 2]u64, event: *Event) void {
    const slewed = word_boolean(parameters[0]);
    const backward = word_boolean(parameters[2]);

    assert(event.kind == .none);

    if (!slewed) {
        const jump: i64 = @intCast(word_below(parameters[1], swarm_jump_ns_max + 1));

        event.kind = .clock_jump;
        event.clock_jump_ns = if (backward) -jump else jump;

        return;
    }

    const slew: i64 = @intCast(word_below(parameters[1], swarm_slew_ppm_max + 1));

    event.kind = .clock_slew;
    event.clock_slew_ppm = if (backward) -slew else slew;
    event.duration_ns = word_below(parameters[3], swarm_slew_ns_max + 1);

    assert(@abs(event.clock_slew_ppm) <= swarm_slew_ppm_max);
}

fn event_decode_kill(
    parameters: *const [event_words - 2]u64,
    targets: []const KillTarget,
    event: *Event,
) void {
    const target = targets[word_below(parameters[0], targets.len)];
    const restart = word_boolean(parameters[2]) and target.restartable();
    const restart_delay_ns = word_below(parameters[3], swarm_restart_ns_max + 1);

    assert(event.kind == .none);

    event.kind = .kill;
    event.target = target;
    event.choice = parameters[1] >> 32;
    event.restart = @intFromBool(restart);
    event.restart_delay_ns = if (restart) restart_delay_ns else 0;

    assert(event.target != .none);
}

fn event_decode_network(parameters: *const [event_words - 2]u64, event: *Event) void {
    const partitioned = word_boolean(parameters[1]);

    assert(event.kind == .none);

    event.kind = .network;
    event.network_link = links[word_below(parameters[0], links.len)];
    event.network_direction = directions[word_below(parameters[7], directions.len)];
    event.duration_ns = word_below(parameters[2], swarm_partition_ns_max + 1);

    if (partitioned) {
        event.network_loss_permille = permille;
        event.network_peers = word_below(parameters[3], peers_mask + 1);

        return;
    }

    event.network_delay_ns = word_below(parameters[3], swarm_network_delay_ns_max + 1);
    event.network_loss_permille = word_below(parameters[5], swarm_loss_permille_max + 1);

    if (event.network_delay_ns > 0) {
        event.network_jitter_ns = word_below(parameters[4], swarm_network_delay_ns_max + 1);
        event.network_reorder_permille = word_below(parameters[6], swarm_reorder_permille_max + 1);
    }

    assert(event.network_link != .none);
}

fn event_decode_stop(
    family: Family,
    parameters: *const [event_words - 2]u64,
    targets: []const KillTarget,
    event: *Event,
) void {
    const throttle_span = swarm_throttle_permille_max - swarm_throttle_permille_min + 1;

    assert(event.kind == .none);

    event.target = targets[word_below(parameters[0], targets.len)];
    event.choice = parameters[1] >> 32;
    event.duration_ns = word_below(parameters[3], swarm_pause_ns_max + 1);

    switch (family) {
        .pause => {
            event.kind = .pause;
            event.pause_tree = @intFromBool(word_boolean(parameters[2]));
        },
        .thread_pause => {
            event.kind = .thread_pause;
            event.thread_choice = parameters[2] >> 32;
        },
        .throttle => {
            event.kind = .throttle;

            event.throttle_permille = swarm_throttle_permille_min +
                word_below(parameters[2], throttle_span);
        },
        .clock, .disk_full, .kill, .memory, .network => unreachable,
    }

    assert(event.target != .none);
}

fn swarm_disk(stream: *Stream, window_ns: u64) Disk {
    assert(window_ns > 0);

    const latency_ns_max = swarm_pick(stream, swarm_latency_ns_max);
    const revert_permille = swarm_pick(stream, permille);
    const stall_ns = swarm_pick(stream, swarm_stall_ns_max);
    const stall_permille = swarm_pick(stream, swarm_stall_permille_max);
    const errors = stream.boolean();
    const error_read_permille = swarm_pick(stream, swarm_error_permille_max);
    const error_write_permille = swarm_pick(stream, swarm_error_permille_max);
    const error_delay_ns = stream.at_most(window_ns);
    const error_duration_ns = stream.at_most(window_ns);

    const disk: Disk = .{
        .error_delay_ns = if (errors) error_delay_ns else 0,
        .error_duration_ns = if (errors) error_duration_ns else 0,
        .error_read_permille = if (errors) @intCast(error_read_permille) else 0,
        .error_write_permille = if (errors) @intCast(error_write_permille) else 0,
        .latency_ns_max = latency_ns_max,
        .persist_permille = @intCast(permille - revert_permille),
        .stall_ns = stall_ns,
        .stall_permille = @intCast(stall_permille),
    };

    assert(disk.persist_permille <= permille);

    return disk;
}

fn swarm_pick(stream: *Stream, limit: u64) u64 {
    assert(limit > 0);

    const selector = stream.below(4);
    const drawn = stream.at_most(limit);

    const value = switch (selector) {
        0 => 0,
        1 => limit,
        else => drawn,
    };

    assert(value <= limit);

    return value;
}

fn swarm_rate(exponent: u32) u32 {
    const octaves = @as(f64, @floatFromInt(exponent)) / 1000.0;
    const rate = @round(@as(f64, swarm_rate_floor_ps) * std.math.exp2(octaves));
    const result: u32 = @intFromFloat(rate);

    assert(exponent <= swarm_rate_exponent_max);
    assert(result >= swarm_rate_floor_ps);

    return result;
}

fn weights_family(weights: *const Weights, slot: u32) Family {
    var rest = slot;

    assert(slot < weights.total());

    inline for (@typeInfo(Weights).@"struct".field_names) |name| {
        const weight = @field(weights, name);
        if (rest < weight) return @field(Family, name);

        rest -= weight;
    }

    unreachable;
}

pub fn event_byte(event: *const Event, offset: usize) u8 {
    assert(event.magic == event_magic);
    assert(offset < @sizeOf(Event));

    return std.mem.asBytes(event)[offset];
}

test "a swarm plan is a function of the random stream alone and every family varies" {
    var enabled: [10]u32 = @splat(0);
    const window_ns = 2 * std.time.ns_per_s;

    for (0..256) |seed| {
        var stream_first: Stream = .init(seed);
        var stream_second: Stream = .init(seed);
        const first = Faults.swarm(&stream_first, window_ns, .{});
        const second = Faults.swarm(&stream_second, window_ns, .{});

        try std.testing.expectEqual(first.disk, second.disk);
        try std.testing.expectEqual(first.weights, second.weights);
        try std.testing.expectEqual(first.branch_ps, second.branch_ps);
        try std.testing.expect(first.valid());
        try std.testing.expect(first.disk.error_delay_ns <= window_ns);

        enabled[0] += @intFromBool(first.disk.errors());
        enabled[1] += @intFromBool(first.weights.kill > 0);
        enabled[2] += @intFromBool(first.weights.clock > 0);
        enabled[3] += @intFromBool(first.weights.network > 0);
        enabled[4] += @intFromBool(first.weights.memory > 0);
        enabled[5] += @intFromBool(first.weights.disk_full > 0);
        enabled[6] += @intFromBool(first.weights.pause > 0);
        enabled[7] += @intFromBool(first.weights.thread_pause > 0);
        enabled[8] += @intFromBool(first.weights.throttle > 0);
        enabled[9] += @intFromBool(first.branch_ps != branch_ps_default);
    }

    for (enabled) |count| {
        try std.testing.expect(count > 32);
        try std.testing.expect(count < 224);
    }
}

test "a swarm restricted to some families leaves every other family off" {
    const names = @typeInfo(Families).@"struct".field_names;

    inline for (names) |name| {
        var alone: Families = .{};
        var without: Families = .{};
        var present: u32 = 0;

        inline for (names) |other| @field(alone, other) = false;

        @field(alone, name) = true;
        @field(without, name) = false;

        for (0..64) |seed| {
            var stream: Stream = .init(seed);
            var other_stream: Stream = .init(seed);
            const only = Faults.swarm(&stream, std.time.ns_per_s, alone);
            const rest = Faults.swarm(&other_stream, std.time.ns_per_s, without);

            present += @intFromBool(test_family_active(&only, name));

            try std.testing.expect(!test_family_active(&rest, name));

            inline for (names) |other| {
                if (comptime !std.mem.eql(u8, other, name)) {
                    try std.testing.expect(!test_family_active(&only, other));
                }
            }
        }

        try std.testing.expect(present > 8);
    }
}

test "a swarm consumes a fixed number of words whatever the words hold" {
    var prng: std.Random.DefaultPrng = .init(0x5a5a);

    for (0..256) |round| {
        var words: [swarm_words]u64 = undefined;

        for (&words) |*word| word.* = switch (round % 4) {
            0 => prng.next(),
            1 => 0,
            2 => std.math.maxInt(u64),
            else => if (prng.random().boolean()) 0 else prng.next(),
        };

        var stream: Stream = .replay(&words);
        const faults = Faults.swarm(&stream, std.time.ns_per_s, .{});

        try std.testing.expect(faults.valid());
        try std.testing.expectEqual(swarm_words, stream.position);
    }
}

test "zeroing the disk words empties the disk plan and keeps every other choice" {
    var prng: std.Random.DefaultPrng = .init(0xd15c);
    const disk_words = swarm_disk_picks * 2 + 3;

    for (0..256) |_| {
        var words: [swarm_words]u64 = undefined;

        for (&words) |*word| word.* = prng.next();

        var original_stream: Stream = .replay(&words);
        const original = Faults.swarm(&original_stream, std.time.ns_per_s, .{});

        @memset(words[0..disk_words], 0);

        var zeroed_stream: Stream = .replay(&words);
        const zeroed = Faults.swarm(&zeroed_stream, std.time.ns_per_s, .{});

        try std.testing.expectEqual(Disk{}, zeroed.disk);
        try std.testing.expectEqual(original.weights, zeroed.weights);
        try std.testing.expectEqual(original.branch_ps, zeroed.branch_ps);
    }
}

test "a roster changes only the target an event names" {
    const weights: Weights = .{ .kill = 1, .pause = 1, .thread_pause = 1, .throttle = 1 };
    var prng: std.Random.DefaultPrng = .init(0xd0c4);
    var targeted: u32 = 0;

    for (0..4000) |_| {
        var words: [event_words - 1]u64 = undefined;
        var docker: Event = undefined;
        var services: Event = undefined;

        for (&words) |*word| word.* = prng.next();

        event_decode(&words, &weights, .docker, &docker);
        event_decode(&words, &weights, .services, &services);

        try std.testing.expect(docker.valid());
        try std.testing.expect(services.valid());
        try std.testing.expectEqual(services.kind, docker.kind);
        try std.testing.expectEqual(services.duration_ns, docker.duration_ns);
        try std.testing.expectEqual(services.choice, docker.choice);
        try std.testing.expectEqual(services.throttle_permille, docker.throttle_permille);
        try std.testing.expectEqual(0, docker.restart);

        if (docker.kind == .none) continue;

        targeted += 1;

        const docker_found = std.mem.findScalar(KillTarget, &docker_targets, docker.target);
        const services_found = std.mem.findScalar(KillTarget, &kill_targets, services.target);

        try std.testing.expect(docker_found != null);
        try std.testing.expect(services_found != null);
    }

    try std.testing.expect(targeted > 3000);
}

test "the minimal words decode to no event and every family is drawn in proportion" {
    const weights: Weights = .{ .clock = 1, .disk_full = 2, .kill = 1, .memory = 1, .network = 3 };
    const minimal: [event_words - 1]u64 = @splat(2);
    var counts: [@typeInfo(EventKind).@"enum".field_names.len]u32 = @splat(0);
    var prng: std.Random.DefaultPrng = .init(0xe7e7);
    var event: Event = undefined;

    event_decode(&minimal, &weights, .services, &event);

    try std.testing.expectEqual(EventKind.none, event.kind);

    for (0..9000) |_| {
        var words: [event_words - 1]u64 = undefined;

        for (&words) |*word| word.* = prng.next();

        event_decode(&words, &weights, .services, &event);
        counts[@backingInt(event.kind)] += 1;

        try std.testing.expect(event.valid());
        try std.testing.expectEqual(0, event.delay_ns);
    }

    const jumps = counts[@backingInt(EventKind.clock_jump)];
    const clock = jumps + counts[@backingInt(EventKind.clock_slew)];

    try std.testing.expect(counts[@backingInt(EventKind.none)] > 800);
    try std.testing.expect(counts[@backingInt(EventKind.none)] < 1200);
    try std.testing.expect(clock > 800);
    try std.testing.expect(clock < 1200);
    try std.testing.expect(counts[@backingInt(EventKind.disk_full)] > 1800);
    try std.testing.expect(counts[@backingInt(EventKind.network)] > 2700);

    var timeline: Timeline = .{ .ready_ns = 100 };
    var stream_window: Stream = .init(0xe7e7);
    const point: ForkPoint = .{ .exits = 1 };
    const half_ns = 100 + std.time.ns_per_s / 2;

    timeline.arm(&.{ .weights = weights }, std.time.ns_per_s);

    for (0..events_max) |_| {
        timeline.wait(&stream_window, half_ns);

        const waited_ns = timeline.served.delay_ns;

        try std.testing.expect(waited_ns <= std.time.ns_per_s / event_gap_divisor);
        try std.testing.expectEqual(EventKind.none, timeline.served.kind);

        timeline.due(&stream_window, half_ns + waited_ns, &point);

        if (timeline.served.kind != .none) {
            try std.testing.expectEqual(waited_ns, timeline.served.delay_ns);
        }
    }

    timeline.wait(&stream_window, 100 + std.time.ns_per_s);

    try std.testing.expectEqual(0, timeline.served.delay_ns);

    timeline.due(&stream_window, 100 + std.time.ns_per_s, &point);

    try std.testing.expectEqual(EventKind.none, timeline.served.kind);
    try std.testing.expectEqual(2 * events_max + 2, timeline.asks);
}

test "a cpu rate lies between a quarter and four times the default and is drawn log-uniform" {
    var faster: u32 = 0;
    var slower: u32 = 0;

    try std.testing.expectEqual(swarm_rate_floor_ps, swarm_rate(0));
    try std.testing.expectEqual(branch_ps_default, swarm_rate(swarm_rate_exponent_max / 2));
    try std.testing.expectEqual(4 * branch_ps_default, swarm_rate(swarm_rate_exponent_max));

    for (0..swarm_rate_exponent_max + 1) |exponent| {
        const rate = swarm_rate(@intCast(exponent));

        try std.testing.expect(rate >= swarm_rate_floor_ps);
        try std.testing.expect(rate <= 4 * branch_ps_default);

        faster += @intFromBool(rate < branch_ps_default);
        slower += @intFromBool(rate > branch_ps_default);
    }

    try std.testing.expectEqual(swarm_rate_exponent_max / 2, faster);
    try std.testing.expectEqual(swarm_rate_exponent_max / 2, slower);
}

test "a halved word never moves a drawn value away from the smallest" {
    var prng: std.Random.DefaultPrng = .init(0x4a17);

    for (0..4096) |_| {
        const word = prng.next();
        const limit = 1 + prng.random().uintLessThan(u64, 1 << 40);
        const value = word_below(word, limit);
        const halved = word_below(word >> 1, limit);

        try std.testing.expect(halved <= value);
        try std.testing.expect(!word_boolean(word >> 1));
    }

    try std.testing.expectEqual(0, word_below(2, (1 << 63) - 1));
    try std.testing.expectEqual(1, word_below(2, 1 << 63));
    try std.testing.expect(!word_boolean(2));
}

test "a timeline serves a script in order with delays from ready and then none" {
    const script = [_]Event{
        .{ .kind = .kill, .delay_ns = 200, .target = .postmaster },
        .{ .kind = .clock_jump, .delay_ns = 300, .clock_jump_ns = 9 },
    };

    const faults: Faults = .{ .script = &script };
    const point: ForkPoint = .{ .exits = 1 };
    var stream: Stream = .init(1);
    var timeline: Timeline = .{ .ready_ns = 1000 };

    timeline.arm(&faults, std.time.ns_per_s);

    timeline.wait(&stream, 1100);
    try std.testing.expectEqual(100, timeline.served.delay_ns);

    timeline.due(&stream, 1200, &point);
    try std.testing.expectEqual(EventKind.kill, timeline.served.kind);
    try std.testing.expectEqual(100, timeline.served.delay_ns);

    timeline.wait(&stream, 1500);
    try std.testing.expectEqual(0, timeline.served.delay_ns);

    timeline.due(&stream, 1500, &point);
    try std.testing.expectEqual(EventKind.clock_jump, timeline.served.kind);
    try std.testing.expectEqual(0, timeline.served.delay_ns);

    timeline.wait(&stream, 1600);
    try std.testing.expectEqual(std.time.ns_per_s - 600, timeline.served.delay_ns);

    timeline.due(&stream, 1700, &point);
    try std.testing.expectEqual(EventKind.none, timeline.served.kind);
    try std.testing.expectEqual(std.time.ns_per_s - 700, timeline.served.delay_ns);
    try std.testing.expectEqual(2, timeline.count);
    try std.testing.expectEqual(6, timeline.asks);
}

test "a full timeline answers none and counts every dropped event" {
    const script: [events_max + 2]Event = @splat(.{ .kind = .disk_full });
    const faults: Faults = .{ .script = script[0..events_max] };
    const point: ForkPoint = .{ .exits = 7 };
    var stream: Stream = .init(1);
    var timeline: Timeline = .{};

    timeline.arm(&faults, std.time.ns_per_s);

    for (0..events_max) |_| timeline.due(&stream, 0, &point);

    try std.testing.expectEqual(events_max, timeline.count);
    try std.testing.expectEqual(0, timeline.dropped);

    timeline.faults.script = &script;

    timeline.due(&stream, 0, &point);

    try std.testing.expectEqual(EventKind.none, timeline.served.kind);
    try std.testing.expectEqual(1, timeline.dropped);
    try std.testing.expectEqual(events_max, timeline.count);
}

test "an event renders every guest field by name in the order the ports carry it" {
    const event: Event = .{
        .kind = .kill,
        .delay_ns = 5,
        .target = .postmaster,
        .choice = 3,
        .restart = 1,
        .restart_delay_ns = 7,
    };

    const expected = "kind=kill delay_ns=5 duration_ns=0 target=postmaster choice=3 restart=1 " ++
        "restart_delay_ns=7 clock_jump_ns=0 clock_slew_ppm=0 disk_full_slack_kib=0 " ++
        "memory_immune=0 memory_kills=0 network_delay_ns=0 network_direction=both " ++
        "network_jitter_ns=0 network_link=none network_loss_permille=0 network_peers=0 " ++
        "network_reorder_permille=0 pause_tree=0 thread_choice=0 throttle_permille=0";

    var buffer: [1024]u8 = undefined;
    var writer: Writer = .fixed(&buffer);

    try event.render(&writer);

    try std.testing.expectEqualStrings(expected, writer.buffered());
    try std.testing.expectEqual(@as(u8, 'D'), event_byte(&event, 0));
    try std.testing.expectEqual(@as(u8, 4), event_byte(&event, 8));
    try std.testing.expectEqual(@as(u8, 5), event_byte(&event, 16));
}

test "a plan or an event that netem or the guest cannot carry out is refused" {
    const reorder_without_delay: Event = .{
        .kind = .network,
        .network_link = .postgres,
        .network_reorder_permille = 10,
    };

    const jitter_without_delay: Event = .{
        .kind = .network,
        .network_jitter_ns = 1,
        .network_link = .redis,
    };

    const unlinked: Event = .{ .kind = .network };
    const respawned: Event = .{ .kind = .kill, .restart = 1, .target = .gunicorn_worker };
    const greedy: Event = .{ .kind = .memory, .memory_kills = 9 };
    const scripted_none = [_]Event{.{}};
    const torn_units: Faults = .{ .disk = .{ .atomic_sectors = 3 } };
    const heavy: Faults = .{ .weights = .{ .kill = weight_max + 1 } };
    const plain: Faults = .{};

    try std.testing.expect(!reorder_without_delay.valid());
    try std.testing.expect(!jitter_without_delay.valid());
    try std.testing.expect(!unlinked.valid());
    try std.testing.expect(!respawned.valid());
    try std.testing.expect(!greedy.valid());
    try std.testing.expect(!(Faults{ .script = &scripted_none }).valid());
    try std.testing.expect(!torn_units.valid());
    try std.testing.expect(!heavy.valid());
    try std.testing.expect(plain.valid());
    try std.testing.expect(plain.idle());
}

fn test_family_active(faults: *const Faults, comptime name: []const u8) bool {
    const disk = faults.disk;
    const latency = disk.latency_ns_max + disk.stall_ns + disk.stall_permille > 0;

    if (comptime std.mem.eql(u8, name, "cpu")) {
        return faults.branch_ps != branch_ps_default;
    } else if (comptime std.mem.eql(u8, name, "disk_errors")) {
        return disk.errors();
    } else if (comptime std.mem.eql(u8, name, "disk_latency")) {
        return latency or disk.persist_permille != permille;
    } else {
        return @field(faults.weights, name) > 0;
    }
}
