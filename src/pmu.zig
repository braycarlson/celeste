const std = @import("std");

const assert = std.debug.assert;
const Io = std.Io;
const linux = std.os.linux;

pub const Error = error{
    AffinityFailed,
    ArmFailed,
    CounterDescheduled,
    OpenFailed,
    PmuUnavailable,
    ReadFailed,
    ReadTorn,
    SmiCounted,
};

pub const Cores = struct {
    count: u16 = 0,
    list: [cpus_max]u16 = undefined,

    pub fn slice(cores: *const Cores) []const u16 {
        assert(cores.count <= cpus_max);

        return cores.list[0..cores.count];
    }
};

pub const Pmu = struct {
    armed_target: ?u64 = null,
    base_count: u64,
    fd: linux.fd_t,

    fn fcntl_checked(pmu: *const Pmu, cmd: i32, arg: usize) Error!void {
        const rc = linux.fcntl(pmu.fd, cmd, arg);

        if (linux.errno(rc) != .SUCCESS) {
            std.log.err("perf fcntl {d} failed: {t}", .{ cmd, linux.errno(rc) });

            return error.OpenFailed;
        }
    }

    fn ioctl_checked(pmu: *const Pmu, request: u32, arg: usize) Error!void {
        const rc = linux.ioctl(pmu.fd, request, arg);

        if (linux.errno(rc) != .SUCCESS) {
            std.log.err("perf ioctl {x} failed: {t}", .{ request, linux.errno(rc) });

            return error.ArmFailed;
        }
    }

    pub fn arm(pmu: *Pmu, target: u64, current: u64, margin: u64) Error!void {
        assert(margin >= skid_margin);
        assert(target > current + margin);

        if (pmu.armed_target == target) return;

        const period: u64 = target - current - margin;

        try pmu.ioctl_checked(linux.PERF.EVENT_IOC.PERIOD, @intFromPtr(&period));
        pmu.armed_target = target;
    }

    pub fn close(pmu: Pmu) void {
        _ = linux.close(pmu.fd);
    }

    pub fn count(pmu: *const Pmu) Error!u64 {
        for (0..read_attempts_max) |_| {
            var reading: Reading = undefined;
            const rc = linux.read(pmu.fd, @ptrCast(&reading), @sizeOf(Reading));
            if (rc != @sizeOf(Reading)) return error.ReadFailed;

            switch (reading.judge()) {
                .exact => return pmu.base_count + reading.value,
                .descheduled => return error.CounterDescheduled,
                .torn => continue,
            }
        }

        return error.ReadTorn;
    }

    pub fn disarm(pmu: *Pmu) Error!void {
        if (pmu.armed_target == null) return;

        const period: u64 = period_idle;

        try pmu.ioctl_checked(linux.PERF.EVENT_IOC.PERIOD, @intFromPtr(&period));
        pmu.armed_target = null;
    }

    pub fn open(pmu_type: u32, tid: linux.pid_t, base_count: u64) Error!Pmu {
        assert(tid > 0);

        var attr: linux.perf_event_attr = .{
            .type = @fromBackingInt(pmu_type),
            .config = event_branches_conditional,
            .sample_period_or_freq = period_idle,
            .read_format = read_format_times,
            .wakeup_events_or_watermark = 1,
            .flags = .{
                .disabled = true,
                .exclude_host = true,
                .exclude_hv = true,
                .pinned = true,
            },
        };

        const rc = linux.perf_event_open(&attr, 0, -1, -1, linux.PERF.FLAG.FD_CLOEXEC);

        if (linux.errno(rc) != .SUCCESS) {
            std.log.err("perf_event_open failed: {t}", .{linux.errno(rc)});

            return error.OpenFailed;
        }

        const pmu: Pmu = .{ .base_count = base_count, .fd = @intCast(rc) };
        errdefer pmu.close();

        const owner: linux.f_owner_ex = .{ .type = .TID, .pid = tid };
        const async_flag: u32 = @bitCast(linux.O{ .ASYNC = true });

        try pmu.fcntl_checked(linux.F.SETOWN_EX, @intFromPtr(&owner));
        try pmu.fcntl_checked(linux.F.SETSIG, overflow_signal_number);
        try pmu.fcntl_checked(linux.F.SETFL, async_flag);
        try pmu.ioctl_checked(linux.PERF.EVENT_IOC.ENABLE, 0);

        return pmu;
    }
};

const Reading = extern struct {
    value: u64,
    time_enabled: u64,
    time_running: u64,

    fn judge(reading: *const Reading) Judgment {
        if (reading.time_running > reading.time_enabled) return .torn;
        if (reading.time_running < reading.time_enabled) return .descheduled;

        assert(reading.time_running == reading.time_enabled);

        return .exact;
    }
};

const Judgment = enum {
    descheduled,
    exact,
    torn,
};

const Topology = struct {
    allowed: Cores = .{},
    capable: Cores = .{},
    isolated: Cores = .{},
    leaders: [cpus_max]u16 = undefined,
};

pub const cpus_max = 256;
pub const overflow_signal: linux.SIG = .IO;
pub const skid_margin = 256;
const cpus_path_atom = "/sys/bus/event_source/devices/cpu_atom/cpus";
const cpus_path_core = "/sys/bus/event_source/devices/cpu_core/cpus";
const cpus_path_isolated = "/sys/devices/system/cpu/isolated";
const cpus_path_online = "/sys/devices/system/cpu/online";
const event_branches_conditional = 0x11c4;
const freeze_path_core = "/sys/bus/event_source/devices/cpu_core/freeze_on_smi";
const freeze_path_plain = "/sys/bus/event_source/devices/cpu/freeze_on_smi";
const kernel_smm_major = 6;
const kernel_smm_minor = 17;
const overflow_signal_number = @backingInt(overflow_signal);
const period_idle: u64 = 1 << 62;
const read_attempts_max = 16;
const read_format_time_enabled = 1 << 0;
const read_format_time_running = 1 << 1;
const read_format_times = read_format_time_enabled | read_format_time_running;
const release_length_max = 64;
const sysfs_read_max = 64;
const topology_path_format = "/sys/devices/system/cpu/cpu{d}/topology/thread_siblings_list";
const type_path_core = "/sys/bus/event_source/devices/cpu_core/type";
const type_path_plain = "/sys/bus/event_source/devices/cpu/type";

comptime {
    assert(cpus_max <= linux.CPU_SETSIZE * 8);
    assert(std.math.log10_int(@as(u16, cpus_max - 1)) + 1 <= "{d}".len);
    assert(@sizeOf(Reading) == 3 * @sizeOf(u64));
    assert(@sizeOf(@FieldType(linux.utsname, "release")) == release_length_max + 1);
}

fn cores_allowed(allowed: *Cores) Error!void {
    var set: linux.cpu_set_t = @splat(0);

    assert(allowed.count == 0);

    const rc = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (linux.errno(rc) != .SUCCESS) return error.AffinityFailed;

    for (0..cpus_max) |cpu| {
        const word = set[cpu / @bitSizeOf(usize)];
        if (word >> @intCast(cpu % @bitSizeOf(usize)) & 1 == 0) continue;

        allowed.list[allowed.count] = @intCast(cpu);
        allowed.count += 1;
    }

    assert(allowed.count <= cpus_max);
}

fn cores_choose(topology: *const Topology, cores: *Cores) void {
    var eligible: Cores = .{};
    var preferred: Cores = .{};

    assert(cores.count == 0);
    assert(topology.isolated.count <= cpus_max);

    for (topology.capable.slice()) |cpu| {
        if (std.mem.findScalar(u16, topology.allowed.slice(), cpu) == null) continue;

        eligible.list[eligible.count] = cpu;
        eligible.count += 1;

        if (std.mem.findScalar(u16, topology.isolated.slice(), cpu) == null) continue;

        preferred.list[preferred.count] = cpu;
        preferred.count += 1;
    }

    const pool = if (preferred.count > 0) preferred.slice() else eligible.slice();

    for ([_]bool{ true, false }) |leading| {
        for (pool, 0..) |cpu, index| {
            if (cores_leading(topology, pool[0..index], cpu) != leading) continue;

            cores.list[cores.count] = cpu;
            cores.count += 1;
        }
    }

    assert(cores.count == pool.len);
    assert(cores.count <= topology.capable.count);
}

fn cores_leaders(io: Io, arena: std.mem.Allocator, topology: *Topology) void {
    var path_buffer: [topology_path_format.len]u8 = undefined;

    assert(topology.capable.count <= cpus_max);

    for (topology.capable.slice()) |cpu| {
        const path = std.mem.print(&path_buffer, topology_path_format, .{cpu}) catch unreachable;
        const text = sysfs_text(io, arena, path);
        const end = std.mem.findAny(u8, text, ",-") orelse text.len;

        topology.leaders[cpu] = cpu_parse(text[0..end]) catch cpu;
    }
}

fn cores_leading(topology: *const Topology, earlier: []const u16, cpu: u16) bool {
    const leader = topology.leaders[cpu];

    assert(cpu < cpus_max);
    assert(earlier.len < cpus_max);

    for (earlier) |other| {
        if (topology.leaders[other] == leader) return false;
    }

    return true;
}

fn cores_parse(text: []const u8, cores: *Cores) Error!void {
    assert(cores.count == 0);
    assert(text.len <= sysfs_read_max);

    var ranges = std.mem.splitScalar(u8, text, ',');

    for (0..text.len + 2) |_| {
        const range = ranges.next() orelse break;
        if (range.len == 0) continue;

        const dash = std.mem.findScalar(u8, range, '-') orelse range.len;
        const first = try cpu_parse(range[0..dash]);
        const last = if (dash < range.len) try cpu_parse(range[dash + 1 ..]) else first;
        if (last < first) return error.AffinityFailed;
        if (last >= cpus_max) return error.AffinityFailed;

        for (first..last + 1) |cpu| {
            if (cores.count == cpus_max) return error.AffinityFailed;

            cores.list[cores.count] = @intCast(cpu);
            cores.count += 1;
        }
    } else unreachable;
}

fn cpu_parse(text: []const u8) Error!u16 {
    return std.fmt.parseInt(u16, text, 10) catch return error.AffinityFailed;
}

fn kernel_freezes_smm(release: []const u8) bool {
    assert(release.len <= release_length_max);

    var parts = std.mem.tokenizeAny(u8, release, ".-");
    const major_text = parts.next() orelse return false;
    const minor_text = parts.next() orelse return false;
    const major = std.fmt.parseInt(u32, major_text, 10) catch return false;
    const minor = std.fmt.parseInt(u32, minor_text, 10) catch return false;

    if (major != kernel_smm_major) return major > kernel_smm_major;
    return minor >= kernel_smm_minor;
}

fn sysfs_text(io: Io, arena: std.mem.Allocator, path: []const u8) []const u8 {
    const limit: Io.Limit = .limited(sysfs_read_max);
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch return "";

    return std.mem.trim(u8, text, " \n");
}

fn sysfs_u32(text: []const u8) Error!u32 {
    assert(text.len > 0);
    assert(text.len <= sysfs_read_max);

    return std.fmt.parseInt(u32, text, 10) catch return error.PmuUnavailable;
}

pub fn cores_find(io: Io, arena: std.mem.Allocator, cores: *Cores) Error!void {
    assert(cores.count == 0);

    const performance = sysfs_text(io, arena, cpus_path_core);
    const online = sysfs_text(io, arena, cpus_path_online);
    var topology: Topology = .{};

    try cores_parse(if (performance.len > 0) performance else online, &topology.capable);
    try cores_parse(sysfs_text(io, arena, cpus_path_isolated), &topology.isolated);
    try cores_allowed(&topology.allowed);
    cores_leaders(io, arena, &topology);
    cores_choose(&topology, cores);

    if (cores.count == 0) return error.AffinityFailed;
}

pub fn cores_pin(cpus: []const u16) Error!void {
    assert(cpus.len > 0);
    assert(cpus.len <= cpus_max);

    var set: linux.cpu_set_t = @splat(0);

    for (cpus) |cpu| {
        assert(cpu < cpus_max);

        set[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    }

    linux.sched_setaffinity(0, &set) catch return error.AffinityFailed;
}

pub fn type_find(io: Io, arena: std.mem.Allocator) Error!u32 {
    const text_core = sysfs_text(io, arena, type_path_core);
    const hybrid = text_core.len > 0;
    const type_text = if (hybrid) text_core else sysfs_text(io, arena, type_path_plain);
    const freeze_path = if (hybrid) freeze_path_core else freeze_path_plain;
    const freeze_text = sysfs_text(io, arena, freeze_path);

    if (type_text.len == 0) return error.PmuUnavailable;

    const pmu_type = try sysfs_u32(type_text);
    const freeze = if (freeze_text.len > 0) try sysfs_u32(freeze_text) else 0;
    const uts = std.posix.uname();
    const release = std.mem.sliceTo(&uts.release, 0);

    if (freeze != 1) {
        std.log.err("{s} must read 1, or branch counts include system management mode; " ++
            "write 1 to it as root", .{freeze_path});

        return error.SmiCounted;
    }

    if (!kernel_freezes_smm(release)) {
        std.log.err("KVM before Linux {d}.{d} counts system management mode inside the guest, " ++
            "and this host runs {s}", .{ kernel_smm_major, kernel_smm_minor, release });

        return error.SmiCounted;
    }

    return pmu_type;
}

test "a cpu list parses ranges and singles and rejects reversed or oversized ones" {
    var cores: Cores = .{};

    try cores_parse("0-3,8,10-11", &cores);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3, 8, 10, 11 }, cores.slice());

    var empty: Cores = .{};

    try cores_parse("", &empty);
    try std.testing.expectEqual(@as(u16, 0), empty.count);

    var reversed: Cores = .{};
    var oversized: Cores = .{};

    try std.testing.expectError(error.AffinityFailed, cores_parse("3-1", &reversed));
    try std.testing.expectError(error.AffinityFailed, cores_parse("0-256", &oversized));
}

test "only kernels whose kvm keeps the counter frozen in system management mode qualify" {
    try std.testing.expect(kernel_freezes_smm("7.0.0-38-generic"));
    try std.testing.expect(kernel_freezes_smm("6.17.0"));
    try std.testing.expect(kernel_freezes_smm("6.18-rc1"));
    try std.testing.expect(!kernel_freezes_smm("6.16.9"));
    try std.testing.expect(!kernel_freezes_smm("6.8.0-85-generic"));
    try std.testing.expect(!kernel_freezes_smm("5.19.0"));
    try std.testing.expect(!kernel_freezes_smm("linux"));
    try std.testing.expect(!kernel_freezes_smm(""));
}

test "isolated cores the counting pmu does not cover are never chosen" {
    var topology: Topology = .{};
    var chosen: Cores = .{};

    try cores_parse("0-15", &topology.capable);
    try cores_parse("0-23", &topology.allowed);
    try cores_parse("8-11,16-19", &topology.isolated);

    for (0..cpus_max) |cpu| topology.leaders[cpu] = @intCast(cpu);

    cores_choose(&topology, &chosen);
    try std.testing.expectEqualSlices(u16, &.{ 8, 9, 10, 11 }, chosen.slice());

    var fallback: Cores = .{};

    topology.isolated = .{};

    try cores_parse("16-19", &topology.isolated);
    cores_choose(&topology, &fallback);
    try std.testing.expectEqualSlices(u16, topology.capable.slice(), fallback.slice());

    var all: Cores = .{};

    topology.isolated = .{};

    cores_choose(&topology, &all);
    try std.testing.expectEqualSlices(u16, topology.capable.slice(), all.slice());
}

test "cores come one per physical core first and only from the inherited affinity" {
    var topology: Topology = .{};
    var paired: Cores = .{};

    try cores_parse("0-15", &topology.capable);
    try cores_parse("0-23", &topology.allowed);

    for (0..cpus_max) |cpu| topology.leaders[cpu] = @intCast(cpu & ~@as(usize, 1));

    cores_choose(&topology, &paired);

    try std.testing.expectEqual(16, paired.count);

    for (paired.list[0..8], 0..) |cpu, index| {
        try std.testing.expect(cores_leading(&topology, paired.list[0..index], cpu));
    }

    for (paired.list[8..16], 8..) |cpu, index| {
        try std.testing.expect(!cores_leading(&topology, paired.list[0..index], cpu));
    }

    var narrowed: Cores = .{};

    topology.allowed = .{};

    try cores_parse("2-3,9,20", &topology.allowed);
    cores_choose(&topology, &narrowed);
    try std.testing.expectEqualSlices(u16, &.{ 2, 9, 3 }, narrowed.slice());

    var efficient: Cores = .{};

    topology.allowed = .{};

    try cores_parse("16-23", &topology.allowed);
    cores_choose(&topology, &efficient);
    try std.testing.expectEqual(0, efficient.count);

    var spread: Cores = .{};

    topology.allowed = .{};

    try cores_parse("0-15", &topology.allowed);

    for (0..cpus_max) |cpu| topology.leaders[cpu] = @intCast(cpu % 8);

    cores_choose(&topology, &spread);
    try std.testing.expectEqualSlices(u16, topology.capable.slice(), spread.slice());
}

test "the affinity read back is the affinity just pinned" {
    var original: Cores = .{};
    var single: Cores = .{};

    try cores_allowed(&original);
    try std.testing.expect(original.count > 0);

    const cpu = original.list[original.count - 1];

    try cores_pin(&.{cpu});
    defer cores_pin(original.slice()) catch unreachable;

    try cores_allowed(&single);
    try std.testing.expectEqualSlices(u16, &.{cpu}, single.slice());
}

test "a reading whose running time passes its enabled time is torn and is read again" {
    const exact: Reading = .{ .value = 9, .time_enabled = 500, .time_running = 500 };
    const descheduled: Reading = .{ .value = 9, .time_enabled = 501, .time_running = 500 };
    const torn: Reading = .{ .value = 9, .time_enabled = 500, .time_running = 731 };

    try std.testing.expectEqual(Judgment.exact, exact.judge());
    try std.testing.expectEqual(Judgment.descheduled, descheduled.judge());
    try std.testing.expectEqual(Judgment.torn, torn.judge());
}

test "a counter that cannot run on its core fails its read instead of counting less" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    var atom: Cores = .{};
    var core: Cores = .{};

    try cores_parse(sysfs_text(io, arena, cpus_path_atom), &atom);
    try cores_parse(sysfs_text(io, arena, cpus_path_core), &core);

    if (atom.count == 0) return error.SkipZigTest;
    if (core.count == 0) return error.SkipZigTest;

    const pmu_type = try type_find(io, arena);
    var affinity: linux.cpu_set_t = undefined;

    try std.testing.expectEqual(0, linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &affinity));
    defer linux.sched_setaffinity(0, &affinity) catch @panic("the test lost its affinity");

    try cores_pin(atom.slice()[0..1]);

    const stray = try Pmu.open(pmu_type, linux.gettid(), 0);
    defer stray.close();

    try std.testing.expectError(error.CounterDescheduled, stray.count());
    try cores_pin(core.slice()[0..1]);

    const steady = try Pmu.open(pmu_type, linux.gettid(), 0);
    defer steady.close();

    try std.testing.expectEqual(0, try steady.count());
}
