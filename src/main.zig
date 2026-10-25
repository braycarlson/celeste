const std = @import("std");

const dst = @import("dst");

const boot = @import("boot.zig");
const choices_module = @import("choices.zig");
const coverage_module = @import("coverage.zig");
const cpuid = @import("cpuid.zig");
const faults_module = @import("faults.zig");
const kvm = @import("kvm.zig");
const lapic_module = @import("lapic.zig");
const machine_module = @import("machine.zig");
const pmu_module = @import("pmu.zig");
const serial_module = @import("serial.zig");
const snapshot = @import("snapshot.zig");
const step = @import("step.zig");
const verdict_module = @import("verdict.zig");
const virtio_block = @import("virtio_block.zig");

const assert = std.debug.assert;
const Catalog = verdict_module.Catalog;
const Choices = choices_module.Choices;
const Coverage = coverage_module.Coverage;
const Io = std.Io;
const linux = std.os.linux;
const Event = faults_module.Event;
const Faults = faults_module.Faults;
const ForkPoint = snapshot.ForkPoint;
const Machine = machine_module.Machine;
const Outcome = machine_module.Outcome;
const Pmu = pmu_module.Pmu;
const Serial = serial_module.Serial;
const Stop = machine_module.Stop;
const Stream = choices_module.Stream;
const StreamName = choices_module.StreamName;
const Timeline = faults_module.Timeline;
const Verdict = verdict_module.Verdict;
const VirtioBlock = virtio_block.VirtioBlock;

const Attempt = struct {
    consumed: [choices_module.stream_count]u64 = @splat(0),
    coverage_fresh: [coverage_module.fresh_max]u32 = undefined,
    coverage_fresh_count: u32 = 0,
    coverage_fresh_points: [coverage_module.fresh_max]?ForkPoint = undefined,
    debug: DebugOutput = .{},
    detail: [detail_max]u8 = undefined,
    detail_length: usize = 0,
    event_points: [faults_module.events_max]ForkPoint = undefined,
    events: [faults_module.events_max]Event = undefined,
    events_count: u32 = 0,
    events_dropped: u32 = 0,
    failure: ?anyerror = null,
    fork_positions: [choices_module.stream_count]?u64 = @splat(null),
    guidance: [coverage_module.guidance_max]coverage_module.Maximum = undefined,
    guidance_count: u32 = 0,
    outcome: Outcome = std.mem.zeroes(Outcome),
    probe: Probe = .{},
    verdict: Verdict = .{},

    fn passed(attempt: *const Attempt) bool {
        return attempt.failure == null and attempt.verdict.passed();
    }

    fn same(attempt: *const Attempt, other: *const Attempt) bool {
        const failure = attempt.failure orelse {
            if (other.failure != null) return false;
            return outcome_same(&attempt.outcome, &other.outcome);
        };

        const other_failure = other.failure orelse return false;
        if (failure != other_failure) return false;
        return outcome_same(&attempt.outcome, &other.outcome);
    }
};

const Batch = struct {
    candidates: ?*[shrink_parallel_max]Choices = null,
    catalog: ?*Catalog = null,
    choices: []const Choices = &.{},
    concurrency: usize,
    cores: []const u16,
    debug: ?*Attempt = null,
    explore: ?*Explore = null,
    fork_points: []const ForkPoint = &.{},
    fork_seeds: []const u64 = &.{},
    holder_stats: ?*HolderStats = null,
    holders_max: u32 = 0,
    likelihood: ?*Likelihood = null,
    plans: []const Faults = &.{},
    pool: ?std.mem.Allocator = null,
    replay_all: bool = false,
    replay_max: u32 = 0,
    replays: []Attempt,
    results: []Attempt,
    seeds: []const u64,
    shrink_runs_max: u32 = 0,
    shrunk: []Shrunk = &.{},
};

const Boot = struct {
    clock_seconds: u64,
    index: u32,
};

const Booted = struct {
    guest: Guest,
    machine: Machine,
    pmu: Pmu,

    fn deinit(booted: *Booted, context: *const Context) void {
        assert(booted.guest.count > 0);

        if (context.host.pmu_type != null) booted.pmu.close();

        booted.guest.close();
    }

    fn init(booted: *Booted, context: *const Context, boot_next: Boot) !void {
        const session = context.session;

        assert(boot_next.index < cycles_max);

        booted.guest = try guest_create(context.host, context.hardware.memory, session.cpus);
        errdefer booted.guest.close();

        try guest_boot(context, &booted.guest, boot_next.index);

        if (context.host.pmu_type) |pmu_type| {
            booted.pmu = try Pmu.open(pmu_type, linux.gettid(), 0);
        }

        machine_init(&booted.machine, context, &booted.guest, &booted.pmu, boot_next);

        assert(booted.machine.cpus_count == session.cpus);
    }

    fn report(booted: *const Booted, context: *const Context, err: anyerror) !void {
        const session = context.session;

        assert(booted.machine.current < booted.guest.count);

        if (err == error.GuestStalled) {
            std.log.err("the guest made no exit and retired no branch for {d} ms", .{
                session.watchdog_ns / std.time.ns_per_ms,
            });
        }

        switch (err) {
            error.GuestStalled, error.Interrupted => {
                try vcpu_dump(booted.guest.vcpus[booted.machine.current], context.hardware.memory);
            },
            else => {},
        }
    }
};

const Branch = struct {
    interrupt_injected: bool,
    interrupt_window: bool,
    outcome: Outcome,
};

const Config = struct {
    cmdline: []const u8,
    cmdline_reboot: []const u8 = "",
    cores_max: u16 = 0,
    cpus: u8 = 1,
    crash_delay_ns: ?u64 = null,
    crash_exit: ?u64 = null,
    crash_window_ns: u64 = 0,
    debug_command: []const u8 = "",
    debug_exit: ?u64 = null,
    debug_ns: u64 = debug_ns_default,
    disk: []const u8 = "",
    disk_cache_sectors: u32 = disk_cache_sectors_default,
    disk_output: []const u8 = "",
    eventually_ns: u64 = 0,
    explore_guidance: bool = true,
    explore_output: []const u8 = "",
    explore_runs: u32 = 0,
    explore_uniform: bool = false,
    fault_families: faults_module.Families = .{},
    fault_roster: faults_module.Roster = .services,
    fault_plan: ?Faults = null,
    fault_window_ns: u64 = fault_window_ns_default,
    faults: bool = false,
    initrd: []const u8 = "",
    jitter_ns_max: u64 = 0,
    kernel: []const u8,
    likelihood_points: u32 = 0,
    likelihood_runs: u32 = likelihood_runs_default,
    memory_mib: u64 = 512,
    preemption: bool = false,
    preflight: bool = false,
    replay_max: u32 = 0,
    reproducer: []const u8 = "",
    runner: bool = false,
    seed: u64 = 0,
    seeds: u64 = 1,
    shrink_output: []const u8 = "",
    shrink_runs_max: u32 = shrink_runs_max_default,
    snapshot_holders_max: u32 = snapshot_holders_max_default,
    time_limit_ns: u64 = time_limit_ns_default,
    transcript_output: []const u8 = "",
    watchdog_ns: u64 = watchdog_ns_default,
};

const Child = struct {
    job: u32,
    pid: linux.pid_t,
};

const Context = struct {
    hardware: *const Hardware,
    host: *const Host,
    session: *const Session,
};

const Cycle = struct {
    outcome: Outcome,
    stop: Stop,
};

const Debug = struct {
    command: []const u8,
    exit: u64,
    ns: u64,
    output: *DebugOutput,
};

const DebugOutput = struct {
    bytes: [debug_output_max]u8 = undefined,
    exit: u64 = 0,
    length: u32 = 0,
    time_ns: u64 = 0,
};

const Entry = struct {
    choices: Choices,
    fork_points: []const ForkPoint,
    picks: u32 = 0,
};

const Explore = struct {
    best: [coverage_module.guidance_max]coverage_module.Maximum = undefined,
    best_count: u32 = 0,
    corpus: []Entry,
    corpus_count: u32 = 0,
    corpus_full: bool = false,
    forks: u32 = 0,
    forks_diverged: u32 = 0,
    forks_past_ready: u32 = 0,
    found: ?Found = null,
    found_pool: std.heap.FixedBufferAllocator,
    global: *coverage_module.Bits,
    guidance: bool,
    history: []u64,
    history_count: u32 = 0,
    pool: std.mem.Allocator,
    prng: std.Random.DefaultPrng,
    ready: ForkPoint = .{},
    runs: u32 = 0,
    runs_max: u32,
    seed_next: u64,
    uniform: bool,
};

const ExploreJob = struct {
    entry: ?*const Entry = null,
    fork_point: ForkPoint = .{},
    fork_seed: u64 = 0,
    seed: u64,
};

const Fan = struct {
    batch: *const Batch,
    catalog: *const Catalog,
    context: *const Context,
    holders: *Holders,
    machine: *Machine,
    plan: *const Plan,
    scratch: *verdict_module.Scratch,
    slots: []Slot,
    states: *const snapshot.VcpuStates,
    transcript: *Io.Writer,
};

const Found = struct {
    attempt: Attempt,
    choices: Choices,
    run: u32,
};

const Guest = struct {
    count: u32 = 0,
    vcpus: [machine_module.cpus_max]kvm.Vcpu = undefined,
    vm: kvm.Vm,

    fn close(guest: *const Guest) void {
        assert(guest.count <= machine_module.cpus_max);

        for (guest.vcpus[0..guest.count]) |vcpu| vcpu.close();

        guest.vm.close();
    }

    fn view(guest: *const Guest) []const kvm.Vcpu {
        assert(guest.count > 0);

        return guest.vcpus[0..guest.count];
    }
};

const Hardware = struct {
    block: ?*VirtioBlock,
    coverage: *Coverage,
    events: *Stream,
    guidance: *coverage_module.Guidance,
    input_signal: ?linux.fd_t,
    jitter: *Stream,
    memory: []align(kvm.page_size) u8,
    schedule: *Stream,
    serial: *Serial,
    serial_debug: *Serial,
    timeline: *Timeline,
    watchdog: ?machine_module.Watchdog,
    workload: *Stream,
};

const Holder = struct {
    key: u64,
    pid: linux.pid_t = 0,
    ready: bool = false,
    request: linux.fd_t,
    response: linux.fd_t,
    used: u64,
};

const HolderEnds = struct {
    request: linux.fd_t,
    response: linux.fd_t,
};

const HolderReply = extern struct {
    failure: u32 = 0,
    pid: i32 = 0,
};

const HolderRequest = extern struct {
    fork_seed: u64,
    margin: u64,
    core: u32,
    slot: u32,
};

const HolderSpawn = struct {
    ends: HolderEnds,
    fan: *const Fan,
    job: *const Job,
    streams: *const [choices_module.stream_count]Stream,
};

const HolderState = enum {
    dead,
    ready,
    starting,
};

const HolderStats = struct {
    served: u32 = 0,
    spawned: u32 = 0,
};

const Holders = struct {
    entries: []?Holder,
    stats: HolderStats = .{},
    tick: u64 = 0,
};

const Host = struct {
    cpuid: *const kvm.Cpuid2,
    exception_entry: u64,
    handle: kvm.Kvm,
    msr_list: *const kvm.MsrList,
    pmu_type: ?u32,
};

const Likelihood = struct {
    exits: []u64,
    failures: []u32,
    jobs: []Job,
    probe: *Attempt,
    results: []Attempt,
    signature: u64 = 0,
    varied: []bool,
};

const Plan = struct {
    cmdline: []const u8,
    cmdline_reboot: []const u8,
    config: *const Config,
    initrd: []const u8,
    kernel: []const u8,
    stop: *const std.atomic.Value(bool),
};

const Session = struct {
    branch_exits: []const u64,
    cmdline: []const u8,
    cmdline_reboot: []const u8,
    cpus: u8,
    crash_delay_ns: ?u64,
    crash_exit: ?u64,
    debug: ?*const Debug,
    disk: []const u8,
    disk_cache_sectors: u32,
    disk_output: []const u8,
    fault_window_ns: u64,
    faults: Faults,
    fork_point: ?ForkPoint,
    fork_seed: u64,
    guest_seed: u64,
    initrd: []const u8,
    jitter_ns_max: u64,
    kernel: []const u8,
    memory_size: usize,
    preemption: bool,
    probe: ?*Probe,
    seed: u64,
    serial_output: *Io.Writer,
    stdin_thread: bool,
    step_margin: u64,
    stop: *const std.atomic.Value(bool),
    time_limit_ns: u64,
    transcript_output: []const u8,
    watchdog_ns: u64,
};

const Slot = struct {
    attempt: Attempt,
    pid: std.atomic.Value(i32),
};

const Runner = struct {
    holders: *Holders,
    jobs: []Job,
    scratch: *verdict_module.Scratch,
    slots: []Slot,
    transcript: *Io.Writer,
};

const Shrunk = struct {
    attempt: Attempt = .{},
    choices: Choices = .{},
    interrupted: bool = false,
    replayed: bool = false,
    runs: u32 = 0,
    shrunk: bool = false,
};

const Job = struct {
    choices: ?*const Choices = null,
    fork_point: ?ForkPoint = null,
    fork_seed: u64 = 0,
    index: u32,
    margin: u64,
    result: u32,
    role: Role = .run,
    seed: ?u64 = null,
};

const Probe = struct {
    count: u32 = 0,
    exits: [probe_max]u64 = undefined,
    points: [probe_max]ForkPoint = undefined,
    times: [probe_max]u64 = undefined,
};

const Role = enum {
    debug,
    likelihood,
    probe,
    run,
    shrink,
};

const Rig = struct {
    block: VirtioBlock = undefined,
    coverage: *Coverage = undefined,
    disk: ?[]align(kvm.page_size) u8 = null,
    events: Stream = .init(0),
    guidance: coverage_module.Guidance = .{},
    handle: kvm.Kvm = undefined,
    host: Host = undefined,
    input_signal: ?linux.fd_t = null,
    jitter: Stream = .init(0),
    memory: []align(kvm.page_size) u8 = &.{},
    schedule: Stream = .init(0),
    serial: Serial = undefined,
    serial_debug: Serial = undefined,
    serial_debug_writer: Io.Writer = undefined,
    timeline: Timeline = .{},
    watchdog: ?machine_module.Watchdog = null,
    workload: Stream = .init(0),

    fn deinit(rig: *Rig) void {
        assert(rig.memory.len > 0);

        if (rig.watchdog) |watchdog| watchdog.stop();

        kvm.guest_memory_free(rig.memory);
        rig.handle.close();

        if (rig.disk) |image| kvm.guest_memory_free(image);
    }

    fn hardware(rig: *Rig) Hardware {
        assert(rig.memory.len > 0);

        return .{
            .block = if (rig.disk != null) &rig.block else null,
            .coverage = rig.coverage,
            .events = &rig.events,
            .guidance = &rig.guidance,
            .input_signal = rig.input_signal,
            .jitter = &rig.jitter,
            .memory = rig.memory,
            .schedule = &rig.schedule,
            .serial = &rig.serial,
            .serial_debug = &rig.serial_debug,
            .timeline = &rig.timeline,
            .watchdog = rig.watchdog,
            .workload = &rig.workload,
        };
    }

    fn init(rig: *Rig, io: Io, arena: std.mem.Allocator, session: *const Session) !void {
        assert(session.memory_size % kvm.page_size == 0);
        assert(rig.memory.len == 0);

        var cores: pmu_module.Cores = .{};

        rig.disk = if (session.disk.len > 0) try disk_map(io, session.disk) else null;
        errdefer if (rig.disk) |image| kvm.guest_memory_free(image);

        rig.handle = try kvm.Kvm.open();
        errdefer rig.handle.close();

        rig.memory = try kvm.guest_memory_alloc(session.memory_size);
        errdefer kvm.guest_memory_free(rig.memory);

        try pmu_module.cores_find(io, arena, &cores);
        try pmu_module.cores_pin(cores.slice());

        rig.host = try host_probe(io, arena, rig.handle, session);
        rig.coverage = try arena.create(Coverage);
        rig.coverage.* = .{ .bits = @splat(0) };
        rig.events = .init(session.seed ^ events_seed_salt);
        rig.jitter = .init(session.seed ^ jitter_seed_salt);
        rig.schedule = .init(session.seed ^ schedule_seed_salt);
        rig.serial = .{ .output = session.serial_output };
        rig.serial_debug_writer = .fixed(try arena.alloc(u8, debug_transcript_size));

        rig.serial_debug = .{
            .irq = serial_module.debug_irq,
            .output = &rig.serial_debug_writer,
            .port_base = serial_module.debug_port_base,
        };

        rig.timeline.arm(&session.faults, session.fault_window_ns);
        rig.workload = .init(session.seed ^ workload_seed_salt);

        if (rig.disk) |image| try block_init(&rig.block, arena, image, session);

        rig.input_signal = if (session.stdin_thread) try input_start(&rig.serial) else null;

        if (session.watchdog_ns > 0) rig.watchdog = try machine_module.watchdog_start();
    }
};

const apic_base_bootstrap = 1 << 8;
const apic_base_enable = 1 << 11;
const block_seed_salt = 0x626c6f636b;
const choices_pool_size = 1 << 30;
const cmdline_phase_max = 64;
const choices_size_max = choices_module.words_max * choices_module.stream_count * 8;
const clock_epoch_seconds = 1767225600;
const config_path_default = "celeste.zon";
const crash_seed_salt = 0x6372617368;
const cycles_max = 8;
const debug_ns_default = std.time.ns_per_s;
const debug_output_max = 4096;
const debug_transcript_size = 64 << 10;
const describe_max = 4096;
const event_missing = "the guest never echoed an event the machine served";
const events_seed_salt = 0x6576656e7473;
const explore_corpus_max = 512;
const explore_newest_odds = 4;
const explore_newest_picks_max = 8;
const explore_parallel_max = 8;
const explore_points_max = coverage_module.fresh_max + coverage_module.guidance_max;
const explore_seed_salt = 0x6578706c6f7265;
const detail_max = 256;
const smaps_path_max = 64;
const smaps_private_dirty = "Private_Dirty:";
const smaps_size_max = 4096;
const disk_cache_sectors_default = 65536;
const fault_window_ns_default = std.time.ns_per_s;
const faults_seed_salt = 0x6661756c7473;
const file_write_chunk = 1 << 24;
const identity_map_addr = 0xfffbc000;
const input_bytes_max = 1 << 48;
const holder_requests_max = 1 << 32;
const interrupted_retries_max = 64;
const jitter_seed_salt = 0x6a6974746572;
const likelihood_runs_default = 8;
const likelihood_runs_max = 64;
const likelihood_seed_salt = 0x6c696b656c79;
const memory_mib_max = boot.memory_size_max >> 20;
const memory_mib_min = 64;
const msr_apic_base = 0x1b;
const path_max = 4096;
const probe_max = 32;
const reap_attempts_max = 1 << 16;
const reboot_gap_ns = 30 * std.time.ns_per_s;
const reproducer_buffer_size = 4096;
const runner_boot_seed = 0;
const schedule_seed_salt = 0x7363686564756c65;
const seeds_max = 1 << 16;
const shrink_parallel_max = 8;
const shrink_runs_max_default = 64;
const shrink_signatures_max = 16;
const snapshot_holders_limit = 256;
const snapshot_holders_max_default = 8;
const stack_words_dumped = 8;
const step_margin_replay = 2048;
const time_limit_ns_default = 600 * std.time.ns_per_s;
const transcript_size_max = 64 << 20;
const watchdog_ns_default = 30 * std.time.ns_per_s;
const workload_seed_salt = 0x776f726b6c6f6164;
const tss_addr = 0xfffbd000;

comptime {
    assert(machine_module.cpus_max == snapshot.vcpus_max);
    assert(machine_module.cpus_max <= boot.mptable_cpus_max);

    assert(choices_size_max * (shrink_parallel_max + shrink_signatures_max + 1) <
        choices_pool_size);

    assert(choices_pool_size % kvm.page_size == 0);
    assert(transcript_size_max % kvm.page_size == 0);
}

const msrs_initial = [_]kvm.MsrEntry{
    .{
        .index = kvm.msr_ia32_misc_enable,
        .reserved = 0,
        .data = kvm.msr_ia32_misc_enable_fast_string,
    },
};

fn attempt_judge(
    scratch: *verdict_module.Scratch,
    transcript: []const u8,
    catalog: *const Catalog,
    attempt: *Attempt,
) !void {
    assert(attempt.detail_length == 0);
    assert(attempt.events_count <= faults_module.events_max);

    attempt.verdict = try verdict_module.judge(scratch, transcript, catalog);

    const echoes_count = @min(attempt.verdict.event_echoes, scratch.event_echoes.len);
    const echoes = scratch.event_echoes[0..echoes_count];
    const events = attempt.events[0..attempt.events_count];
    const overflowed = attempt.verdict.event_echoes > echoes_count;
    const mismatch = verdict_module.event_mismatch(events, echoes);
    const misread = if (mismatch) |index| attempt_misread(echoes, index) else event_missing;
    const failed = overflowed or mismatch != null;
    const reported = if (failed) misread else attempt.verdict.detail;
    const detail = reported[0..@min(reported.len, detail_max)];

    @memcpy(attempt.detail[0..detail.len], detail);

    attempt.detail_length = detail.len;
    attempt.verdict.detail = "";

    assert(attempt.detail_length <= detail_max);

    if (attempt.verdict.agent_errors > 0) return error.AgentFailed;
    if (failed) return error.EventMismatch;
}

fn attempt_misread(echoes: []const []const u8, index: u32) []const u8 {
    assert(index <= echoes.len);
    assert(echoes.len <= faults_module.events_max);

    if (index == echoes.len) return event_missing;
    return echoes[index];
}

fn attempt_signature(attempt: *const Attempt) u64 {
    const detail = attempt.detail[0..attempt.detail_length];
    const message = detail[0 .. std.mem.find(u8, detail, " | ") orelse detail.len];
    const failure = if (attempt.failure) |err| @errorName(err) else "";
    const checked = attempt.verdict.checked;
    const lost = attempt.verdict.lost > 0;
    const flags = [_]u8{ @intFromBool(checked), @intFromBool(lost) };
    var hasher: std.hash.Wyhash = .init(0);

    assert(attempt.detail_length <= detail_max);
    assert(message.len <= detail.len);

    hasher.update(failure);
    hasher.update(&flags);
    hasher.update(message);

    return hasher.final();
}

fn block_init(
    block: *VirtioBlock,
    arena: std.mem.Allocator,
    image: []align(kvm.page_size) u8,
    session: *const Session,
) !void {
    assert(image.len % virtio_block.sector_size == 0);

    const sectors = image.len / virtio_block.sector_size;
    const words = std.math.divCeil(usize, sectors, 64) catch unreachable;
    const logged = try arena.alloc(u64, words);
    const entries = try arena.alloc(virtio_block.LogEntry, session.disk_cache_sectors);

    @memset(logged, 0);

    block.* = .{
        .faults = session.faults.disk,
        .image = image,
        .log = .{ .entries = entries, .logged = logged },
        .stream = .init(session.seed ^ block_seed_salt),
    };
}

fn boot_at(index: u32, clock_ns: u64) Boot {
    return .{ .clock_seconds = clock_epoch_seconds + clock_ns / std.time.ns_per_s, .index = index };
}

fn branch_attach(
    host: *const Host,
    machine: *Machine,
    states: *const snapshot.VcpuStates,
    guest: *Guest,
    pmu: *Pmu,
) !void {
    assert(machine.pause_exit == null);
    assert(machine.cpus_count == states.count);

    guest.* = try guest_create(host, machine.memory, @intCast(machine.cpus_count));
    errdefer guest.close();

    try states.apply_all(guest.view());

    if (host.pmu_type) |pmu_type| pmu.* = try Pmu.open(pmu_type, linux.gettid(), machine.branches);

    machine.resume_on(guest.view(), if (host.pmu_type != null) pmu else null);
}

fn branch_child(
    context: *const Context,
    machine: *Machine,
    states: *const snapshot.VcpuStates,
    pipe: linux.fd_t,
) noreturn {
    const outcome = branch_continue(context, machine, states) catch |err| {
        std.log.err("branch failed: {t}", .{err});

        linux.exit_group(1);
    };

    const bytes = std.mem.asBytes(&outcome);
    const written = linux.write(pipe, bytes.ptr, bytes.len);

    linux.exit_group(if (written == bytes.len) 0 else 1);
}

fn branch_continue(
    context: *const Context,
    machine: *Machine,
    states: *const snapshot.VcpuStates,
) !Outcome {
    const watched = context.session.watchdog_ns > 0;
    var hardware = context.hardware.*;

    hardware.watchdog = if (watched) try machine_module.watchdog_start() else null;
    defer if (hardware.watchdog) |timer| timer.stop();

    const child: Context = .{
        .hardware = &hardware,
        .host = context.host,
        .session = context.session,
    };

    machine.watchdog = hardware.watchdog;

    const first = try branch_resume(&child, machine, states);
    return cycles_continue(&child, first);
}

fn branch_debug(machine: *Machine, context: *const Context, debug: *const Debug) !Cycle {
    const serial = context.hardware.serial_debug;
    const output = debug.output;

    assert(machine.pause_exit == null);
    assert(debug.command.len < serial_module.receive_ring_size);

    if (debug.exit > machine.exits) try branch_pause(machine, debug.exit);

    assert(machine.exits >= debug.exit);

    output.exit = machine.exits;
    output.time_ns = machine.time_ns;
    serial.output.end = 0;

    for (debug.command) |byte| serial.receive(byte);

    serial.receive('\n');
    machine.crash_time_ns = null;
    machine.power_loss_ignored = true;
    machine.time_limit_ns = machine.time_ns + debug.ns;

    _ = machine.run() catch |err| switch (err) {
        error.TimeLimitExceeded => {},
        error.SerialOutputFailed => if (serial.output.end == serial.output.buffer.len) {
            return error.DebugOutputFull;
        } else {
            return err;
        },
        else => |other| return other,
    };

    const written = serial.output.buffered();
    const length = @min(written.len, output.bytes.len);

    @memcpy(output.bytes[0..length], written[0..length]);
    output.length = @intCast(written.len);

    assert(output.length >= length);

    return .{ .outcome = machine.outcome(), .stop = .shutdown };
}

fn branch_fork(machine: *Machine, context: *const Context) !Branch {
    var vcpus: [machine_module.cpus_max]kvm.Vcpu = undefined;
    var states: snapshot.VcpuStates = .{};

    try states.capture_all(machine.vcpus_view(&vcpus), context.host.msr_list);

    const state = &states.states[machine.current];

    var branch: Branch = .{
        .interrupt_injected = state.events.interrupt.injected != 0,
        .interrupt_window = state.request_interrupt_window != 0,
        .outcome = undefined,
    };

    var pipe: [2]linux.fd_t = undefined;

    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) {
        return error.BranchFailed;
    }

    const rc = linux.fork();

    if (linux.errno(rc) != .SUCCESS) {
        _ = linux.close(pipe[0]);
        _ = linux.close(pipe[1]);

        return error.BranchFailed;
    }

    if (rc == 0) {
        _ = linux.close(pipe[0]);

        branch_child(context, machine, &states, pipe[1]);
    }

    _ = linux.close(pipe[1]);
    defer _ = linux.close(pipe[0]);

    branch.outcome = try branch_wait(@intCast(rc), pipe[0]);

    return branch;
}

fn branch_hold(
    context: *const Context,
    machine: *Machine,
    states: *const snapshot.VcpuStates,
    spawn: *const HolderSpawn,
) !Cycle {
    const point = &context.session.fork_point.?;
    var guest: Guest = undefined;
    var pmu: Pmu = undefined;

    assert(machine.pause_exit == null);
    assert(context.session.crash_exit == null);

    try branch_attach(context.host, machine, states, &guest, &pmu);
    defer guest.close();
    defer if (context.host.pmu_type != null) pmu.close();

    const counter: ?*Pmu = if (context.host.pmu_type != null) &pmu else null;
    const paused = try branch_switch_pause(machine, point);
    if (paused != .paused) return .{ .outcome = machine.outcome(), .stop = paused };

    holder_spawn(machine, context, spawn, &guest, counter);
    branch_streams_fork(context.hardware, context.session.fork_seed);

    const stop = try machine_drive(machine, null);
    return .{ .outcome = machine.outcome(), .stop = stop };
}

fn branch_pause(machine: *Machine, exit: u64) !void {
    assert(exit > machine.exits);
    assert(machine.pause_exit == null);

    machine.pause_exit = exit;

    const stop = try machine.run();

    machine.pause_exit = null;

    if (stop == .paused) return;

    std.log.err("the run stopped with {t} at exit {d}, before exit {d}", .{
        stop,
        machine.exits,
        exit,
    });

    return error.PauseExitMissed;
}

fn branch_probe(machine: *Machine, probe: *Probe) !Cycle {
    const count = probe.count;

    assert(count > 0);
    assert(count <= probe_max);

    for (0..count) |index| {
        try branch_pause(machine, probe.exits[index]);
        machine.fork_point(&probe.points[index]);
        probe.times[index] = machine.time_ns;
    }

    return .{ .outcome = machine.outcome(), .stop = .shutdown };
}

fn branch_resume(
    context: *const Context,
    machine: *Machine,
    states: *const snapshot.VcpuStates,
) !Cycle {
    const crash_exit = context.session.crash_exit;
    var guest: Guest = undefined;
    var pmu: Pmu = undefined;

    assert(machine.pause_exit == null);
    if (crash_exit) |exit| assert(exit >= machine.exits);

    try branch_attach(context.host, machine, states, &guest, &pmu);
    defer guest.close();
    defer if (context.host.pmu_type != null) pmu.close();

    if (context.session.debug) |debug| return branch_debug(machine, context, debug);

    if (context.session.fork_point) |*point| {
        const switched = try branch_switch(machine, context, point);
        if (switched != .paused) return .{ .outcome = machine.outcome(), .stop = switched };
    }

    if (context.session.probe) |probe| return branch_probe(machine, probe);

    const stop = try machine_drive(machine, crash_exit);
    return .{ .outcome = machine.outcome(), .stop = stop };
}

fn branch_streams_fork(hardware: *const Hardware, fork_seed: u64) void {
    const seeds = stream_seeds(fork_seed);

    assert(hardware.events.fork_position == null);
    assert(hardware.jitter.fork_position == null);

    hardware.events.fork(seeds[@backingInt(StreamName.events)]);
    hardware.jitter.fork(seeds[@backingInt(StreamName.jitter)]);
    hardware.schedule.fork(seeds[@backingInt(StreamName.schedule)]);
    hardware.workload.fork(seeds[@backingInt(StreamName.workload)]);

    if (hardware.block) |block| block.stream.fork(seeds[@backingInt(StreamName.block)]);
}

fn branch_switch(machine: *Machine, context: *const Context, point: *const ForkPoint) !Stop {
    assert(machine.pause_exit == null);
    assert(context.hardware.jitter.fork_position == null);

    const stop = try branch_switch_pause(machine, point);
    if (stop != .paused) return stop;

    branch_streams_fork(context.hardware, context.session.fork_seed);

    return .paused;
}

fn branch_switch_check(machine: *const Machine, point: *const ForkPoint) error{ForkDiverged}!void {
    var reached: ForkPoint = undefined;

    assert(point.exits > 0);
    assert(machine.pause_exit == null);

    machine.fork_point(&reached);

    if (std.meta.eql(reached, point.*)) return;

    std.log.warn("fork point exit {d} branches {d} was reached as exit {d} branches {d}", .{
        point.exits,
        point.branches,
        reached.exits,
        reached.branches,
    });

    return error.ForkDiverged;
}

fn branch_switch_pause(machine: *Machine, point: *const ForkPoint) !Stop {
    var stop: Stop = .paused;

    assert(machine.pause_exit == null);
    assert(point.exits > 0);

    if (point.exits > machine.exits) {
        machine.pause_exit = point.exits;
        stop = try machine.run();
        machine.pause_exit = null;
    }

    try branch_switch_check(machine, point);

    return stop;
}

fn branch_wait(pid: linux.pid_t, pipe: linux.fd_t) !Outcome {
    assert(pid > 0);

    var outcome: Outcome = undefined;
    var status: i32 = 0;
    const bytes = std.mem.asBytes(&outcome);
    const received = syscall_retried(linux.read, .{ pipe, bytes.ptr, bytes.len });
    const reaped = syscall_retried(linux.waitpid, .{ pid, &status, 0 });
    const code: u32 = @bitCast(status);
    const reaped_ok = linux.errno(reaped) == .SUCCESS;
    const exited = reaped_ok and linux.W.IFEXITED(code) and linux.W.EXITSTATUS(code) == 0;
    const delivered = received == bytes.len and exited;

    if (!delivered) {
        std.log.err("branch {d} ended with status {x} after {d} bytes", .{ pid, code, received });

        return error.BranchFailed;
    }

    return outcome;
}

fn cmdline_build(
    arena: std.mem.Allocator,
    configured: []const u8,
    disk: bool,
    cpus: u8,
    eventually_ns: u64,
) ![]const u8 {
    const block = if (disk) " " ++ machine_module.cmdline_block else "";
    const smp = cpus > 1;

    const required = if (smp)
        machine_module.cmdline_required_smp
    else
        machine_module.cmdline_required;

    var phase_buffer: [cmdline_phase_max]u8 = undefined;

    const phase = if (eventually_ns > 0)
        try std.mem.print(&phase_buffer, " dst.eventually_ns={d}", .{eventually_ns})
    else
        "";

    assert(cpus > 0);

    return std.mem.concat(arena, u8, &.{ configured, " ", required, block, phase });
}

fn config_check(path: []const u8, config: *const Config) !void {
    assert(path.len > 0);

    if (config.memory_mib < memory_mib_min) return config_memory_reject(path, config);
    if (config.memory_mib > memory_mib_max) return config_memory_reject(path, config);
    if (config.kernel.len == 0) return config_reject(path, "kernel path is empty", .{});
    if (config.seeds == 0) return config_reject(path, "seeds 0 outside 1..{d}", .{seeds_max});

    if (config.seeds > seeds_max) {
        return config_reject(path, "seeds {d} outside 1..{d}", .{ config.seeds, seeds_max });
    }

    if (config.disk_output.len > 0) {
        if (config.disk.len == 0) return config_reject(path, "disk_output needs a disk", .{});
    }

    if (config.runner) {
        if (config.crash_exit != null) {
            const reason = "the runner crashes by crash_window_ns, not crash_exit";
            return config_reject(path, reason, .{});
        }
    }

    try config_check_branches(path, config);
    try config_check_cpus(path, config);
    try config_check_faults(path, config);
    try config_check_runner(path, config);
}

fn config_check_branches(path: []const u8, config: *const Config) !void {
    const command = config.debug_command;
    const replaying = config.reproducer.len > 0;

    assert(path.len > 0);

    if (config.debug_exit != null) {
        if (!replaying) return config_reject(path, "debug_exit needs a reproducer", .{});
        if (command.len == 0) return config_reject(path, "debug_exit needs a debug_command", .{});
    }

    if (command.len > 0) {
        if (config.debug_exit == null) {
            return config_reject(path, "debug_command needs debug_exit", .{});
        }
    }

    if (command.len >= serial_module.receive_ring_size) {
        return config_reject(path, "debug_command is {d} bytes, above {d}", .{
            command.len,
            serial_module.receive_ring_size - 1,
        });
    }

    if (config.debug_ns == 0) return config_reject(path, "debug_ns must be positive", .{});

    if (config.likelihood_points > 0) {
        if (!replaying) return config_reject(path, "likelihood_points needs a reproducer", .{});
    }

    if (config.likelihood_points > probe_max) {
        return config_reject(path, "likelihood_points {d} above {d}", .{
            config.likelihood_points,
            probe_max,
        });
    }

    if (config.likelihood_runs == 0) {
        return config_reject(path, "likelihood_runs 0 outside 1..{d}", .{likelihood_runs_max});
    }

    if (config.likelihood_runs > likelihood_runs_max) {
        return config_reject(path, "likelihood_runs {d} outside 1..{d}", .{
            config.likelihood_runs,
            likelihood_runs_max,
        });
    }
}

fn config_check_cpus(path: []const u8, config: *const Config) !void {
    const cpus_max = machine_module.cpus_max;

    assert(path.len > 0);

    if (config.cpus == 0) return config_reject(path, "cpus 0 outside 1..{d}", .{cpus_max});

    if (config.cpus > cpus_max) {
        return config_reject(path, "cpus {d} outside 1..{d}", .{ config.cpus, cpus_max });
    }

    if (config.cpus > 1) {
        if (!config.preemption) {
            const reason = "cpus {d} needs preemption, because the guest calibrates its local " ++
                "apic timer by spinning until a timer tick advances jiffies";

            return config_reject(path, reason, .{config.cpus});
        }
    }

    if (config.cores_max > pmu_module.cpus_max) {
        return config_reject(path, "cores_max {d} above {d}", .{
            config.cores_max,
            pmu_module.cpus_max,
        });
    }

    if (config.snapshot_holders_max > snapshot_holders_limit) {
        return config_reject(path, "snapshot_holders_max {d} above {d}", .{
            config.snapshot_holders_max,
            snapshot_holders_limit,
        });
    }
}

fn config_check_faults(path: []const u8, config: *const Config) !void {
    assert(path.len > 0);

    if (config.fault_window_ns == 0) {
        return config_reject(path, "fault_window_ns must be positive", .{});
    }

    const plan = config.fault_plan orelse return;

    if (config.faults) {
        const reason = "faults draws a swarm plan per seed and excludes fault_plan";
        return config_reject(path, reason, .{});
    }

    if (!plan.valid()) {
        return config_reject(path, "fault_plan asks for faults the guest cannot carry out", .{});
    }
}

fn config_check_runner(path: []const u8, config: *const Config) !void {
    assert(path.len > 0);

    const exploring = config.explore_runs > 0;
    const replaying = config.reproducer.len > 0;
    const shrinking = config.shrink_output.len > 0;
    const needs_runner = replaying or shrinking or exploring;

    if (needs_runner) {
        if (!config.runner) {
            const reason = "reproducer, shrink_output, and explore_runs need the runner";
            return config_reject(path, reason, .{});
        }
    }

    if (exploring) {
        if (replaying) return config_explore_reject(path);
        if (config.explore_runs < config.seeds) return config_explore_reject(path);
    }

    if (config.explore_output.len > 0) {
        if (!exploring) return config_reject(path, "explore_output needs explore_runs", .{});
    }

    if (replaying) {
        if (shrinking) {
            const reason = "a reproducer replays one run and cannot shrink it again";
            return config_reject(path, reason, .{});
        }
    }

    if (shrinking) {
        if (config.shrink_runs_max == 0) {
            return config_reject(path, "shrink_output needs shrink_runs_max above 0", .{});
        }
    }
}

fn config_explore_reject(path: []const u8) error{ConfigInvalid} {
    assert(path.len > 0);

    const reason = "explore_runs counts the first seeds and cannot replay a reproducer";
    return config_reject(path, reason, .{});
}

fn config_load(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8) !Config {
    const source = try Io.Dir.cwd().readFileAllocOptions(io, path, arena, .unlimited, .of(u8), 0);

    var diagnostics: std.zon.parse.Diagnostics = undefined;

    const config = std.zon.parse.fromSlice(Config, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| {
        diagnostics.log(path);

        return err;
    };

    try config_check(path, &config);

    return config;
}

fn config_memory_reject(path: []const u8, config: *const Config) error{ConfigInvalid} {
    assert(path.len > 0);

    return config_reject(path, "memory_mib {d} outside {d}..{d}", .{
        config.memory_mib,
        memory_mib_min,
        memory_mib_max,
    });
}

fn config_reject(
    path: []const u8,
    comptime format: []const u8,
    args: anytype,
) error{ConfigInvalid} {
    assert(path.len > 0);
    assert(format.len > 0);

    std.log.err("{s}: " ++ format, .{path} ++ args);

    return error.ConfigInvalid;
}

fn crash_delay_derive(seed: u64, config: *const Config) ?u64 {
    var stream: Stream = .init(stream_seeds(seed)[@backingInt(StreamName.crash)]);
    return crash_delay_draw(&stream, config);
}

fn crash_delay_draw(stream: *Stream, config: *const Config) ?u64 {
    if (config.crash_delay_ns) |delay| return delay;
    if (config.crash_window_ns == 0) return null;

    const position = stream.position;
    const skipped = stream.boolean();
    const delay = stream.at_most(config.crash_window_ns);

    assert(stream.position - position == 2);
    assert(delay <= config.crash_window_ns);

    if (config.eventually_ns > 0) {
        if (skipped) return null;
    }

    return delay;
}

fn cycle_first(context: *const Context, branches: []Branch) !Cycle {
    const session = context.session;
    var booted: Booted = undefined;

    assert(branches.len == session.branch_exits.len);

    try booted.init(context, boot_at(0, 0));
    defer booted.deinit(context);

    machine_branch(&booted.machine, context, session.branch_exits, branches) catch |err| {
        try booted.report(context, err);

        return err;
    };

    const stop = machine_drive(&booted.machine, session.crash_exit) catch |err| {
        try booted.report(context, err);

        return err;
    };

    return .{ .outcome = booted.machine.outcome(), .stop = stop };
}

fn cycle_run(context: *const Context, boot_next: Boot) !Cycle {
    var booted: Booted = undefined;

    assert(boot_next.index > 0);
    assert(boot_next.index < cycles_max);

    try booted.init(context, boot_next);
    defer booted.deinit(context);

    const stop = machine_drive(&booted.machine, null) catch |err| {
        try booted.report(context, err);

        return err;
    };

    return .{ .outcome = booted.machine.outcome(), .stop = stop };
}

fn cycles_continue(context: *const Context, first: Cycle) !Outcome {
    const hardware = context.hardware;
    var clock_ns: u64 = 0;
    var cycle = first;
    var cycles: u32 = 1;

    while (cycles < cycles_max) : (cycles += 1) {
        if (cycle.stop != .crash) break;

        clock_ns += cycle.outcome.time_ns + reboot_gap_ns;

        if (hardware.block) |block| block.power_loss();

        hardware.serial.power_cycle();
        hardware.serial_debug.power_cycle();
        try kvm.guest_memory_clear(hardware.memory);

        cycle = try cycle_run(context, boot_at(cycles, clock_ns));
    }

    if (cycle.stop != .shutdown) return error.CyclesExhausted;

    var outcome = cycle.outcome;
    outcome.cycle_first_exits = first.outcome.exits;
    outcome.cycles = cycles;

    assert(outcome.cycles <= cycles_max);
    assert(outcome.cycle_first_exits == first.outcome.exits);

    return outcome;
}

fn cycles_run(context: *const Context, branches: []Branch) !Outcome {
    assert(branches.len == context.session.branch_exits.len);

    const first = try cycle_first(context, branches);
    return cycles_continue(context, first);
}

fn disk_invalid(path: []const u8, length: u64) error{DiskImageInvalid} {
    assert(path.len > 0);

    std.log.err("{s}: disk image length {d} is not whole sectors", .{ path, length });

    return error.DiskImageInvalid;
}

fn disk_map(io: Io, path: []const u8) ![]align(kvm.page_size) u8 {
    assert(path.len > 0);

    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const length = try file.length(io);
    if (length == 0) return disk_invalid(path, length);
    if (length % virtio_block.sector_size != 0) return disk_invalid(path, length);

    const mapped = std.mem.alignForward(usize, @intCast(length), kvm.page_size);
    return try kvm.file_map_private(file.handle, mapped);
}

fn disk_save(path: []const u8, image: []const u8) !void {
    assert(path.len > 0);
    assert(image.len % virtio_block.sector_size == 0);

    try file_save(path, image);
}

fn exception_entry_find(kernel: []const u8) !u64 {
    assert(kernel.len > 0);

    const address = boot.symbol_find(kernel, step.exception_entry_symbol) catch |err| switch (err) {
        error.SymbolMissing => {
            std.log.err("kernel has no {s} symbol, which preemption steps through", .{
                step.exception_entry_symbol,
            });

            return error.KernelSymbolMissing;
        },
        else => |failure| return failure,
    };

    assert(address != 0);

    return address;
}

fn explore_full(explore: *Explore) void {
    assert(!explore.corpus_full);
    assert(explore.corpus_count < explore.corpus.len);

    explore.corpus_full = true;

    std.log.warn("explore: the choice pool filled at {d} corpus entries, so the corpus " ++
        "stops growing", .{explore.corpus_count});
}

fn explore_guide(
    explore: *Explore,
    attempt: *const Attempt,
    points: []ForkPoint,
    points_count: *u32,
) bool {
    var raised = false;

    assert(attempt.guidance_count <= coverage_module.guidance_max);
    assert(points_count.* <= points.len);

    if (!explore.guidance) return false;

    for (attempt.guidance[0..attempt.guidance_count]) |*maximum| {
        if (!explore_guide_raise(explore, maximum)) continue;

        raised = true;

        const point = maximum.point orelse continue;

        if (points_count.* == points.len) continue;

        points[points_count.*] = point;
        points_count.* += 1;
    }

    return raised;
}

fn explore_guide_raise(explore: *Explore, maximum: *const coverage_module.Maximum) bool {
    assert(explore.best_count <= explore.best.len);

    for (explore.best[0..explore.best_count]) |*best| {
        if (best.crc != maximum.crc) continue;
        if (maximum.value <= best.value) return false;

        best.* = maximum.*;

        return true;
    }

    if (explore.best_count == explore.best.len) return false;

    explore.best[explore.best_count] = maximum.*;
    explore.best_count += 1;

    return true;
}

fn explore_history(explore: *Explore) void {
    const bits = coverage_module.count(explore.global);

    assert(explore.runs <= explore.runs_max);

    if (explore.history_count == explore.history.len) return;

    explore.history[explore.history_count] = bits;
    explore.history_count += 1;

    std.log.info("explore: {d} runs, coverage {d} bits, corpus {d} entries", .{
        explore.runs,
        bits,
        explore.corpus_count,
    });
}

fn explore_integrate(explore: *Explore, plan: *const ExploreJob, attempt: *const Attempt) !void {
    const count = attempt.coverage_fresh_count;
    const fresh = attempt.coverage_fresh[0..count];
    const points = attempt.coverage_fresh_points[0..count];
    var added_points: [explore_points_max]ForkPoint = undefined;
    const merged = coverage_module.merge(explore.global, fresh, points, &added_points);
    var points_count = merged.points_count;
    const raised = explore_guide(explore, attempt, &added_points, &points_count);

    assert(explore.runs < explore.runs_max);
    assert(explore.corpus_count <= explore.corpus.len);

    explore.runs += 1;

    if (plan.entry != null) {
        const diverged = if (attempt.failure) |failure| failure == error.ForkDiverged else false;

        explore.forks += 1;
        explore.forks_diverged += @intFromBool(diverged);
        explore.forks_past_ready += @intFromBool(plan.fork_point.exits > explore.ready.exits);
    }

    const kept = (merged.added > 0 or raised) and explore.corpus_count < explore.corpus.len;

    if (kept) try explore_keep(explore, plan, attempt, added_points[0..points_count]);

    if (explore.found != null) return;
    if (attempt.failure != null) return;
    if (attempt.passed()) return;

    const found_pool = explore.found_pool.allocator();

    explore.found = .{ .attempt = attempt.*, .choices = .{}, .run = explore.runs };

    try explore_record(found_pool, plan, attempt, &explore.found.?.choices);
}

fn explore_job(plan: *const ExploreJob, slot: usize) Job {
    assert(slot < explore_parallel_max);

    const entry = plan.entry orelse return .{
        .index = 0,
        .margin = pmu_module.skid_margin,
        .result = @intCast(slot),
        .seed = plan.seed,
    };

    assert(entry.choices.seed == plan.seed);

    return .{
        .choices = &entry.choices,
        .fork_point = plan.fork_point,
        .fork_seed = plan.fork_seed,
        .index = 0,
        .margin = pmu_module.skid_margin,
        .result = @intCast(slot),
    };
}

fn explore_keep(
    explore: *Explore,
    plan: *const ExploreJob,
    attempt: *const Attempt,
    fork_points: []const ForkPoint,
) !void {
    assert(explore.corpus_count < explore.corpus.len);
    assert(fork_points.len <= coverage_module.fresh_max);

    if (explore.corpus_full) return;

    const entry = &explore.corpus[explore.corpus_count];

    explore_record(explore.pool, plan, attempt, &entry.choices) catch |err| switch (err) {
        error.OutOfMemory => return explore_full(explore),
        else => |other| return other,
    };

    entry.fork_points = explore.pool.dupe(ForkPoint, fork_points) catch {
        return explore_full(explore);
    };

    entry.picks = 0;
    explore.corpus_count += 1;
}

fn explore_pick(explore: *Explore) ExploreJob {
    assert(explore.corpus_count <= explore.corpus.len);

    if (explore.uniform) return explore_seed_next(explore);
    if (explore.corpus_count == 0) return explore_seed_next(explore);

    const random = explore.prng.random();
    const favored = random.uintLessThan(u8, explore_newest_odds) != 0;
    const count = explore.corpus_count;
    const spent = explore.corpus[count - 1].picks >= explore_newest_picks_max;
    const newest = favored and !spent;
    const index = if (newest) count - 1 else random.uintLessThan(u32, count);
    const entry = &explore.corpus[index];
    const points = entry.fork_points;
    const pick = if (points.len == 0) null else random.uintLessThan(usize, points.len);

    assert(index < explore.corpus_count);

    entry.picks += 1;

    return .{
        .entry = entry,
        .fork_point = if (pick) |point| points[point] else explore.ready,
        .fork_seed = random.int(u64),
        .seed = entry.choices.seed,
    };
}

fn explore_record(
    arena: std.mem.Allocator,
    plan: *const ExploreJob,
    attempt: *const Attempt,
    choices: *Choices,
) !void {
    var capacities: [choices_module.stream_count]u32 = undefined;

    for (attempt.consumed, &capacities) |consumed, *capacity| {
        if (consumed > choices_module.words_max) return error.ChoicesTooLong;

        capacity.* = @intCast(consumed);
    }

    try choices.init_capacity(arena, &capacities);

    const entry = plan.entry orelse {
        choices.record(&stream_seeds(plan.seed), &capacities);
        choices.guest_seed = plan.seed;
        choices.seed = plan.seed;

        return;
    };

    const fork_seeds = stream_seeds(plan.fork_seed);

    for (std.enums.values(StreamName)) |name| {
        const index = @backingInt(name);
        const fork_position = attempt.fork_positions[index] orelse capacities[index];

        choices.splice(name, entry.choices.slice(name), fork_position, fork_seeds[index]);
    }

    choices.guest_seed = entry.choices.guest_seed;
    choices.seed = entry.choices.seed;
}

fn explore_seed_next(explore: *Explore) ExploreJob {
    const seed = explore.seed_next;

    assert(explore.corpus_count <= explore.corpus.len);

    explore.seed_next +%= 1;

    assert(explore.seed_next != seed);

    return .{ .seed = seed };
}

fn faults_derive(seed: u64, config: *const Config) Faults {
    var stream: Stream = .init(stream_seeds(seed)[@backingInt(StreamName.plan)]);
    return faults_draw(&stream, config);
}

fn faults_draw(stream: *Stream, config: *const Config) Faults {
    assert(config.fault_window_ns > 0);
    assert(config.fault_plan == null or !config.faults);

    if (config.fault_plan) |plan| return plan;
    if (!config.faults) return .{};

    var faults: Faults = .swarm(stream, config.fault_window_ns, config.fault_families);

    faults.roster = config.fault_roster;

    return faults;
}

fn file_save(path: []const u8, bytes: []const u8) !void {
    assert(path.len > 0);

    var path_buffer: [path_max + 1]u8 = undefined;

    if (path.len > path_max) return error.PathTooLong;

    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;

    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const opened = linux.open(path_buffer[0..path.len :0], flags, 0o644);

    if (linux.errno(opened) != .SUCCESS) {
        std.log.err("{s}: cannot create the file: {t}", .{ path, linux.errno(opened) });

        return error.FileSaveFailed;
    }

    const file: linux.fd_t = @intCast(opened);
    defer _ = linux.close(file);

    var written: usize = 0;

    for (0..bytes.len) |_| {
        if (written == bytes.len) return;

        const length = @min(bytes.len - written, file_write_chunk);
        const rc = syscall_retried(linux.write, .{ file, bytes.ptr + written, length });
        if (linux.errno(rc) != .SUCCESS) return error.FileSaveFailed;
        if (rc == 0) return error.FileSaveFailed;

        written += rc;
    }

    assert(written == bytes.len);
}

fn guest_boot(context: *const Context, guest: *const Guest, cycle: u32) !void {
    const session = context.session;

    assert(cycle < cycles_max);
    assert(session.kernel.len > 0);
    assert(guest.count == session.cpus);

    const image: boot.Image = .{
        .cmdline = if (cycle == 0) session.cmdline else session.cmdline_reboot,
        .cpus = session.cpus,
        .initrd = session.initrd,
        .kernel = session.kernel,
        .rng_seed = rng_seed_derive(session.seed +% cycle),
    };

    const entry = try boot.load(context.hardware.memory, &image);

    try boot.vcpu_setup(guest.vcpus[0], entry);
}

fn guest_create(host: *const Host, memory: []align(kvm.page_size) u8, cpus: u8) !Guest {
    assert(cpus > 0);
    assert(cpus <= machine_module.cpus_max);

    var guest: Guest = .{ .vm = try host.handle.vm_create() };
    errdefer guest.close();

    try guest.vm.memory_region_set(0, 0, memory);
    try guest.vm.identity_map_addr_set(identity_map_addr);
    try guest.vm.tss_addr_set(tss_addr);

    for (0..cpus) |index| {
        guest.vcpus[index] = try guest.vm.vcpu_create(@intCast(index));
        guest.count += 1;

        try guest_vcpu_setup(host, guest.vcpus[index], @intCast(index), cpus);
    }

    return guest;
}

fn guest_vcpu_setup(host: *const Host, vcpu: kvm.Vcpu, index: u8, cpus: u8) !void {
    var leaves = host.cpuid.*;

    assert(index < cpus);

    cpuid.processor_set(&leaves, index, cpus);

    try vcpu.cpuid_set(&leaves);
    try vcpu.guest_debug_set(false, &kvm.breakpoints_none);

    if (try vcpu.msrs_set(&msrs_initial) != msrs_initial.len) return error.MsrRefused;
    if (cpus == 1) return;

    const bootstrap: u64 = if (index == 0) apic_base_bootstrap else 0;
    const base: u64 = lapic_module.base | apic_base_enable | bootstrap;
    const entry = [1]kvm.MsrEntry{.{ .index = msr_apic_base, .reserved = 0, .data = base }};
    if (try vcpu.msrs_set(&entry) != entry.len) return error.MsrRefused;
}

fn holder_continue(
    machine: *Machine,
    context: *const Context,
    spawn: *const HolderSpawn,
    states: *const snapshot.VcpuStates,
    request: *const HolderRequest,
) noreturn {
    const slot = &spawn.fan.slots[request.slot];

    _ = linux.close(spawn.ends.request);
    _ = linux.close(spawn.ends.response);

    slot.attempt = .{};

    holder_continue_attempt(machine, context, spawn, states, request, &slot.attempt) catch |err| {
        slot.attempt.failure = err;
    };

    linux.exit_group(0);
}

fn holder_continue_attempt(
    machine: *Machine,
    context: *const Context,
    spawn: *const HolderSpawn,
    states: *const snapshot.VcpuStates,
    request: *const HolderRequest,
    attempt: *Attempt,
) !void {
    var session = context.session.*;
    var job = spawn.job.*;

    assert(request.margin >= pmu_module.skid_margin);
    assert(machine.pause_exit == null);

    try pmu_module.cores_pin(&.{@intCast(request.core)});

    session.fork_point = null;
    session.fork_seed = request.fork_seed;
    session.step_margin = request.margin;
    job.fork_seed = request.fork_seed;
    job.margin = request.margin;
    machine.step_margin = request.margin;

    branch_streams_fork(context.hardware, request.fork_seed);

    const child: Context = .{
        .hardware = context.hardware,
        .host = context.host,
        .session = &session,
    };

    defer runner_child_transcript(&session, job, spawn.fan.transcript.buffered());

    attempt.outcome = branch_continue(&child, machine, states) catch |err| switch (err) {
        error.SerialOutputFailed => return error.TranscriptFull,
        else => |other| return other,
    };

    try runner_child_judge(spawn.fan, &job, &session, spawn.streams, attempt);
}

fn holder_ends_close(ends: HolderEnds) void {
    assert(ends.request >= 0);
    assert(ends.response >= 0);

    _ = linux.close(ends.request);
    _ = linux.close(ends.response);
}

fn holder_fork(
    machine: *Machine,
    context: *const Context,
    spawn: *const HolderSpawn,
    states: *const snapshot.VcpuStates,
    request: *const HolderRequest,
) HolderReply {
    const slot = &spawn.fan.slots[request.slot];
    var status: i32 = 0;

    assert(request.slot < spawn.fan.slots.len);
    assert(machine.pause_exit == null);

    slot.pid.store(0, .release);

    const intermediate = linux.fork();
    if (linux.errno(intermediate) != .SUCCESS) return .{ .failure = 1 };

    if (intermediate == 0) {
        const continuation = linux.fork();

        if (linux.errno(continuation) != .SUCCESS) linux.exit_group(1);
        if (continuation == 0) holder_continue(machine, context, spawn, states, request);

        slot.pid.store(@intCast(continuation), .release);
        linux.exit_group(0);
    }

    const pid_intermediate: linux.pid_t = @intCast(intermediate);
    const reaped = syscall_retried(linux.waitpid, .{ pid_intermediate, &status, 0 });
    const code: u32 = @bitCast(status);
    const exited = linux.errno(reaped) == .SUCCESS and linux.W.IFEXITED(code);
    const pid = slot.pid.load(.acquire);

    if (!exited) return .{ .failure = 1 };
    if (linux.W.EXITSTATUS(code) != 0) return .{ .failure = 1 };
    if (pid == 0) return .{ .failure = 1 };
    return .{ .pid = pid };
}

fn holder_key(choices: *const Choices, point: *const ForkPoint, plan_index: ?u32) u64 {
    var hasher: std.hash.Wyhash = .init(0);

    assert(point.exits > 0);
    assert(choices.total() <= choices_module.words_max * choices_module.stream_count);

    for (choices.words) |words| {
        const address: usize = @intFromPtr(words.ptr);

        hasher.update(std.mem.asBytes(&address));
    }

    hasher.update(std.mem.asBytes(&choices.counts));
    hasher.update(std.mem.asBytes(&choices.guest_seed));
    hasher.update(std.mem.asBytes(&choices.seed));
    hasher.update(std.mem.asBytes(point));

    if (plan_index) |index| hasher.update(std.mem.asBytes(&index));

    return hasher.final();
}

fn holder_private_dirty_kib(pid: linux.pid_t) ?u64 {
    var path_buffer: [smaps_path_max]u8 = undefined;
    var text_buffer: [smaps_size_max]u8 = undefined;

    assert(pid > 0);

    const path = std.mem.print(&path_buffer, "/proc/{d}/smaps_rollup\x00", .{pid}) catch {
        return null;
    };

    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const opened = linux.open(path[0 .. path.len - 1 :0], flags, 0);
    if (linux.errno(opened) != .SUCCESS) return null;

    const file: linux.fd_t = @intCast(opened);
    defer _ = linux.close(file);

    const length = syscall_retried(linux.read, .{ file, &text_buffer, text_buffer.len });
    if (linux.errno(length) != .SUCCESS) return null;

    const text = text_buffer[0..length];
    const start = std.mem.find(u8, text, smaps_private_dirty) orelse return null;
    const rest = std.mem.trimStart(u8, text[start + smaps_private_dirty.len ..], " ");
    const end = std.mem.findNone(u8, rest, "0123456789") orelse rest.len;

    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

fn holder_ready(holder: *Holder) HolderState {
    var polls = [1]linux.pollfd{.{ .fd = holder.response, .events = linux.POLL.IN, .revents = 0 }};
    var reply: HolderReply = .{};
    const bytes = std.mem.asBytes(&reply);

    assert(holder.response >= 0);

    if (holder.ready) return .ready;

    const polled = linux.poll(&polls, polls.len, 0);
    if (linux.errno(polled) != .SUCCESS) return .starting;
    if (polled == 0) return .starting;

    const received = syscall_retried(linux.read, .{ holder.response, bytes.ptr, bytes.len });
    if (received != bytes.len) return .dead;
    if (reply.failure != 0) return .dead;

    holder.pid = reply.pid;
    holder.ready = true;

    assert(holder.pid > 0);

    return .ready;
}

fn holder_request(
    holders: *Holders,
    holder: *Holder,
    request: *const HolderRequest,
) error{ HolderFailed, HolderRefused }!linux.pid_t {
    var reply: HolderReply = .{};
    const sent = std.mem.asBytes(request);
    const bytes = std.mem.asBytes(&reply);

    assert(holder.ready);
    assert(holder.pid > 0);

    const written = syscall_retried(linux.write, .{ holder.request, sent.ptr, sent.len });
    if (written != sent.len) return error.HolderRefused;

    const received = syscall_retried(linux.read, .{ holder.response, bytes.ptr, bytes.len });

    if (received != bytes.len) {
        std.log.err("holder {d} ended while it served a request", .{holder.pid});

        return error.HolderFailed;
    }

    if (reply.failure != 0) return error.HolderRefused;

    holders.stats.served += 1;
    holders.tick += 1;
    holder.used = holders.tick;

    assert(reply.pid > 0);

    return reply.pid;
}

fn holder_serve(
    machine: *Machine,
    context: *const Context,
    spawn: *const HolderSpawn,
    states: *const snapshot.VcpuStates,
    guest: *const Guest,
    pmu: ?*Pmu,
) noreturn {
    const ready: HolderReply = .{ .pid = linux.getpid() };

    guest.close();

    if (pmu) |counter| counter.close();
    if (!holder_write(spawn.ends.response, &ready)) linux.exit_group(1);

    for (0..holder_requests_max) |_| {
        var request: HolderRequest = undefined;
        const bytes = std.mem.asBytes(&request);
        const received = syscall_retried(linux.read, .{ spawn.ends.request, bytes.ptr, bytes.len });

        if (received != bytes.len) linux.exit_group(0);

        const reply = holder_fork(machine, context, spawn, states, &request);

        if (!holder_write(spawn.ends.response, &reply)) linux.exit_group(0);
    }

    linux.exit_group(0);
}

fn holder_spawn(
    machine: *Machine,
    context: *const Context,
    spawn: *const HolderSpawn,
    guest: *const Guest,
    pmu: ?*Pmu,
) void {
    var states: snapshot.VcpuStates = .{};

    assert(machine.pause_exit == null);
    assert(spawn.ends.request >= 0);
    defer holder_ends_close(spawn.ends);

    states.capture_all(guest.view(), context.host.msr_list) catch |err| {
        std.log.warn("a holder could not capture the processors: {t}", .{err});

        return;
    };

    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return;

    if (rc == 0) holder_serve(machine, context, spawn, &states, guest, pmu);
}

fn holder_write(fd: linux.fd_t, reply: *const HolderReply) bool {
    const bytes = std.mem.asBytes(reply);

    assert(fd >= 0);

    const written = syscall_retried(linux.write, .{ fd, bytes.ptr, bytes.len });
    return written == bytes.len;
}

fn holders_close(holders: *const Holders) void {
    assert(holders.entries.len <= snapshot_holders_limit);

    for (holders.entries) |entry| {
        const holder = entry orelse continue;

        _ = linux.close(holder.request);
        _ = linux.close(holder.response);
    }
}

fn holders_drop(holders: *Holders, index: usize) void {
    const holder = holders.entries[index].?;

    assert(index < holders.entries.len);

    _ = linux.close(holder.request);
    _ = linux.close(holder.response);
    holders.entries[index] = null;
}

fn holders_end(holders: *Holders) void {
    var reaped: u64 = 0;

    for (holders.entries, 0..) |entry, index| {
        const holder = entry orelse continue;

        if (holder.ready) holders_report(&holder);

        holders_drop(holders, index);
    }

    if (holders.stats.spawned > 0) {
        std.log.info("snapshot holders: {d} spawned, {d} continuations served", .{
            holders.stats.spawned,
            holders.stats.served,
        });
    }

    for (0..2 * @as(u64, holders.stats.spawned) + 2) |_| {
        var status: i32 = 0;
        const rc = syscall_retried(linux.waitpid, .{ -1, &status, 0 });
        if (linux.errno(rc) != .SUCCESS) break;

        reaped += 1;
    }

    assert(reaped <= 2 * @as(u64, holders.stats.spawned) + 2);
}

fn holders_find(holders: *const Holders, key: u64) ?usize {
    for (holders.entries, 0..) |entry, index| {
        const holder = entry orelse continue;
        if (holder.key == key) return index;
    }

    return null;
}

fn holders_open(holders: *Holders, key: u64) ?HolderEnds {
    const index = holders_slot(holders) orelse return null;
    var request: [2]linux.fd_t = undefined;
    var response: [2]linux.fd_t = undefined;

    assert(holders.entries[index] == null);

    if (linux.errno(linux.pipe2(&request, .{ .CLOEXEC = true })) != .SUCCESS) return null;

    if (linux.errno(linux.pipe2(&response, .{ .CLOEXEC = true })) != .SUCCESS) {
        _ = linux.close(request[0]);
        _ = linux.close(request[1]);

        return null;
    }

    holders.tick += 1;
    holders.stats.spawned += 1;

    holders.entries[index] = .{
        .key = key,
        .request = request[1],
        .response = response[0],
        .used = holders.tick,
    };

    return .{ .request = request[0], .response = response[1] };
}

fn holders_reaped(holders: *Holders, pid: linux.pid_t) void {
    assert(pid > 0);

    for (holders.entries, 0..) |entry, index| {
        const holder = entry orelse continue;
        if (holder.pid == pid) return holders_drop(holders, index);
    }
}

fn holders_report(holder: *const Holder) void {
    assert(holder.ready);
    assert(holder.pid > 0);

    const kib = holder_private_dirty_kib(holder.pid) orelse return;

    std.log.info("holder {d} held {d} KiB of private dirty memory", .{ holder.pid, kib });
}

fn holders_slot(holders: *Holders) ?usize {
    var oldest: ?usize = null;

    for (holders.entries, 0..) |entry, index| {
        const holder = entry orelse return index;
        if (!holder.ready) continue;

        if (oldest) |chosen| {
            if (holders.entries[chosen].?.used <= holder.used) continue;
        }

        oldest = index;
    }

    const evicted = oldest orelse return null;

    holders_drop(holders, evicted);

    return evicted;
}

fn host_probe(
    io: Io,
    arena: std.mem.Allocator,
    handle: kvm.Kvm,
    session: *const Session,
) !Host {
    const supported = try arena.create(kvm.Cpuid2);
    const leaves = try arena.create(kvm.Cpuid2);
    const msr_list = try arena.create(kvm.MsrList);

    var missing: cpuid.Missing = .{};

    try handle.cpuid_supported(supported);
    try handle.msr_index_list(msr_list);

    cpuid.model(supported, leaves, &missing) catch |err| {
        std.log.err("host CPU lacks the DST model: leaf {x} {s} bits {x}", .{
            missing.function,
            missing.register,
            missing.bits,
        });

        return err;
    };

    const vm = try handle.vm_create();
    defer vm.close();

    const vcpu = try vm.vcpu_create(0);
    defer vcpu.close();

    try vcpu.cpuid_set(leaves);
    try snapshot.msrs_probe(vcpu, msr_list);

    return .{
        .cpuid = leaves,
        .exception_entry = if (session.preemption) try exception_entry_find(session.kernel) else 0,
        .handle = handle,
        .msr_list = msr_list,
        .pmu_type = if (session.preemption) try pmu_module.type_find(io, arena) else null,
    };
}

fn initrd_read(io: Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) return "";
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
}

fn input_start(serial: *Serial) !linux.fd_t {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(rc) != .SUCCESS) return error.EventfdFailed;

    const signal: linux.fd_t = @intCast(rc);
    const input = try std.Thread.spawn(.{}, stdin_read, .{ serial, signal });

    input.detach();

    return signal;
}

fn interactive_run(io: Io, arena: std.mem.Allocator, plan: *const Plan) !void {
    var stdout_buffer: [1]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var session: Session = undefined;

    session_plan(&session, plan, plan.config.seed, &stdout_writer.interface, true);

    const saved = raw_mode_enter();
    defer if (saved) |termios| raw_mode_restore(&termios);

    const faulted = plan.config.faults or plan.config.fault_plan != null;

    if (faulted) {
        var buffer: [describe_max]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);

        try session.faults.describe(&writer);
        std.log.info("faults: {s}", .{writer.buffered()});
    }

    const outcome = try session_run(io, arena, &session, &.{});

    std.log.info("memory {x} disk {x} serial {x} after {d} cycles, {d} exits, {d} branches", .{
        outcome.memory_hash,
        outcome.disk_hash,
        outcome.serial_hash,
        outcome.cycles,
        outcome.exits,
        outcome.branches,
    });
}

fn likelihood_count(likelihood: *Likelihood) void {
    const points = likelihood.exits.len;

    assert(points > 0);
    assert(likelihood.results.len % points == 0);

    @memset(likelihood.failures, 0);
    @memset(likelihood.varied, false);

    for (likelihood.results, 0..) |*result, index| {
        const point = index % points;
        const first = &likelihood.results[point];

        if (attempt_signature(result) == likelihood.signature) likelihood.failures[point] += 1;
        if (!result.same(first)) likelihood.varied[point] = true;
    }
}

fn likelihood_exits(exits: []u64, ready: u64, last: u64) void {
    const count = exits.len;
    const span = last - 1 - ready;
    var previous = ready;

    assert(count > 0);
    assert(count <= probe_max);
    assert(span >= count);

    for (exits, 1..) |*exit, index| {
        const shift: u6 = @intCast(count - index);

        exit.* = @max(previous + 1, ready + (span >> shift));
        previous = exit.*;
    }

    assert(exits[0] > ready);
    assert(exits[count - 1] == last - 1);
}

fn likelihood_jobs(likelihood: *Likelihood, choices: *const Choices) void {
    const points = likelihood.exits.len;
    const probe = &likelihood.probe.probe;
    var prng: std.Random.DefaultPrng = .init(choices.seed ^ likelihood_seed_salt);

    assert(probe.count == points);
    assert(likelihood.jobs.len % points == 0);

    for (likelihood.jobs, 0..) |*job, index| {
        job.* = .{
            .choices = choices,
            .fork_point = probe.points[index % points],
            .fork_seed = prng.random().int(u64),
            .index = 0,
            .margin = pmu_module.skid_margin,
            .result = @intCast(index),
            .role = .likelihood,
        };
    }
}

fn machine_branch(
    machine: *Machine,
    context: *const Context,
    branch_exits: []const u64,
    branches: []Branch,
) !void {
    assert(branch_exits.len == branches.len);
    assert(machine.pause_exit == null);

    for (branch_exits, branches) |exit, *branch| {
        assert(exit >= machine.exits);

        machine.pause_exit = exit;

        if (try machine.run() != .paused) return error.BranchAfterStop;

        branch.* = try branch_fork(machine, context);
    }
}

fn machine_drive(machine: *Machine, crash_exit: ?u64) !Stop {
    assert(machine.pause_exit == null);
    if (crash_exit) |exit| assert(exit >= machine.exits);

    machine.pause_exit = crash_exit;

    return switch (try machine.run()) {
        .paused => .crash,
        .crash, .shutdown => |stop| stop,
    };
}

fn machine_init(
    machine: *Machine,
    context: *const Context,
    guest: *const Guest,
    pmu: *Pmu,
    boot_next: Boot,
) void {
    const hardware = context.hardware;
    const session = context.session;

    assert(boot_next.index < cycles_max);
    assert(session.step_margin >= pmu_module.skid_margin);

    machine.* = .{
        .block = hardware.block,
        .branch_ps = session.faults.branch_ps,
        .coverage = hardware.coverage,
        .crash_delay_ns = if (boot_next.index == 0) session.crash_delay_ns else null,
        .cycle = boot_next.index,
        .events = hardware.events,
        .guidance = hardware.guidance,
        .input_signal = hardware.input_signal,
        .jitter = hardware.jitter,
        .jitter_ns_max = session.jitter_ns_max,
        .memory = hardware.memory,
        .pmu = if (context.host.pmu_type != null) pmu else null,
        .rtc = .init(boot_next.clock_seconds),
        .schedule = hardware.schedule,
        .seed = session.guest_seed,
        .serial = hardware.serial,
        .serial_debug = hardware.serial_debug,
        .step_margin = session.step_margin,
        .stop = context.session.stop,
        .time_limit_ns = session.time_limit_ns,
        .timeline = hardware.timeline,
        .watchdog = hardware.watchdog,
        .watchdog_ns = session.watchdog_ns,
        .workload = hardware.workload,
    };

    machine.cpus_attach(guest.view(), context.host.exception_entry);
}

fn outcome_same(first: *const Outcome, other: *const Outcome) bool {
    if (first.branches != other.branches) return false;
    if (!std.mem.eql(u64, &first.cpu_branches, &other.cpu_branches)) return false;
    if (!std.mem.eql(u64, &first.cpu_exits, &other.cpu_exits)) return false;
    if (first.cycle_first_exits != other.cycle_first_exits) return false;
    if (first.cycles != other.cycles) return false;
    if (first.disk_errors != other.disk_errors) return false;
    if (first.disk_hash != other.disk_hash) return false;
    if (first.exits != other.exits) return false;
    if (first.memory_hash != other.memory_hash) return false;
    if (first.serial_hash != other.serial_hash) return false;
    return first.time_ns == other.time_ns;
}

fn preflight_reject(component: []const u8, err: anyerror) error{HostUnsupported} {
    assert(component.len > 0);

    std.log.info("preflight: unsupported {s}={t}", .{ component, err });

    return error.HostUnsupported;
}

fn preflight_run(io: Io, arena: std.mem.Allocator, plan: *const Plan) !void {
    const config = plan.config;
    const supported = try arena.create(kvm.Cpuid2);
    const leaves = try arena.create(kvm.Cpuid2);
    const uts = std.posix.uname();
    const release = std.mem.sliceTo(&uts.release, 0);
    var cores: pmu_module.Cores = .{};
    var missing: cpuid.Missing = .{};
    var pmu_type: ?u32 = null;

    assert(plan.kernel.len > 0);

    pmu_module.cores_find(io, arena, &cores) catch |err| return preflight_reject("cores", err);
    pmu_module.cores_pin(cores.slice()) catch |err| return preflight_reject("cores", err);

    const handle = kvm.Kvm.open() catch |err| return preflight_reject("kvm", err);
    defer handle.close();

    handle.cpuid_supported(supported) catch |err| return preflight_reject("kvm", err);

    cpuid.model(supported, leaves, &missing) catch |err| {
        std.log.err("host CPU lacks the DST model: leaf {x} {s} bits {x}", .{
            missing.function,
            missing.register,
            missing.bits,
        });

        return preflight_reject("cpu", err);
    };

    if (config.preemption) {
        pmu_type = pmu_module.type_find(io, arena) catch |err| return preflight_reject("pmu", err);
        _ = exception_entry_find(plan.kernel) catch |err| return preflight_reject("kernel", err);
    }

    assert(cores.count > 0);

    std.log.info("preflight: supported cores={d} release={s} pmu={?d} preemption={}", .{
        cores.count,
        release,
        pmu_type,
        config.preemption,
    });
}

fn raw_mode_enter() ?linux.termios {
    var saved: linux.termios = undefined;
    if (linux.errno(linux.tcgetattr(0, &saved)) != .SUCCESS) return null;

    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;

    raw.cc[@backingInt(linux.V.MIN)] = 1;
    raw.cc[@backingInt(linux.V.TIME)] = 0;
    _ = linux.tcsetattr(0, .NOW, &raw);

    return saved;
}

fn raw_mode_restore(termios: *const linux.termios) void {
    _ = linux.tcsetattr(0, .NOW, termios);
}

fn replay_summary(first: *const Attempt, replay: *const Attempt) []const u8 {
    assert(first.outcome.cycles <= cycles_max);
    assert(replay.outcome.cycles <= cycles_max);

    if (replay.failure) |failure| {
        if (failure == error.Interrupted) return "interrupted before it finished";
    }

    if (replay.outcome.cycles == 0) {
        if (replay.failure == null) return "skipped by replay_max";
    }

    if (first.same(replay)) return "reproduced the same run";
    return "DIVERGED";
}

fn reproducer_load(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    path: []const u8,
    choices: *Choices,
) !void {
    assert(path.len > 0);

    const source = try Io.Dir.cwd().readFileAllocOptions(io, path, arena, .unlimited, .of(u8), 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;

    const reproducer = std.zon.parse.fromSlice(choices_module.Reproducer, .{
        .arena = arena,
        .diagnostics = &diagnostics,
        .gpa = gpa,
        .source = source,
    }) catch |err| {
        diagnostics.log(path);

        return err;
    };

    try choices.init_reproducer(arena, &reproducer);

    assert(choices.seed == reproducer.seed);
}

fn reproducer_save(io: Io, path: []const u8, choices: *const Choices) !void {
    assert(path.len > 0);
    assert(choices.total() <= choices_module.words_max * choices_module.stream_count);

    var buffer: [reproducer_buffer_size]u8 = undefined;

    const file = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.log.err("{s}: cannot create the reproducer: {t}", .{ path, err });

        return err;
    };

    defer file.close(io);

    var writer: Io.File.Writer = .init(file, io, &buffer);

    try std.zon.stringify.serialize(choices.reproducer(), .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn rng_seed_derive(seed: u64) [boot.rng_seed_size]u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    var bytes: [boot.rng_seed_size]u8 = undefined;

    prng.fill(&bytes);

    return bytes;
}

fn runner_batch(io: Io, gpa: std.mem.Allocator, plan: *const Plan, batch: *const Batch) !void {
    assert(batch.seeds.len == batch.results.len);
    assert(batch.seeds.len == batch.replays.len);
    assert(batch.plans.len == 0 or batch.plans.len == batch.seeds.len);
    assert(batch.concurrency > 0);
    assert(batch.concurrency <= batch.cores.len);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const transcript_buffer = try kvm.guest_memory_alloc(transcript_size_max);
    defer kvm.guest_memory_free(transcript_buffer);

    var transcript: Io.Writer = .fixed(transcript_buffer);
    var session: Session = undefined;

    session_plan(&session, plan, runner_boot_seed, &transcript, false);
    session.crash_delay_ns = null;
    session.faults = .{};

    wake_handler_install();
    try runner_processes_adopt();

    var rig: Rig = .{};

    try rig.init(io, arena, &session);
    defer rig.deinit();

    const slots_size = batch.concurrency * @sizeOf(Slot);
    const slots_mapped = std.mem.alignForward(usize, slots_size, kvm.page_size);
    const slots_memory = try kvm.shared_memory_alloc(slots_mapped);
    defer kvm.guest_memory_free(slots_memory);

    const holders = try arena.create(Holders);

    holders.* = .{ .entries = try arena.alloc(?Holder, batch.holders_max) };

    @memset(holders.entries, null);
    defer runner_holders_end(holders, batch.holder_stats);

    const hardware = rig.hardware();
    const context: Context = .{ .hardware = &hardware, .host = &rig.host, .session = &session };

    const runner: Runner = .{
        .holders = holders,
        .jobs = try arena.alloc(Job, batch.seeds.len),
        .scratch = try arena.create(verdict_module.Scratch),
        .slots = std.mem.bytesAsSlice(Slot, slots_memory[0..slots_size]),
        .transcript = &transcript,
    };

    assert(runner.slots.len == batch.concurrency);

    try runner_boot(&context, &runner, plan, batch);
}

fn runner_boot(
    context: *const Context,
    runner: *const Runner,
    plan: *const Plan,
    batch: *const Batch,
) !void {
    assert(runner.jobs.len == batch.seeds.len);
    assert(runner.slots.len == batch.concurrency);
    assert(context.session.crash_delay_ns == null);
    assert(context.session.faults.idle());

    const guest = try guest_create(context.host, context.hardware.memory, context.session.cpus);
    defer guest.close();

    try guest_boot(context, &guest, 0);

    var pmu: Pmu = undefined;

    if (context.host.pmu_type) |pmu_type| pmu = try Pmu.open(pmu_type, linux.gettid(), 0);
    defer if (context.host.pmu_type != null) pmu.close();

    var machine: Machine = undefined;

    machine_init(&machine, context, &guest, &pmu, boot_at(0, 0));
    machine.ready_pause = true;

    const stop = machine.run() catch |err| switch (err) {
        error.SerialOutputFailed => return error.TranscriptFull,
        else => |other| return other,
    };

    const ready = stop == .paused and !machine.ready_pause;

    if (!ready) {
        std.log.err("the guest stopped with {t} before it reported ready", .{stop});

        return error.ReadyMissing;
    }

    var states: snapshot.VcpuStates = .{};
    var catalog: Catalog = .{};

    try states.capture_all(guest.view(), context.host.msr_list);
    try catalog.parse(runner.transcript.buffered());

    if (batch.explore) |explore| {
        explore.global.* = context.hardware.coverage.bits;

        machine.fork_point(&explore.ready);
    }

    if (batch.catalog) |out| out.* = catalog;

    const fan: Fan = .{
        .batch = batch,
        .catalog = &catalog,
        .context = context,
        .holders = runner.holders,
        .machine = &machine,
        .plan = plan,
        .scratch = runner.scratch,
        .slots = runner.slots,
        .states = &states,
        .transcript = runner.transcript,
    };

    try runner_seeds(&fan, runner.jobs);
}

fn runner_child(fan: *const Fan, job: Job, core: u16, slot: *Slot, ends: ?HolderEnds) noreturn {
    slot.attempt = .{};

    runner_child_attempt(fan, job, core, &slot.attempt, ends) catch |err| {
        slot.attempt.failure = err;
    };

    linux.exit_group(0);
}

fn runner_child_attempt(
    fan: *const Fan,
    job: Job,
    core: u16,
    attempt: *Attempt,
    ends: ?HolderEnds,
) !void {
    assert(job.index < fan.batch.seeds.len);
    assert(job.margin >= pmu_module.skid_margin);

    const seed_default = job.seed orelse fan.batch.seeds[job.index];
    const seed = if (job.choices) |recorded| recorded.seed else seed_default;
    var session: Session = undefined;
    var streams: [choices_module.stream_count]Stream = undefined;

    try pmu_module.cores_pin(&.{core});

    session_plan(&session, fan.plan, seed, fan.transcript, false);
    session_draw(&session, fan.plan.config, &streams, job.choices);
    session.fork_point = job.fork_point;
    session.fork_seed = job.fork_seed;
    session.step_margin = job.margin;

    if (fan.batch.plans.len > 0) session.faults = fan.batch.plans[job.index];

    const debug: Debug = .{
        .command = fan.plan.config.debug_command,
        .exit = fan.plan.config.debug_exit orelse 0,
        .ns = fan.plan.config.debug_ns,
        .output = &attempt.debug,
    };

    if (job.role == .debug) session.debug = &debug;
    if (job.role == .probe) session.probe = runner_child_probe(fan.batch, &attempt.probe);

    runner_child_prepare(fan, &session, &streams);
    defer runner_child_transcript(&session, job, fan.transcript.buffered());

    const context: Context = .{
        .hardware = fan.context.hardware,
        .host = fan.context.host,
        .session = &session,
    };

    const held = if (ends) |holder| HolderSpawn{
        .ends = holder,
        .fan = fan,
        .job = &job,
        .streams = &streams,
    } else null;

    const run = if (held) |*spawn|
        runner_child_hold(&context, fan.machine, fan.states, spawn)
    else
        branch_continue(&context, fan.machine, fan.states);

    attempt.outcome = run catch |err| switch (err) {
        error.SerialOutputFailed => return error.TranscriptFull,
        else => |other| return other,
    };

    switch (job.role) {
        .debug, .probe => return,
        .likelihood, .run, .shrink => {},
    }

    try runner_child_judge(fan, &job, &session, &streams, attempt);
}

fn runner_child_hold(
    context: *const Context,
    machine: *Machine,
    states: *const snapshot.VcpuStates,
    spawn: *const HolderSpawn,
) !Outcome {
    const watched = context.session.watchdog_ns > 0;
    var hardware = context.hardware.*;

    assert(context.session.fork_point != null);
    assert(machine.pause_exit == null);

    hardware.watchdog = if (watched) try machine_module.watchdog_start() else null;
    defer if (hardware.watchdog) |timer| timer.stop();

    const child: Context = .{
        .hardware = &hardware,
        .host = context.host,
        .session = context.session,
    };

    machine.watchdog = hardware.watchdog;

    const first = try branch_hold(&child, machine, states, spawn);
    return cycles_continue(&child, first);
}

fn runner_child_judge(
    fan: *const Fan,
    job: *const Job,
    session: *const Session,
    streams: *const [choices_module.stream_count]Stream,
    attempt: *Attempt,
) !void {
    assert(job.margin == session.step_margin);
    assert(attempt.events_count == 0);

    runner_child_record(fan.context.hardware, streams, attempt);

    try attempt_judge(fan.scratch, fan.transcript.buffered(), fan.catalog, attempt);

    if (attempt.passed()) return;
    if (session.disk_output.len == 0) return;
    if (job.margin != pmu_module.skid_margin) return;
    if (job.role != .run) return;

    var path_buffer: [path_max]u8 = undefined;

    const path = try std.fmt.bufPrint(&path_buffer, "{s}.{d}", .{
        session.disk_output,
        session.seed,
    });

    try disk_save(path, fan.context.hardware.block.?.image);
}

fn runner_child_prepare(
    fan: *const Fan,
    session: *const Session,
    streams: *const [choices_module.stream_count]Stream,
) void {
    const hardware = fan.context.hardware;
    const machine = fan.machine;

    assert(session.faults.valid());
    assert(machine.pause_exit == null);
    assert(machine.jitter == hardware.jitter);

    machine.crash_delay_ns = session.crash_delay_ns;
    machine.crash_time_ns = if (session.crash_delay_ns) |delay| machine.time_ns + delay else null;
    machine.jitter_ns_max = session.jitter_ns_max;
    machine.seed = session.guest_seed;
    machine.step_margin = session.step_margin;

    machine.rate_set(session.faults.branch_ps);
    hardware.coverage.reset_fresh(if (fan.batch.explore) |explore| explore.global else null);
    hardware.events.* = streams[@backingInt(StreamName.events)];

    hardware.guidance.reset();
    hardware.jitter.* = streams[@backingInt(StreamName.jitter)];
    hardware.schedule.* = streams[@backingInt(StreamName.schedule)];

    hardware.timeline.arm(&session.faults, session.fault_window_ns);
    hardware.workload.* = streams[@backingInt(StreamName.workload)];

    assert(hardware.timeline.ready_ns == machine.time_ns);

    if (hardware.block) |block| {
        block.faults = session.faults.disk;
        block.stream = streams[@backingInt(StreamName.block)];

        block.errors_arm(machine.time_ns);
    }
}

fn runner_child_probe(batch: *const Batch, probe: *Probe) *Probe {
    const likelihood = batch.likelihood.?;
    const count = likelihood.exits.len;

    assert(count > 0);
    assert(count <= probe_max);

    probe.count = @intCast(count);

    @memcpy(probe.exits[0..count], likelihood.exits);

    return probe;
}

fn runner_child_record(
    hardware: *const Hardware,
    streams: *const [choices_module.stream_count]Stream,
    attempt: *Attempt,
) void {
    const coverage = hardware.coverage;
    const fresh = coverage.fresh[0..coverage.fresh_count];

    assert(coverage.fresh_count <= coverage.fresh.len);
    assert(attempt.coverage_fresh_count == 0);

    attempt.consumed = streams_consumed(streams, hardware);
    attempt.coverage_fresh_count = coverage.fresh_count;

    @memcpy(attempt.coverage_fresh[0..fresh.len], fresh);
    @memcpy(attempt.coverage_fresh_points[0..fresh.len], coverage.fresh_points[0..fresh.len]);
    attempt.fork_positions[@backingInt(StreamName.events)] = hardware.events.fork_position;
    attempt.fork_positions[@backingInt(StreamName.jitter)] = hardware.jitter.fork_position;
    attempt.fork_positions[@backingInt(StreamName.schedule)] = hardware.schedule.fork_position;
    attempt.fork_positions[@backingInt(StreamName.workload)] = hardware.workload.fork_position;
    attempt.guidance_count = hardware.guidance.count;

    @memcpy(attempt.guidance[0..hardware.guidance.count], hardware.guidance.slice());
    runner_child_record_events(hardware.timeline, attempt);

    if (hardware.block) |block| {
        attempt.fork_positions[@backingInt(StreamName.block)] = block.stream.fork_position;
    }
}

fn runner_child_record_events(timeline: *const Timeline, attempt: *Attempt) void {
    const count = timeline.count;

    assert(count <= faults_module.events_max);
    assert(attempt.events_count == 0);

    @memcpy(attempt.events[0..count], timeline.events[0..count]);
    @memcpy(attempt.event_points[0..count], timeline.points[0..count]);
    attempt.events_count = count;
    attempt.events_dropped = timeline.dropped;
}

fn runner_child_transcript(session: *const Session, job: Job, transcript: []const u8) void {
    if (session.transcript_output.len == 0) return;

    const replay = job.margin != pmu_module.skid_margin;

    const suffix = switch (job.role) {
        .debug => ".debug",
        .likelihood, .probe => return,
        .run => if (replay) ".replay" else "",
        .shrink => if (replay) ".shrunk" else return,
    };

    const output = session.transcript_output;
    const seed = session.seed;
    var path_buffer: [path_max]u8 = undefined;

    const path = std.fmt.bufPrint(&path_buffer, "{s}.{d}{s}", .{ output, seed, suffix }) catch {
        std.log.err("{s}: the transcript path is longer than {d} bytes", .{ output, path_max });

        return;
    };

    file_save(path, transcript) catch |err| {
        std.log.err("{s}: cannot save the transcript: {t}", .{ path, err });
    };
}

fn runner_conclude(io: Io, plan: *const Plan, batch: *const Batch) !void {
    assert(batch.catalog != null);
    assert(batch.shrunk.len == 0 or batch.shrunk.len == batch.seeds.len);

    var violations = runner_verdicts(plan, batch);

    if (batch.explore) |explore| {
        violations += try runner_explore_report(io, plan, batch.catalog.?, explore);
    }

    for (batch.shrunk, 0..) |*entry, index| {
        if (entry.shrunk) try runner_shrunk_report(io, plan, batch.seeds[index], entry);
    }

    if (batch.debug) |attempt| runner_debug_report(plan.config, attempt);
    if (batch.likelihood) |likelihood| runner_likelihood_report(likelihood);

    runner_coverage(batch.catalog.?, batch.results);

    std.log.info("{d} of {d} seeds violated a property", .{ violations, batch.seeds.len });

    if (violations > 0) return error.ViolationsFound;
}

fn runner_coverage(catalog: *const Catalog, results: []const Attempt) void {
    assert(catalog.count <= catalog.kinds.len);

    var hits: verdict_module.Hits = @splat(0);
    var reached: u32 = 0;
    var undeclared: u64 = 0;

    for (results) |*result| {
        for (&hits, result.verdict.hits) |*word, hit| word.* |= hit;

        undeclared += result.verdict.undeclared;
    }

    for (0..catalog.count) |index| {
        const property: u32 = @intCast(index);
        const kind = catalog.kinds[property];

        if (!catalog.unreached(&hits, property)) {
            reached += 1;

            continue;
        }

        const verb = if (kind == .always) "evaluated" else "reached";
        const message = catalog.message_at(property);

        std.log.info("property never {s}: {t} '{s}'", .{ verb, kind, message });
    }

    std.log.info("{d} of {d} declared properties reached, {d} reports named none of them", .{
        reached,
        catalog.count,
        undeclared,
    });
}

fn runner_debug(fan: *const Fan, attempt: *Attempt) !void {
    assert(fan.batch.choices.len == 1);
    assert(fan.plan.config.debug_exit != null);

    const jobs = [_]Job{.{
        .choices = &fan.batch.choices[0],
        .index = 0,
        .margin = pmu_module.skid_margin,
        .result = 0,
        .role = .debug,
    }};

    attempt.* = .{};

    try runner_fan(fan, &jobs, @as(*[1]Attempt, attempt));
}

fn runner_debug_report(config: *const Config, attempt: *const Attempt) void {
    const output = &attempt.debug;
    const length = @min(output.length, output.bytes.len);

    assert(config.debug_exit != null);
    assert(output.length >= length);

    if (attempt.failure) |failure| {
        std.log.err("debug: the branch failed with {t}", .{failure});

        return;
    }

    std.log.info("debug: '{s}' at exit {d}, {d} ns, ran {d} ns and printed {d} bytes", .{
        config.debug_command,
        output.exit,
        output.time_ns,
        config.debug_ns,
        output.length,
    });

    std.log.info("debug: output\n{s}", .{output.bytes[0..length]});

    if (output.length > length) {
        std.log.warn("debug: the output is cut to its first {d} bytes", .{length});
    }
}

fn runner_explore(fan: *const Fan, explore: *Explore) !void {
    const batch = fan.batch;
    const parallel = @min(batch.concurrency, explore_parallel_max);
    var plans: [explore_parallel_max]ExploreJob = undefined;
    var jobs: [explore_parallel_max]Job = undefined;
    var attempts: [explore_parallel_max]Attempt = undefined;

    assert(parallel > 0);
    assert(explore.runs == 0);

    for (batch.seeds, batch.results) |seed, *result| {
        try explore_integrate(explore, &.{ .seed = seed }, result);
    }

    explore_history(explore);

    for (0..explore.runs_max) |_| {
        if (explore.runs >= explore.runs_max) break;

        const count = @min(parallel, explore.runs_max - explore.runs);

        for (plans[0..count], jobs[0..count], 0..) |*plan, *job, slot| {
            plan.* = explore_pick(explore);
            job.* = explore_job(plan, slot);
        }

        @memset(attempts[0..count], .{});
        try runner_fan(fan, jobs[0..count], attempts[0..count]);

        for (plans[0..count], attempts[0..count]) |*plan, *attempt| {
            try explore_integrate(explore, plan, attempt);
        }

        explore_history(explore);
    }
}

fn runner_explore_init(
    arena: std.mem.Allocator,
    pool: std.mem.Allocator,
    config: *const Config,
    seeds_count: usize,
) !*Explore {
    assert(config.explore_runs > 0);
    assert(config.explore_runs >= seeds_count);

    const explore = try arena.create(Explore);
    const found_words = try pool.alloc(u64, @divExact(choices_size_max, @sizeOf(u64)));

    explore.* = .{
        .corpus = try arena.alloc(Entry, explore_corpus_max),
        .found_pool = .init(std.mem.sliceAsBytes(found_words)),
        .global = try arena.create(coverage_module.Bits),
        .guidance = config.explore_guidance,
        .history = try arena.alloc(u64, config.explore_runs + 1),
        .pool = pool,
        .prng = .init(config.seed ^ explore_seed_salt),
        .runs_max = config.explore_runs,
        .seed_next = config.seed +% seeds_count,
        .uniform = config.explore_uniform,
    };

    assert(explore.history.len > explore.runs_max);

    return explore;
}

fn runner_explore_report(
    io: Io,
    plan: *const Plan,
    catalog: *const Catalog,
    explore: *const Explore,
) !u64 {
    const config = plan.config;
    const first = if (explore.history_count > 0) explore.history[0] else 0;
    const last = if (explore.history_count > 0) explore.history[explore.history_count - 1] else 0;
    const mode = if (explore.uniform) "uniform seeds" else "guided search";

    assert(explore.runs <= explore.runs_max);

    std.log.info("explore: {s} grew coverage from {d} to {d} bits over {d} runs", .{
        mode,
        first,
        last,
        explore.runs,
    });

    std.log.info("explore: {d} forks, {d} past ready, {d} diverged from their fork point", .{
        explore.forks,
        explore.forks_past_ready,
        explore.forks_diverged,
    });

    runner_explore_report_best(catalog, explore);

    const found = explore.found orelse return 0;

    std.log.info("explore: run {d} of {d} violated a property", .{ found.run, explore.runs });
    runner_report(plan, found.choices.seed, &found.choices, &found.attempt);

    if (config.explore_output.len > 0) {
        try reproducer_save(io, config.explore_output, &found.choices);
    }

    return 1;
}

fn runner_explore_report_best(catalog: *const Catalog, explore: *const Explore) void {
    assert(explore.best_count <= explore.best.len);
    assert(catalog.count <= catalog.kinds.len);

    for (explore.best[0..explore.best_count]) |*best| {
        const message = verdict_module.maximize_message(catalog, best.crc) orelse "undeclared";

        std.log.info("explore: the best {s} is {d}", .{ message, best.value });
    }
}

fn runner_fan(fan: *const Fan, jobs: []const Job, results: []Attempt) !void {
    const concurrency = fan.batch.concurrency;
    var children: [pmu_module.cpus_max]?Child = @splat(null);
    var next: usize = 0;
    var running: usize = 0;

    assert(concurrency <= children.len);
    assert(concurrency <= fan.slots.len);
    assert(jobs.len <= results.len);

    for (jobs) |job| assert(job.result < results.len);
    errdefer runner_reap_all(fan, children[0..concurrency], results);

    for (0..jobs.len * 2) |_| {
        const spawning = next < jobs.len and running < concurrency;

        if (spawning) {
            const slot = runner_slot_free(children[0..concurrency]).?;

            children[slot] = try runner_spawn(fan, jobs[next], slot);
            next += 1;
            running += 1;

            continue;
        }

        try runner_reap(fan, children[0..concurrency], results);
        running -= 1;
    }

    assert(next == jobs.len);
    assert(running == 0);
}

fn runner_holders_end(holders: *Holders, stats: ?*HolderStats) void {
    assert(holders.stats.served <= holders.tick);

    holders_end(holders);

    if (stats) |out| out.* = holders.stats;
}

fn runner_job(batch: *const Batch, index: usize, margin: u64) Job {
    const forked = batch.fork_points.len > 0;

    assert(index < batch.seeds.len);
    assert(batch.choices.len == 0 or batch.choices.len == batch.seeds.len);
    assert(batch.fork_points.len == batch.fork_seeds.len);
    if (forked) assert(batch.choices.len == batch.fork_points.len);

    return .{
        .choices = if (batch.choices.len > 0) &batch.choices[index] else null,
        .fork_point = if (forked) batch.fork_points[index] else null,
        .fork_seed = if (forked) batch.fork_seeds[index] else 0,
        .index = @intCast(index),
        .margin = margin,
        .result = @intCast(index),
    };
}

fn runner_likelihood(fan: *const Fan, likelihood: *Likelihood) !void {
    const batch = fan.batch;
    const reproduced = &batch.results[0];
    const ready = fan.machine.exits;
    const last = reproduced.outcome.cycle_first_exits;
    const points = likelihood.exits.len;

    assert(batch.choices.len == 1);
    assert(likelihood.results.len == likelihood.jobs.len);

    if (reproduced.passed()) {
        std.log.err("likelihood: the reproducer passed, so no continuation fails its way", .{});

        return error.ReproducerPassed;
    }

    if (last <= ready + points) {
        std.log.err("likelihood: {d} exits after ready leave no room for {d} points", .{
            last -| ready,
            points,
        });

        return error.ReproducerShort;
    }

    likelihood.signature = attempt_signature(reproduced);

    likelihood_exits(likelihood.exits, ready, last);

    try runner_likelihood_probe(fan, likelihood);

    likelihood_jobs(likelihood, &batch.choices[0]);

    try runner_fan(fan, likelihood.jobs, likelihood.results);

    likelihood_count(likelihood);
}

fn runner_likelihood_init(arena: std.mem.Allocator, config: *const Config) !*Likelihood {
    const points = config.likelihood_points;
    const count = points * config.likelihood_runs;

    assert(points > 0);
    assert(points <= probe_max);
    assert(config.likelihood_runs > 0);
    assert(config.likelihood_runs <= likelihood_runs_max);

    const likelihood = try arena.create(Likelihood);

    likelihood.* = .{
        .exits = try arena.alloc(u64, points),
        .failures = try arena.alloc(u32, points),
        .jobs = try arena.alloc(Job, count),
        .probe = try arena.create(Attempt),
        .results = try arena.alloc(Attempt, count),
        .varied = try arena.alloc(bool, points),
    };

    likelihood.probe.* = .{};

    @memset(likelihood.results, .{});

    return likelihood;
}

fn runner_likelihood_probe(fan: *const Fan, likelihood: *Likelihood) !void {
    const probe = likelihood.probe;

    assert(fan.batch.choices.len == 1);
    assert(likelihood.exits.len <= probe_max);

    const jobs = [_]Job{.{
        .choices = &fan.batch.choices[0],
        .index = 0,
        .margin = pmu_module.skid_margin,
        .result = 0,
        .role = .probe,
    }};

    probe.* = .{};

    try runner_fan(fan, &jobs, @as(*[1]Attempt, probe));

    if (probe.failure) |failure| {
        std.log.err("likelihood: the replay that records the fork points failed with {t}", .{
            failure,
        });

        return failure;
    }

    assert(probe.probe.count == likelihood.exits.len);
}

fn runner_likelihood_report(likelihood: *const Likelihood) void {
    const points = likelihood.exits.len;
    const runs = @divExact(likelihood.results.len, points);
    const times = likelihood.probe.probe.times[0..points];
    var likely: ?usize = null;

    assert(likelihood.probe.probe.count == points);

    for (0..points) |index| {
        const failures = likelihood.failures[index];
        const note = if (likelihood.varied[index]) "" else ", and every continuation ran the same";

        std.log.info("likelihood: exit {d} at {d} ns: {d} of {d} failed the same way{s}", .{
            likelihood.exits[index],
            times[index],
            failures,
            runs,
            note,
        });

        if (likely == null) {
            if (failures * 2 > runs) likely = index;
        }
    }

    runner_likelihood_report_errors(likelihood);

    const index = likely orelse {
        std.log.info("likelihood: no point fails more than half of its continuations", .{});

        return;
    };

    std.log.info("likelihood: the failure became likely by exit {d}, at {d} ns", .{
        likelihood.exits[index],
        times[index],
    });
}

fn runner_likelihood_report_errors(likelihood: *const Likelihood) void {
    var errors: u32 = 0;
    var first: ?anyerror = null;

    for (likelihood.results) |*result| {
        const failure = result.failure orelse continue;

        if (attempt_signature(result) == likelihood.signature) continue;

        errors += 1;
        first = first orelse failure;
    }

    assert(errors <= likelihood.results.len);

    const failure = first orelse return;

    std.log.warn("likelihood: {d} continuations stopped with an error, the first {t}", .{
        errors,
        failure,
    });
}

fn runner_processes_adopt() !void {
    const ignore: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };

    const subreaper = @backingInt(linux.PR.SET_CHILD_SUBREAPER);
    if (linux.errno(linux.prctl(subreaper, 1, 0, 0, 0)) != .SUCCESS) return error.SubreaperRefused;
    if (linux.errno(linux.sigaction(.PIPE, &ignore, null)) != .SUCCESS) return error.SignalRefused;
}

fn runner_reap(fan: *const Fan, children: []?Child, results: []Attempt) !void {
    assert(children.len <= fan.slots.len);

    for (0..reap_attempts_max) |_| {
        var status: i32 = 0;
        const reaped = syscall_retried(linux.waitpid, .{ -1, &status, 0 });
        if (linux.errno(reaped) != .SUCCESS) return error.BranchFailed;

        const pid: linux.pid_t = @intCast(reaped);
        if (runner_reap_child(fan, children, results, pid, status)) return;

        holders_reaped(fan.holders, pid);
    }

    std.log.err("reaped {d} processes that no slot owns", .{reap_attempts_max});

    return error.BranchFailed;
}

fn runner_reap_all(fan: *const Fan, children: []?Child, results: []Attempt) void {
    for (0..children.len) |_| {
        if (runner_slot_used(children) == null) return;

        runner_reap(fan, children, results) catch return;
    }
}

fn runner_reap_child(
    fan: *const Fan,
    children: []?Child,
    results: []Attempt,
    pid: linux.pid_t,
    status: i32,
) bool {
    assert(pid > 0);
    assert(children.len <= fan.slots.len);

    for (children, 0..) |*entry, slot| {
        const child = entry.* orelse continue;
        if (child.pid != pid) continue;

        entry.* = null;

        runner_result(child, status, &fan.slots[slot].attempt, &results[child.job]);

        return true;
    }

    return false;
}

fn runner_report(
    plan: *const Plan,
    seed: u64,
    recorded: ?*const Choices,
    attempt: *const Attempt,
) void {
    var session: Session = undefined;
    var discard: Io.Writer.Discarding = .init(&.{});
    var streams: [choices_module.stream_count]Stream = undefined;

    session_plan(&session, plan, seed, &discard.writer, false);
    session_draw(&session, plan.config, &streams, recorded);
    runner_report_plan(&session);
    runner_report_events(seed, attempt);

    if (attempt.failure) |err| {
        std.log.err("seed {d}: session failed: {t} {s}", .{
            seed,
            err,
            attempt.detail[0..attempt.detail_length],
        });

        return;
    }

    const detail = attempt.detail[0..attempt.detail_length];
    const separator = if (detail.len > 0) ", first: " else "";
    const status = if (attempt.passed()) "ok" else "VIOLATION";
    const verdict = attempt.verdict;
    const checked = if (verdict.checked) "checked" else "UNCHECKED";

    const phase = switch (verdict.eventually) {
        .unreached => "",
        .passed => ", eventually passed",
        .failed => ", eventually FAILED",
    };

    std.log.info("seed {d}: {s}, {d} acknowledged, {d} present, {d} lost, {s}, " ++
        "{d} failed assertions{s}{s}{s}, {d} cycles, {d} disk errors, fingerprint {x} {x} {x}", .{
        seed,
        status,
        verdict.acknowledged,
        verdict.present,
        verdict.lost,
        checked,
        verdict.failures,
        separator,
        detail,
        phase,
        attempt.outcome.cycles,
        attempt.outcome.disk_errors,
        attempt.outcome.memory_hash,
        attempt.outcome.disk_hash,
        attempt.outcome.serial_hash,
    });
}

fn runner_report_events(seed: u64, attempt: *const Attempt) void {
    var buffer: [describe_max]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    assert(attempt.events_count <= faults_module.events_max);

    if (attempt.events_count == 0) return;

    for (attempt.events[0..attempt.events_count], 0..) |*event, index| {
        writer.writeAll(if (index == 0) "" else "; ") catch break;
        event.describe(&writer) catch break;
    }

    std.log.info("seed {d} events: {s}, {d} dropped", .{
        seed,
        writer.buffered(),
        attempt.events_dropped,
    });
}

fn runner_report_plan(session: *const Session) void {
    assert(session.faults.valid());

    var buffer: [describe_max]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    session.faults.describe(&writer) catch |err| switch (err) {
        error.WriteFailed => @panic("a fault plan description outgrew describe_max"),
    };

    std.log.info("seed {d} plan: crash after {?d} ns; {s}", .{
        session.seed,
        session.crash_delay_ns,
        writer.buffered(),
    });
}

fn runner_report_replay(seed: u64, first: *const Attempt, replay: *const Attempt) void {
    const failure = if (replay.failure) |err| @errorName(err) else "none";
    const outcomes = [_]*const Outcome{ &first.outcome, &replay.outcome };
    const names = [_][]const u8{ "run", "replay" };

    for (outcomes, names) |o, w| {
        std.log.info("seed {d}: {s} {d} cycles, {d} exits, {d} branches, {d} ns, " ++
            "{d} first-cycle exits, {d} disk errors, fingerprint {x} {x} {x}", .{
            seed,
            w,
            o.cycles,
            o.exits,
            o.branches,
            o.time_ns,
            o.cycle_first_exits,
            o.disk_errors,
            o.memory_hash,
            o.disk_hash,
            o.serial_hash,
        });
    }

    std.log.info("seed {d}: replay failure {s}", .{ seed, failure });
}

fn runner_result(child: Child, status: i32, slot: *const Attempt, result: *Attempt) void {
    const code: u32 = @bitCast(status);
    const exited = linux.W.IFEXITED(code) and linux.W.EXITSTATUS(code) == 0;

    assert(child.pid > 0);
    assert(slot != result);

    if (exited) {
        result.* = slot.*;

        return;
    }

    std.log.err("seed child {d} ended with status {x}", .{ child.pid, code });

    result.* = .{ .failure = error.BranchFailed };
}

fn runner_run(io: Io, gpa: std.mem.Allocator, plan: *const Plan) !void {
    const config = plan.config;
    const replaying = config.reproducer.len > 0;
    const count: usize = if (replaying) 1 else @intCast(config.seeds);
    const shrinking = config.shrink_output.len > 0;
    const explored = config.explore_runs > 0;
    const pooled = shrinking or explored;
    const branched = config.likelihood_points > 0;
    const fanned = pooled or branched;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const pool_memory = if (pooled) try kvm.guest_memory_alloc(choices_pool_size) else null;
    defer if (pool_memory) |memory| kvm.guest_memory_free(memory);

    var pool_state: std.heap.FixedBufferAllocator = .init(pool_memory orelse &.{});
    const arena = arena_state.allocator();
    const pool = pool_state.allocator();
    const reproduced = try arena.alloc(Choices, if (replaying) 1 else 0);
    const seeds = try arena.alloc(u64, count);
    const results = try arena.alloc(Attempt, count);
    const replays = try arena.alloc(Attempt, count);
    const shrunk = try arena.alloc(Shrunk, if (shrinking) count else 0);
    const candidates = try arena.create([shrink_parallel_max]Choices);
    const explore = if (explored) try runner_explore_init(arena, pool, config, count) else null;
    const debug = if (config.debug_exit != null) try arena.create(Attempt) else null;
    const likelihood = if (branched) try runner_likelihood_init(arena, config) else null;
    var catalog: Catalog = .{};
    var cores: pmu_module.Cores = .{};

    if (shrinking) try shrink_candidates_init(pool, candidates);
    if (replaying) try reproducer_load(io, gpa, arena, config.reproducer, &reproduced[0]);

    for (seeds, 0..) |*seed, index| {
        seed.* = if (replaying) reproduced[0].seed else config.seed +% index;
    }

    @memset(results, .{});
    @memset(replays, .{});
    @memset(shrunk, .{});

    try pmu_module.cores_find(io, arena, &cores);

    const width = if (config.cores_max > 0) @min(cores.count, config.cores_max) else cores.count;

    const batch: Batch = .{
        .candidates = if (shrinking) candidates else null,
        .catalog = &catalog,
        .choices = reproduced,
        .concurrency = if (fanned) width else @min(width, seeds.len),
        .cores = cores.slice()[0..width],
        .debug = debug,
        .explore = explore,
        .holders_max = config.snapshot_holders_max,
        .likelihood = likelihood,
        .pool = if (pooled) pool else null,
        .replay_all = replaying,
        .replay_max = config.replay_max,
        .replays = replays,
        .results = results,
        .seeds = seeds,
        .shrink_runs_max = if (shrinking) config.shrink_runs_max else 0,
        .shrunk = shrunk,
    };

    try runner_batch(io, gpa, plan, &batch);
    try runner_conclude(io, plan, &batch);
}

fn runner_seeds(fan: *const Fan, jobs: []Job) !void {
    const batch = fan.batch;
    var failed: usize = 0;

    assert(jobs.len == batch.seeds.len);

    for (jobs, 0..) |*job, index| job.* = runner_job(batch, index, pmu_module.skid_margin);

    try runner_fan(fan, jobs, batch.results);

    for (batch.results, 0..) |*result, index| {
        if (result.passed()) {
            if (!batch.replay_all) continue;
        }

        if (batch.replay_max > 0) {
            if (failed == batch.replay_max) break;
        }

        jobs[failed] = runner_job(batch, index, step_margin_replay);
        failed += 1;
    }

    assert(failed <= jobs.len);

    try runner_fan(fan, jobs[0..failed], batch.replays);
    try runner_shrink_all(fan);

    if (batch.explore) |explore| try runner_explore(fan, explore);
    if (batch.debug) |attempt| try runner_debug(fan, attempt);
    if (batch.likelihood) |likelihood| try runner_likelihood(fan, likelihood);
}

fn runner_shrink(fan: *const Fan, index: u32, shrunk: *Shrunk) !void {
    const batch = fan.batch;
    const result = &batch.results[index];
    const seed = batch.seeds[index];
    const candidates = batch.candidates.?;
    var capacities: [choices_module.stream_count]u32 = undefined;

    assert(!result.passed());
    assert(batch.choices.len == 0);

    for (result.consumed, &capacities) |consumed, *capacity| {
        if (consumed > choices_module.words_max) {
            std.log.err("seed {d}: a stream drew {d} words, more than a reproducer holds", .{
                seed,
                consumed,
            });

            return;
        }

        capacity.* = @intCast(consumed);
    }

    shrunk.* = .{ .attempt = result.*, .shrunk = true };

    try shrunk.choices.init_capacity(batch.pool.?, &capacities);
    shrunk.choices.record(&stream_seeds(seed), &capacities);
    shrunk.choices.guest_seed = seed;
    shrunk.choices.seed = seed;

    var shrinker: choices_module.Shrinker = .{ .current = &shrunk.choices };
    const signature = attempt_signature(result);

    shrinker.units[@backingInt(StreamName.events)] = faults_module.event_words;

    for (0..batch.shrink_runs_max) |_| {
        if (shrunk.runs >= batch.shrink_runs_max) break;

        const ran = try runner_shrink_round(fan, index, signature, &shrinker, candidates, shrunk);
        if (ran == 0) break;
    }

    try runner_shrink_verify(fan, index, signature, shrunk);
}

fn runner_shrink_all(fan: *const Fan) !void {
    const batch = fan.batch;
    if (batch.shrink_runs_max == 0) return;

    assert(batch.candidates != null);
    assert(batch.pool != null);
    assert(batch.shrunk.len == batch.seeds.len);

    var signatures: [shrink_signatures_max]u64 = undefined;
    var signatures_count: usize = 0;

    for (batch.results, batch.replays, 0..) |*result, *replay, index| {
        if (result.passed()) continue;
        if (!result.same(replay)) continue;
        if (signatures_count == signatures.len) break;

        const signature = attempt_signature(result);
        const seen = signatures[0..signatures_count];
        if (std.mem.findScalar(u64, seen, signature) != null) continue;

        signatures[signatures_count] = signature;
        signatures_count += 1;

        try runner_shrink(fan, @intCast(index), &batch.shrunk[index]);
    }
}

fn runner_shrink_round(
    fan: *const Fan,
    index: u32,
    signature: u64,
    shrinker: *choices_module.Shrinker,
    candidates: *[shrink_parallel_max]Choices,
    shrunk: *Shrunk,
) !usize {
    const parallel = @min(fan.batch.concurrency, shrink_parallel_max);
    var cursors: [shrink_parallel_max]choices_module.Cursor = undefined;
    var attempts: [shrink_parallel_max]Attempt = @splat(.{});
    var jobs: [shrink_parallel_max]Job = undefined;
    var count: usize = 0;

    assert(parallel > 0);
    assert(shrunk.shrunk);

    while (count < parallel) : (count += 1) {
        cursors[count] = shrinker.next(&candidates[count]) orelse break;

        jobs[count] = .{
            .choices = &candidates[count],
            .index = index,
            .margin = pmu_module.skid_margin,
            .result = @intCast(count),
            .role = .shrink,
        };
    }

    if (count == 0) return 0;

    try runner_fan(fan, jobs[0..count], attempts[0..count]);
    shrunk.runs += @intCast(count);

    for (attempts[0..count], candidates[0..count], cursors[0..count]) |*attempt, *candidate, at| {
        if (attempt_signature(attempt) != signature) continue;

        shrinker.accept(candidate, at);
        shrunk.attempt = attempt.*;

        break;
    }

    return count;
}

fn runner_shrink_verify(fan: *const Fan, index: u32, signature: u64, shrunk: *Shrunk) !void {
    var attempts: [1]Attempt = @splat(.{});

    const jobs = [_]Job{.{
        .choices = &shrunk.choices,
        .index = index,
        .margin = step_margin_replay,
        .result = 0,
        .role = .shrink,
    }};

    assert(shrunk.shrunk);
    assert(attempt_signature(&shrunk.attempt) == signature);

    try runner_fan(fan, &jobs, &attempts);

    const same = attempts[0].same(&shrunk.attempt);

    shrunk.interrupted = if (attempts[0].failure) |failure| failure == error.Interrupted else false;
    shrunk.replayed = same and attempt_signature(&attempts[0]) == signature;
}

fn runner_shrunk_report(io: Io, plan: *const Plan, seed: u64, shrunk: *const Shrunk) !void {
    const config = plan.config;
    const replay = shrunk_summary(shrunk);
    var path_buffer: [path_max]u8 = undefined;

    assert(shrunk.shrunk);
    assert(config.shrink_output.len > 0);

    const path = try std.fmt.bufPrint(&path_buffer, "{s}.{d}.zon", .{ config.shrink_output, seed });

    try reproducer_save(io, path, &shrunk.choices);

    std.log.info("seed {d}: shrunk in {d} runs to {d} choice words, replay {s}, saved {s}", .{
        seed,
        shrunk.runs,
        shrunk.choices.total(),
        replay,
        path,
    });

    runner_report(plan, seed, &shrunk.choices, &shrunk.attempt);
}

fn runner_slot_free(children: []const ?Child) ?usize {
    assert(children.len > 0);

    for (children, 0..) |child, slot| {
        if (child == null) return slot;
    }

    return null;
}

fn runner_slot_used(children: []const ?Child) ?usize {
    assert(children.len > 0);

    for (children, 0..) |child, slot| {
        if (child != null) return slot;
    }

    return null;
}

fn runner_spawn(fan: *const Fan, job: Job, slot: usize) !Child {
    const holders = fan.holders;
    const point = job.fork_point orelse return runner_spawn_child(fan, job, slot, null);
    const choices = job.choices orelse return runner_spawn_child(fan, job, slot, null);

    assert(slot < fan.slots.len);
    assert(holders.entries.len <= snapshot_holders_limit);

    if (holders.entries.len == 0) return runner_spawn_child(fan, job, slot, null);

    const plan_index: ?u32 = if (fan.batch.plans.len > 0) job.index else null;
    const key = holder_key(choices, &point, plan_index);

    const index = holders_find(holders, key) orelse {
        return runner_spawn_child(fan, job, slot, holders_open(holders, key));
    };

    const holder = &holders.entries[index].?;

    switch (holder_ready(holder)) {
        .ready => {},
        .starting => return runner_spawn_child(fan, job, slot, null),
        .dead => {
            holders_drop(holders, index);

            return runner_spawn_child(fan, job, slot, null);
        },
    }

    const request: HolderRequest = .{
        .core = fan.batch.cores[slot],
        .fork_seed = job.fork_seed,
        .margin = job.margin,
        .slot = @intCast(slot),
    };

    const pid = holder_request(holders, holder, &request) catch |err| switch (err) {
        error.HolderRefused => {
            holders_drop(holders, index);

            return runner_spawn_child(fan, job, slot, null);
        },
        error.HolderFailed => return err,
    };

    return .{ .job = job.result, .pid = pid };
}

fn runner_spawn_child(fan: *const Fan, job: Job, slot: usize, ends: ?HolderEnds) !Child {
    const core = fan.batch.cores[slot];

    assert(job.index < fan.batch.seeds.len);
    assert(slot < fan.slots.len);
    assert(core < pmu_module.cpus_max);

    const rc = linux.fork();

    if (linux.errno(rc) != .SUCCESS) {
        if (ends) |holder| holder_ends_close(holder);

        return error.BranchFailed;
    }

    if (rc == 0) {
        holders_close(fan.holders);
        runner_child(fan, job, core, &fan.slots[slot], ends);
    }

    if (ends) |holder| holder_ends_close(holder);

    return .{ .job = job.result, .pid = @intCast(rc) };
}

fn runner_verdicts(plan: *const Plan, batch: *const Batch) u64 {
    var violations: u64 = 0;

    assert(batch.seeds.len == batch.results.len);
    assert(batch.seeds.len == batch.replays.len);

    for (batch.seeds, batch.results, batch.replays, 0..) |seed, *first, *replay, index| {
        const recorded = if (batch.choices.len > 0) &batch.choices[index] else null;

        runner_report(plan, seed, recorded, first);

        if (first.passed()) {
            if (!batch.replay_all) continue;
        }

        violations += @intFromBool(!first.passed());

        std.log.info("seed {d}: replay {s}", .{ seed, replay_summary(first, replay) });

        if (!first.same(replay)) runner_report_replay(seed, first, replay);
    }

    return violations;
}

fn session_draw(
    session: *Session,
    config: *const Config,
    streams: *[choices_module.stream_count]Stream,
    recorded: ?*const Choices,
) void {
    assert(recorded == null or recorded.?.seed == session.seed);

    streams_init(streams, session.seed, recorded);
    session.crash_delay_ns = crash_delay_draw(&streams[@backingInt(StreamName.crash)], config);
    session.faults = faults_draw(&streams[@backingInt(StreamName.plan)], config);
    session.guest_seed = if (recorded) |choices| choices.guest_seed else session.seed;

    assert(session.faults.valid());
}

fn session_plan(
    session: *Session,
    plan: *const Plan,
    seed: u64,
    output: *Io.Writer,
    stdin_thread: bool,
) void {
    const config = plan.config;

    session.* = .{
        .branch_exits = &.{},
        .cmdline = plan.cmdline,
        .cmdline_reboot = plan.cmdline_reboot,
        .cpus = config.cpus,
        .crash_delay_ns = crash_delay_derive(seed, config),
        .crash_exit = config.crash_exit,
        .debug = null,
        .disk = config.disk,
        .disk_cache_sectors = config.disk_cache_sectors,
        .disk_output = config.disk_output,
        .fault_window_ns = config.fault_window_ns,
        .faults = faults_derive(seed, config),
        .fork_point = null,
        .fork_seed = 0,
        .guest_seed = seed,
        .initrd = plan.initrd,
        .jitter_ns_max = config.jitter_ns_max,
        .kernel = plan.kernel,
        .memory_size = config.memory_mib << 20,
        .preemption = config.preemption,
        .probe = null,
        .seed = seed,
        .serial_output = output,
        .stdin_thread = stdin_thread,
        .step_margin = pmu_module.skid_margin,
        .stop = plan.stop,
        .time_limit_ns = config.time_limit_ns,
        .transcript_output = config.transcript_output,
        .watchdog_ns = if (stdin_thread) 0 else config.watchdog_ns,
    };
}

fn shrink_candidates_init(
    pool: std.mem.Allocator,
    candidates: *[shrink_parallel_max]Choices,
) error{OutOfMemory}!void {
    const capacities: [choices_module.stream_count]u32 = @splat(choices_module.words_max);

    for (candidates) |*candidate| try candidate.init_capacity(pool, &capacities);

    assert(candidates[0].total() == 0);
    assert(candidates[shrink_parallel_max - 1].words[0].len == choices_module.words_max);
}

fn shrunk_summary(shrunk: *const Shrunk) []const u8 {
    assert(shrunk.shrunk);
    assert(shrunk.runs > 0);

    if (shrunk.interrupted) return "interrupted before it finished";
    if (shrunk.replayed) return "reproduced the same run";
    return "DIVERGED";
}

fn stdin_read(serial: *Serial, signal: linux.fd_t) void {
    const one: u64 = 1;
    var byte: u8 = undefined;
    var stop = linux.sigemptyset();

    linux.sigaddset(&stop, .INT);
    linux.sigaddset(&stop, .TERM);
    linux.sigaddset(&stop, pmu_module.overflow_signal);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &stop, null);

    for (0..input_bytes_max) |_| {
        const rc = linux.read(0, @ptrCast(&byte), 1);
        if (rc == 0) return;
        if (linux.errno(rc) != .SUCCESS) return;

        assert(rc == 1);
        serial.receive(byte);

        _ = linux.write(signal, std.mem.asBytes(&one), @sizeOf(u64));
    } else unreachable;
}

fn stop_watch(signals: linux.fd_t, stop: *std.atomic.Value(bool), target: linux.pid_t) void {
    var info: linux.signalfd_siginfo = undefined;
    const bytes = std.mem.asBytes(&info);

    assert(signals >= 0);
    assert(target > 0);

    const rc = syscall_retried(linux.read, .{ signals, bytes.ptr, bytes.len });

    if (rc != bytes.len) {
        std.log.err("the stop signal watch failed: {t}", .{linux.errno(rc)});

        return;
    }

    stop.store(true, .release);
    _ = linux.tgkill(linux.getpid(), target, pmu_module.overflow_signal);
}

fn stop_watch_start(stop: *std.atomic.Value(bool)) !void {
    var mask = linux.sigemptyset();

    wake_handler_install();
    linux.sigaddset(&mask, .INT);
    linux.sigaddset(&mask, .TERM);

    if (linux.errno(linux.sigprocmask(linux.SIG.BLOCK, &mask, null)) != .SUCCESS) {
        return error.StopWatchFailed;
    }

    const rc = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.StopWatchFailed;

    const signals: linux.fd_t = @intCast(rc);
    const watcher = try std.Thread.spawn(.{}, stop_watch, .{ signals, stop, linux.gettid() });

    watcher.detach();
}

fn stream_seeds(seed: u64) [choices_module.stream_count]u64 {
    var seeds: [choices_module.stream_count]u64 = undefined;

    for (std.enums.values(StreamName)) |name| {
        const salt: u64 = switch (name) {
            .plan => faults_seed_salt,
            .crash => crash_seed_salt,
            .block => block_seed_salt,
            .jitter => jitter_seed_salt,
            .schedule => schedule_seed_salt,
            .workload => workload_seed_salt,
            .events => events_seed_salt,
        };

        seeds[@backingInt(name)] = seed ^ salt;
    }

    assert(seeds[@backingInt(StreamName.plan)] != seeds[@backingInt(StreamName.crash)]);
    assert(seeds[@backingInt(StreamName.block)] != seeds[@backingInt(StreamName.jitter)]);

    return seeds;
}

fn streams_consumed(
    streams: *const [choices_module.stream_count]Stream,
    hardware: *const Hardware,
) [choices_module.stream_count]u64 {
    var consumed: [choices_module.stream_count]u64 = undefined;

    for (std.enums.values(StreamName)) |name| {
        consumed[@backingInt(name)] = switch (name) {
            .plan, .crash => streams[@backingInt(name)].position,
            .block => if (hardware.block) |block| block.stream.position else 0,
            .jitter => hardware.jitter.position,
            .schedule => hardware.schedule.position,
            .workload => hardware.workload.position,
            .events => hardware.events.position,
        };
    }

    if (hardware.block == null) assert(consumed[@backingInt(StreamName.block)] == 0);

    return consumed;
}

fn streams_init(
    streams: *[choices_module.stream_count]Stream,
    seed: u64,
    recorded: ?*const Choices,
) void {
    const seeds = stream_seeds(seed);

    assert(recorded == null or recorded.?.seed == seed);

    for (std.enums.values(StreamName)) |name| {
        const index = @backingInt(name);

        streams[index] = if (recorded) |choices| choices.stream(name) else .init(seeds[index]);
    }

    for (streams) |stream| assert(stream.position == 0);
}

fn syscall_retried(comptime function: anytype, args: anytype) usize {
    var rc: usize = 0;

    for (0..interrupted_retries_max) |_| {
        rc = @call(.auto, function, args);

        if (linux.errno(rc) != .INTR) return rc;
    }

    return rc;
}

fn vcpu_dump(vcpu: kvm.Vcpu, memory: []const u8) !void {
    var regs: kvm.Regs = undefined;
    var sregs: kvm.Sregs = undefined;

    try vcpu.regs_get(&regs);
    try vcpu.sregs_get(&sregs);

    std.log.err("stopped at rip={x} rsp={x} rflags={x}", .{ regs.rip, regs.rsp, regs.rflags });
    std.log.err("rax={x} rbx={x} rcx={x} rdx={x}", .{ regs.rax, regs.rbx, regs.rcx, regs.rdx });
    std.log.err("rsi={x} rdi={x} rbp={x}", .{ regs.rsi, regs.rdi, regs.rbp });

    std.log.err("cr0={x} cr2={x} cr3={x} cr4={x} efer={x}", .{
        sregs.cr0,
        sregs.cr2,
        sregs.cr3,
        sregs.cr4,
        sregs.efer,
    });

    if (boot.translate(memory, sregs.cr3, regs.rip)) |paddr| {
        std.log.err("code at rip: {x}", .{memory[paddr..][0..16]});
    }

    for (0..stack_words_dumped) |i| {
        const vaddr = regs.rsp + i * 8;

        const paddr = boot.translate(memory, sregs.cr3, vaddr) orelse {
            std.log.err("  [rsp+{d}] unmapped", .{i * 8});

            continue;
        };

        const word = std.mem.readInt(u64, memory[paddr..][0..8], .little);

        std.log.err("  [rsp+{d}] {x}", .{ i * 8, word });
    }
}

fn wake_handler(_: linux.SIG) callconv(.c) void {}

fn wake_handler_install() void {
    const wake: linux.Sigaction = .{
        .handler = .{ .handler = wake_handler },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };

    _ = linux.sigaction(pmu_module.overflow_signal, &wake, null);
}

pub fn main(init: std.process.Init) !void {
    const stop_page = try kvm.shared_memory_alloc(kvm.page_size);
    const stop_bytes = stop_page[0..@sizeOf(std.atomic.Value(bool))];
    const stop = std.mem.bytesAsValue(std.atomic.Value(bool), stop_bytes);

    stop.* = .init(false);

    try stop_watch_start(stop);

    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const config_path = if (args.len > 1) args[1] else config_path_default;
    const config = try config_load(io, init.gpa, arena, config_path);
    const reboot = if (config.cmdline_reboot.len == 0) config.cmdline else config.cmdline_reboot;

    const plan: Plan = .{
        .cmdline = try cmdline_build(
            arena,
            config.cmdline,
            config.disk.len != 0,
            config.cpus,
            config.eventually_ns,
        ),
        .cmdline_reboot = try cmdline_build(
            arena,
            reboot,
            config.disk.len != 0,
            config.cpus,
            config.eventually_ns,
        ),
        .config = &config,
        .initrd = try initrd_read(io, arena, config.initrd),
        .kernel = try Io.Dir.cwd().readFileAlloc(io, config.kernel, arena, .unlimited),
        .stop = stop,
    };

    try preflight_run(io, arena, &plan);

    if (config.preflight) return;
    if (config.runner) return runner_run(io, init.gpa, &plan);

    try interactive_run(io, arena, &plan);
}

pub fn session_run(
    io: Io,
    arena: std.mem.Allocator,
    session: *const Session,
    branches: []Branch,
) !Outcome {
    assert(session.memory_size % kvm.page_size == 0);
    assert(branches.len == session.branch_exits.len);

    wake_handler_install();

    var rig: Rig = .{};

    try rig.init(io, arena, session);
    defer rig.deinit();

    const hardware = rig.hardware();
    const context: Context = .{ .hardware = &hardware, .host = &rig.host, .session = session };
    const outcome = try cycles_run(&context, branches);

    if (session.disk_output.len > 0) try disk_save(session.disk_output, rig.block.image);

    return outcome;
}

test "two runs and branches forked from the second at seven exits end in one state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    const branch_exits = [_]u64{ 0, 1, 12_690, 12_691, 20_000, 25_000, 30_000 };

    var first = try check_run(gpa, kernel, .{});
    defer first.transcript.deinit();

    var second = try check_run(gpa, kernel, .{ .branch_exits = &branch_exits });
    defer second.transcript.deinit();

    const transcript = first.transcript.written();

    try std.testing.expect(std.mem.find(u8, transcript, "GUEST UP") != null);
    try std.testing.expect(std.mem.find(u8, transcript, "CHECK DONE") != null);
    try std.testing.expectEqual(std.hash.Fnv1a_64.hash(transcript), first.outcome.serial_hash);
    try std.testing.expectEqualStrings(transcript, second.transcript.written());
    try std.testing.expectEqual(first.outcome, second.outcome);

    try std.testing.expect(second.branches[2].interrupt_window);
    try std.testing.expect(second.branches[3].interrupt_injected);

    for (second.branches[0..branch_exits.len]) |branch| {
        try std.testing.expectEqual(first.outcome, branch.outcome);
    }
}

test "a two-processor branch taken at any of eight exits finishes exactly as its parent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    var run = try check_run(gpa, kernel, .{
        .branch_exits = &check_smp_branch_exits,
        .cmdline = check_cmdline ++ " spin",
        .cpus = 2,
        .preemption = true,
    });

    defer run.transcript.deinit();

    try check_cpus_ran(&run.outcome, 2);

    for (run.branches[0..check_smp_branch_exits.len]) |*branch| {
        try std.testing.expectEqual(run.outcome, branch.outcome);
    }
}

test "preemption wakes a sleeper beside a spinner and a wider step margin places the same ticks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    try check_spin(gpa, kernel, 1);
    try check_spin(gpa, kernel, 2);
}

test "power loss keeps each overwritten sector whole and the persist rate picks old or new" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    for ([_]u16{ 0, 500, 1000 }) |persist| {
        var run = try check_run(gpa, kernel, .{
            .cmdline = check_cmdline_crash,
            .cmdline_reboot = check_cmdline_verify,
            .faults = .{ .disk = .{ .persist_permille = persist } },
        });

        defer run.transcript.deinit();

        const sectors = try check_sectors(run.transcript.written());

        try std.testing.expectEqual(@as(u64, 2), run.outcome.cycles);
        try std.testing.expectEqual(@as(u64, check_target_size), sectors.size);
        try std.testing.expectEqual(@as(u64, check_target_sectors), sectors.old + sectors.new);
        try std.testing.expectEqual(@as(u64, 0), sectors.mixed);
        try std.testing.expectEqual(persist == 0, sectors.new == 0);
        try std.testing.expectEqual(persist == 1000, sectors.old == 0);
    }
}

test "a power loss with torn sectors replays to one state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    const options: CheckOptions = .{
        .cmdline = check_cmdline_crash,
        .cmdline_reboot = check_cmdline_verify,
        .faults = .{ .disk = .{ .persist_permille = 500 } },
    };

    var first = try check_run(gpa, kernel, options);
    defer first.transcript.deinit();

    var second = try check_run(gpa, kernel, options);
    defer second.transcript.deinit();

    try std.testing.expectEqualStrings(first.transcript.written(), second.transcript.written());
    try std.testing.expectEqual(first.outcome, second.outcome);
}

test "a crash at any exit leaves a mountable filesystem and the synced data whole" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    try check_sweep(gpa, kernel, 1, check_sweep_first);
    try check_sweep(gpa, kernel, 2, check_sweep_first_smp);
}

test "latency and stall faults move the schedule and two runs still end in one state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    const faults: Faults = .{
        .disk = .{
            .latency_ns_max = 1_000_000,
            .stall_ns = 20_000_000,
            .stall_permille = 50,
        },
    };

    var plain = try check_run(gpa, kernel, .{});
    defer plain.transcript.deinit();

    var first = try check_run(gpa, kernel, .{ .faults = faults });
    defer first.transcript.deinit();

    var second = try check_run(gpa, kernel, .{ .faults = faults });
    defer second.transcript.deinit();

    try std.testing.expect(std.mem.find(u8, first.transcript.written(), "CHECK DONE") != null);
    try std.testing.expect(first.outcome.time_ns != plain.outcome.time_ns);
    try std.testing.expectEqualStrings(first.transcript.written(), second.transcript.written());
    try std.testing.expectEqual(first.outcome, second.outcome);
}

test "the final disk image is written out and hashes like the outcome" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    var path_buffer: [path_max]u8 = undefined;

    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/disk.img", .{
        &directory.sub_path,
    });

    var run = try check_run(gpa, kernel, .{ .disk_output = path });
    defer run.transcript.deinit();

    const saved = try directory.dir.readFileAlloc(io, "disk.img", gpa, .unlimited);
    defer gpa.free(saved);

    try std.testing.expectEqual(run.outcome.disk_hash, std.hash.Wyhash.hash(0, saved));
    try std.testing.expect(std.mem.find(u8, run.transcript.written(), "CHECK DONE") != null);
}

test "a misread event or an agent error fails the attempt and keeps what the guest read" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const scratch = try std.testing.allocator.create(verdict_module.Scratch);
    defer std.testing.allocator.destroy(scratch);

    const arena = arena_state.allocator();
    const event: Event = .{ .delay_ns = 40, .kind = .kill, .target = .redis_server };
    var buffer: [verdict_module.event_text_max]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    try event.render(&writer);

    const echoed = try std.mem.concat(arena, u8, &.{ "DST EVENT ", writer.buffered(), " END\n" });
    const done = "DST CHECK DONE\n";
    const misread = "DST EVENT kind=kill target=postmaster END\n" ++ done;
    const agent = "DST AGENT ERROR KeyError: target\n" ++ done;
    var matched: Attempt = .{};
    var misreading: Attempt = .{};
    var failing: Attempt = .{};
    var silent: Attempt = .{};

    for ([_]*Attempt{ &matched, &misreading, &failing, &silent }) |attempt| {
        attempt.events[0..2].* = .{ event, event };
        attempt.events_count = 1;
    }

    silent.events_count = 2;

    const whole = try std.mem.concat(arena, u8, &.{ echoed, done });
    const catalog: Catalog = .{};
    const mismatch = attempt_judge(scratch, misread, &catalog, &misreading);
    const failure = attempt_judge(scratch, agent, &catalog, &failing);
    const missing = attempt_judge(scratch, done, &catalog, &silent);
    const kept = misreading.detail[0..misreading.detail_length];
    const unechoed = silent.detail[0..silent.detail_length];

    try attempt_judge(scratch, whole, &catalog, &matched);

    try std.testing.expectError(error.EventMismatch, mismatch);
    try std.testing.expectError(error.AgentFailed, failure);
    try std.testing.expectError(error.EventMismatch, missing);
    try std.testing.expect(matched.passed());
    try std.testing.expectEqualStrings("kind=kill target=postmaster", kept);
    try std.testing.expectEqualStrings(event_missing, unechoed);
}

test "the zig sdk decodes the event block byte for byte as the hypervisor renders it" {
    const event: Event = .{
        .kind = .network,
        .delay_ns = 123_456,
        .duration_ns = 7_000_000,
        .target = .redis_server,
        .choice = 3,
        .clock_jump_ns = -9,
        .clock_slew_ppm = -11,
        .network_direction = .replies,
        .network_link = .redis,
        .network_loss_permille = 1000,
        .network_peers = 5,
    };

    var bytes: [@sizeOf(dst.Event)]u8 = undefined;
    var expected_buffer: [verdict_module.event_text_max]u8 = undefined;
    var decoded_buffer: [verdict_module.event_text_max]u8 = undefined;
    var expected: Io.Writer = .fixed(&expected_buffer);
    var decoded_writer: Io.Writer = .fixed(&decoded_buffer);

    for (&bytes, 0..) |*byte, offset| byte.* = faults_module.event_byte(&event, @intCast(offset));

    const decoded = std.mem.bytesToValue(dst.Event, &bytes);

    try event.render(&expected);
    try decoded.render(&decoded_writer);

    try std.testing.expectEqual(@sizeOf(Event), @sizeOf(dst.Event));
    try std.testing.expectEqual(faults_module.event_magic, dst.event_magic);
    try std.testing.expectEqualStrings(expected.buffered(), decoded_writer.buffered());
}

test "the zig sdk conformance guest draws, acknowledges, echoes, covers, and guides" {
    try check_conformance("zig");
}

test "the rust sdk conformance guest draws, acknowledges, echoes, covers, and guides" {
    try check_conformance("rust");
}

test "the go sdk conformance guest draws, acknowledges, echoes, covers, and guides" {
    try check_conformance("go");
}

test "the tigerstyle checker runs under disk faults and power loss and its cache is judged cold" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_tigerstyle_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    var path_buffer: [path_max]u8 = undefined;
    var config = check_tigerstyle_config;
    var catalog: Catalog = .{};
    var cores: pmu_module.Cores = .{};
    var results: [check_tigerstyle_seeds.len]Attempt = @splat(.{});
    var replays: [check_tigerstyle_seeds.len]Attempt = @splat(.{});
    var violations: u32 = 0;

    config.transcript_output = try check_output(&path_buffer, &directory);

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .catalog = &catalog,
        .concurrency = cores.count,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &check_tigerstyle_seeds,
    });

    const property = catalog.find(.always, check_tigerstyle_cache) orelse return error.Unexpected;

    for (&results, check_tigerstyle_seeds) |*result, seed| {
        const evaluated = !catalog.unreached(&result.verdict.hits, property);
        const format = "tigerstyle seed {d}: {d} acknowledged, {d} present, {d} failures, {s}\n";

        std.debug.print(format, .{
            seed,
            result.verdict.acknowledged,
            result.verdict.present,
            result.verdict.failures,
            result.verdict.detail,
        });

        try std.testing.expectEqual(null, result.failure);
        try std.testing.expect(result.verdict.checked);
        try std.testing.expect(evaluated);
        try std.testing.expectEqual(0, result.verdict.agent_errors);
        try std.testing.expect(result.verdict.present <= result.verdict.acknowledged);

        violations += @intFromBool(!result.passed());
    }

    std.debug.print("tigerstyle: {d} of {d} seeds violated a property\n", .{
        violations,
        check_tigerstyle_seeds.len,
    });
}

test "the docker-zig sdk keeps its properties while its daemon is killed, paused, and throttled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_docker_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    var path_buffer: [path_max]u8 = undefined;
    var config = check_docker_config;
    var catalog: Catalog = .{};
    var cores: pmu_module.Cores = .{};
    var results: [check_docker_seeds.len]Attempt = @splat(.{});
    var replays: [check_docker_seeds.len]Attempt = @splat(.{});

    config.transcript_output = try check_output(&path_buffer, &directory);

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .catalog = &catalog,
        .concurrency = cores.count,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &check_docker_seeds,
    });

    const idle = catalog.find(.always, check_docker_idle) orelse return error.Unexpected;

    for (&results, check_docker_seeds) |*result, seed| {
        const format = "docker-zig seed {d}: {d} acknowledged, {d} present, {t}, {s}\n";

        std.debug.print(format, .{
            seed,
            result.verdict.acknowledged,
            result.verdict.present,
            result.verdict.eventually,
            result.verdict.detail,
        });

        try std.testing.expectEqual(null, result.failure);
        try std.testing.expect(result.verdict.checked);
        try std.testing.expectEqual(0, result.verdict.agent_errors);
        try std.testing.expect(!catalog.unreached(&result.verdict.hits, idle));
        try std.testing.expect(result.passed());
    }
}

test "crash delays and fault plans derive from the seed alone" {
    const config: Config = .{
        .cmdline = "",
        .crash_window_ns = 1_000_000,
        .faults = true,
        .kernel = "",
    };

    var differs: u32 = 0;

    for (0..64) |seed| {
        const delay = crash_delay_derive(seed, &config).?;
        const first = faults_derive(seed, &config);
        const again = faults_derive(seed, &config);
        const next = faults_derive(seed + 1, &config);
        const disk_same = std.meta.eql(first.disk, next.disk);
        const weights_same = std.meta.eql(first.weights, next.weights);

        try std.testing.expect(delay <= config.crash_window_ns);
        try std.testing.expectEqual(delay, crash_delay_derive(seed, &config).?);
        try std.testing.expectEqual(first.disk, again.disk);
        try std.testing.expectEqual(first.weights, again.weights);

        differs += @intFromBool(!disk_same or !weights_same);
    }

    const script = [_]Event{.{ .delay_ns = 9, .kind = .kill, .target = .postmaster }};
    const explicit: Faults = .{ .script = &script };

    const fixed: Config = .{
        .cmdline = "",
        .crash_delay_ns = 5,
        .fault_plan = explicit,
        .kernel = "",
    };

    const plain: Config = .{ .cmdline = "", .kernel = "" };

    try std.testing.expect(differs > 60);
    try std.testing.expectEqual(@as(?u64, 5), crash_delay_derive(3, &fixed));
    try std.testing.expectEqual(@as(?u64, null), crash_delay_derive(3, &plain));
    try std.testing.expectEqual(explicit, faults_derive(3, &fixed));
    try std.testing.expectEqual(explicit, faults_derive(4, &fixed));
    try std.testing.expect(faults_derive(3, &plain).idle());
}

test "minimal choices draw the empty plan and an immediate crash" {
    const config: Config = .{
        .cmdline = "",
        .crash_window_ns = 1_000_000,
        .faults = true,
        .kernel = "",
    };

    var plan_stream: Stream = .replay(&.{});
    var crash_stream: Stream = .replay(&.{ 0, 0 });

    try std.testing.expect(faults_draw(&plan_stream, &config).idle());
    try std.testing.expectEqual(@as(?u64, 0), crash_delay_draw(&crash_stream, &config));
    try std.testing.expect(plan_stream.position > 0);
    try std.testing.expectEqual(2, crash_stream.position);
}

test "exploration keeps runs with fresh coverage and forks the newest at a new fork point" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const config: Config = .{ .cmdline = "", .explore_runs = 200, .kernel = "", .seed = 5 };
    const explore = try runner_explore_init(arena, arena, &config, 2);
    const early = [_]ForkPoint{check_point(900)};
    const late = [_]ForkPoint{ check_point(300), check_point(700) };
    var attempt: Attempt = .{ .consumed = check_consumed, .verdict = .{ .checked = true } };

    explore.global.* = @splat(0);
    attempt.coverage_fresh[0] = 17;
    attempt.coverage_fresh_count = 1;
    attempt.coverage_fresh_points[0] = early[0];

    try explore_integrate(explore, &.{ .seed = 5 }, &attempt);
    try explore_integrate(explore, &.{ .seed = 6 }, &attempt);

    try std.testing.expectEqual(2, explore.runs);
    try std.testing.expectEqual(1, explore.corpus_count);
    try std.testing.expectEqualSlices(ForkPoint, &early, explore.corpus[0].fork_points);
    try std.testing.expectEqual(5, explore.corpus[0].choices.seed);
    try std.testing.expectEqual(8, explore.corpus[0].choices.total());
    try std.testing.expect(explore.found == null);

    attempt.coverage_fresh[0..4].* = .{ 17, 40, 41, 42 };
    attempt.coverage_fresh_count = 4;
    attempt.coverage_fresh_points[0..4].* = .{ check_point(100), late[0], null, late[1] };
    attempt.verdict = .{ .checked = true, .failures = 1 };

    try explore_integrate(explore, &.{ .seed = 7 }, &attempt);

    const found = explore.found orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(3, found.run);
    try std.testing.expectEqual(7, found.choices.seed);
    try std.testing.expectEqual(2, explore.corpus_count);
    try std.testing.expectEqualSlices(ForkPoint, &late, explore.corpus[1].fork_points);
    try std.testing.expectEqual(4, coverage_module.count(explore.global));

    try check_explore_picks(explore, &early[0]);

    explore.uniform = true;

    try std.testing.expectEqual(7, explore_pick(explore).seed);
    try std.testing.expectEqual(null, explore_pick(explore).entry);
}

test "a full choice pool stops the corpus from growing and still records the violation" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const config: Config = .{ .cmdline = "", .explore_runs = 8, .kernel = "", .seed = 5 };
    const pool_words = try arena.alloc(u64, @divExact(choices_size_max, @sizeOf(u64)) + 4);
    var pool: std.heap.FixedBufferAllocator = .init(std.mem.sliceAsBytes(pool_words));
    const explore = try runner_explore_init(arena, pool.allocator(), &config, 1);
    var attempt: Attempt = .{ .consumed = check_consumed, .verdict = .{ .checked = true } };

    explore.global.* = @splat(0);
    attempt.coverage_fresh[0] = 17;
    attempt.coverage_fresh_count = 1;
    attempt.coverage_fresh_points[0] = check_point(900);

    try explore_integrate(explore, &.{ .seed = 5 }, &attempt);

    const corpus_full_first = explore.corpus_full;
    const corpus_count_first = explore.corpus_count;

    attempt.coverage_fresh[0] = 18;
    attempt.verdict = .{ .checked = true, .failures = 1 };

    try explore_integrate(explore, &.{ .seed = 6 }, &attempt);

    const found = explore.found orelse return error.TestUnexpectedResult;
    const found_total = found.choices.total();

    try std.testing.expect(corpus_full_first);
    try std.testing.expectEqual(0, corpus_count_first);
    try std.testing.expectEqual(0, explore.corpus_count);
    try std.testing.expectEqual(2, explore.runs);
    try std.testing.expectEqual(6, found.choices.seed);
    try std.testing.expectEqual(8, found_total);
    try std.testing.expectEqual(2, coverage_module.count(explore.global));
}

test "a saved reproducer loads back as the same choices" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const arena = arena_state.allocator();
    const capacities: [choices_module.stream_count]u32 = .{ 6, 1, 0, 700, 2, 30, 20 };
    var path_buffer: [path_max]u8 = undefined;
    var saved: Choices = .{};
    var loaded: Choices = .{};

    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/reproducer.zon", .{
        &directory.sub_path,
    });

    try saved.init_capacity(arena, &capacities);
    saved.record(&stream_seeds(77), &capacities);
    saved.guest_seed = 78;
    saved.seed = 77;

    try reproducer_save(std.testing.io, path, &saved);
    try reproducer_load(std.testing.io, std.testing.allocator, arena, path, &loaded);

    const loaded_smaller = loaded.smaller(&saved);
    const saved_smaller = saved.smaller(&loaded);

    try std.testing.expect(!loaded_smaller);
    try std.testing.expect(!saved_smaller);
    try std.testing.expectEqual(saved.seed, loaded.seed);
    try std.testing.expectEqual(saved.guest_seed, loaded.guest_seed);
    try std.testing.expectEqualSlices(u64, saved.slice(.jitter), loaded.slice(.jitter));
}

test "a ledger without row locks loses an update and the seed reproduces it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    var path_buffer: [path_max]u8 = undefined;

    var config: Config = .{
        .cmdline = check_cmdline_app ++ " dst.mode=run",
        .cmdline_reboot = check_cmdline_app ++ " dst.mode=check",
        .disk = check_app_path,
        .jitter_ns_max = check_app_jitter_ns_max,
        .kernel = check_kernel_path,
        .memory_mib = 1024,
        .preemption = true,
        .transcript_output = try check_output(&path_buffer, &directory),
    };

    var cores: pmu_module.Cores = .{};
    var locked: [1]Attempt = @splat(.{});
    var locked_replays: [1]Attempt = @splat(.{});
    var unlocked: [1]Attempt = @splat(.{});
    var unlocked_replays: [1]Attempt = @splat(.{});
    const seeds = [_]u64{check_app_seed};

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &locked_replays,
        .results = &locked,
        .seeds = &seeds,
    });

    const transcript = try check_transcript(gpa, &directory, check_app_seed);
    defer gpa.free(transcript);

    const drawn = std.fmt.comptimePrint("DST WORKLOAD SEED {d} TRANSFERS ", .{check_app_seed});
    const transfers = try check_number(transcript, drawn);

    config.cmdline = check_cmdline_app ++ " dst.mode=run dst.locking=0";
    config.transcript_output = "";

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &unlocked_replays,
        .results = &unlocked,
        .seeds = &seeds,
    });

    try std.testing.expect(locked[0].passed());
    try std.testing.expect(transfers > 0);
    try std.testing.expectEqual(transfers, locked[0].verdict.acknowledged);
    try std.testing.expect(!unlocked[0].passed());
    try std.testing.expect(unlocked[0].verdict.failures > 0);
    try std.testing.expect(unlocked[0].same(&unlocked_replays[0]));
}

test "celery loses accepted transfers without an append-only file and keeps them with one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var config: Config = .{
        .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_celery,
        .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_celery,
        .crash_window_ns = check_app_crash_window_ns,
        .disk = check_app_path,
        .jitter_ns_max = check_app_jitter_ns_max,
        .kernel = check_kernel_path,
        .memory_mib = 1024,
        .preemption = true,
    };

    var cores: pmu_module.Cores = .{};
    var lossy: [1]Attempt = @splat(.{});
    var lossy_replays: [1]Attempt = @splat(.{});
    var durable: [1]Attempt = @splat(.{});
    var durable_replays: [1]Attempt = @splat(.{});
    const seeds = [_]u64{check_celery_seed};

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &lossy_replays,
        .results = &lossy,
        .seeds = &seeds,
    });

    config.cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_celery ++ check_celery_durable;

    config.cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_celery ++
        check_celery_durable;

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &durable_replays,
        .results = &durable,
        .seeds = &seeds,
    });

    try std.testing.expect(lossy[0].verdict.acknowledged > 0);
    try std.testing.expect(lossy[0].verdict.lost > 0);
    try std.testing.expect(lossy[0].same(&lossy_replays[0]));
    try std.testing.expect(durable[0].passed());
    try std.testing.expectEqual(lossy[0].verdict.acknowledged, durable[0].verdict.acknowledged);
}

test "a replay reports interrupted, skipped, reproduced, or diverged, in that order" {
    const ran: Outcome = std.mem.zeroInit(Outcome, .{ .cycles = 2, .memory_hash = 7 });
    const other: Outcome = std.mem.zeroInit(Outcome, .{ .cycles = 2, .memory_hash = 8 });
    const first: Attempt = .{ .outcome = ran };
    const interrupted: Attempt = .{ .failure = error.Interrupted, .outcome = ran };
    const skipped: Attempt = .{};
    const same: Attempt = .{ .outcome = ran };
    const diverged: Attempt = .{ .outcome = other };
    const failed: Attempt = .{ .failure = error.GuestStalled };

    try std.testing.expectEqualStrings(
        "interrupted before it finished",
        replay_summary(&first, &interrupted),
    );

    try std.testing.expectEqualStrings("skipped by replay_max", replay_summary(&first, &skipped));
    try std.testing.expectEqualStrings("reproduced the same run", replay_summary(&first, &same));
    try std.testing.expectEqualStrings("DIVERGED", replay_summary(&first, &diverged));
    try std.testing.expectEqualStrings("DIVERGED", replay_summary(&first, &failed));
}

test "a replay cap replays the first failures in seed order and skips the rest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    const config: Config = .{
        .cmdline = check_cmdline_app ++ " dst.mode=run dst.locking=0",
        .cmdline_reboot = check_cmdline_app ++ " dst.mode=check",
        .disk = check_app_path,
        .jitter_ns_max = check_app_jitter_ns_max,
        .kernel = check_kernel_path,
        .memory_mib = 1024,
        .preemption = true,
    };

    const seeds = [_]u64{ 7, 8, 9 };
    var cores: pmu_module.Cores = .{};
    var results: [seeds.len]Attempt = @splat(.{});
    var replays: [seeds.len]Attempt = @splat(.{});
    var failures: u32 = 0;
    var replayed: u32 = 0;

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = @min(cores.count, seeds.len),
        .cores = cores.slice(),
        .replay_max = 1,
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    for (&results, &replays) |*result, *replay| {
        if (result.passed()) continue;

        failures += 1;

        if (failures == 1) try std.testing.expect(result.same(replay));
        if (failures > 1) try std.testing.expectEqual(0, replay.outcome.cycles);

        replayed += @intFromBool(replay.outcome.cycles > 0);
    }

    try std.testing.expect(failures >= 2);
    try std.testing.expectEqual(1, replayed);
}

test "seeds forked in parallel from one boot match the same seeds forked one at a time" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    const config: Config = .{
        .cmdline = check_cmdline_app ++ " dst.mode=run",
        .cmdline_reboot = check_cmdline_app ++ " dst.mode=check",
        .crash_window_ns = check_app_crash_window_ns,
        .disk = check_app_path,
        .faults = true,
        .jitter_ns_max = check_app_jitter_ns_max,
        .kernel = check_kernel_path,
        .memory_mib = 1024,
        .preemption = true,
    };

    var cores: pmu_module.Cores = .{};
    var parallel: [check_app_seeds.len]Attempt = @splat(.{});
    var parallel_replays: [check_app_seeds.len]Attempt = @splat(.{});
    var serial: [check_app_seeds.len]Attempt = @splat(.{});
    var serial_replays: [check_app_seeds.len]Attempt = @splat(.{});

    try check_cores(&cores);
    try std.testing.expect(cores.count >= check_app_seeds.len);

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = check_app_seeds.len,
        .cores = cores.slice(),
        .replays = &parallel_replays,
        .results = &parallel,
        .seeds = &check_app_seeds,
    });

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &serial_replays,
        .results = &serial,
        .seeds = &check_app_seeds,
    });

    for (&parallel, &serial, &parallel_replays, &serial_replays) |*one, *two, *replay, *again| {
        try std.testing.expectEqual(@as(?anyerror, null), one.failure);
        try std.testing.expect(one.same(two));
        try std.testing.expect(replay.same(again));
    }
}

test "every fault family fires against the row-locked ledger and it keeps every transfer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    var catalog: Catalog = .{};
    var output_buffer: [path_max]u8 = undefined;
    var results: [check_ledger_plans.len]Attempt = @splat(.{});
    var replays: [check_ledger_plans.len]Attempt = @splat(.{});

    const config: Config = .{
        .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_tcp,
        .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_tcp,
        .disk = check_app_path,
        .kernel = check_kernel_path,
        .memory_mib = 1024,
        .preemption = true,
        .transcript_output = try check_output(&output_buffer, &directory),
    };

    try check_faults(gpa, kernel, &config, &.{
        .catalog = &catalog,
        .plans = &check_ledger_plans,
        .replays = &replays,
        .results = &results,
        .seeds = &check_ledger_seeds,
    });

    for (results) |result| try std.testing.expect(result.passed());

    try check_ledger_catalog(&catalog, &results);
    try check_ledger_evidence(gpa, &directory, &results);
}

test "a forward clock jump expires redis leases and only row locks keep every update" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    const jumps: [check_lease_seeds.len]Faults = @splat(check_lease_plan);
    const plans = jumps ++ [_]Faults{ .{}, .{} };
    const seeds = check_lease_seeds ++ check_lease_controls;
    var leased: [plans.len]Attempt = @splat(.{});
    var leased_replays: [plans.len]Attempt = @splat(.{});
    var locked: [check_lease_controls.len]Attempt = @splat(.{});
    var locked_replays: [check_lease_controls.len]Attempt = @splat(.{});

    const leases: Config = .{
        .cmdline = check_cmdline_app ++ " dst.mode=run dst.locking=redis" ++ check_critical,
        .cmdline_reboot = check_cmdline_app ++ " dst.mode=check dst.locking=redis" ++
            check_critical,
        .disk = check_app_path,
        .kernel = check_kernel_path,
        .memory_mib = 1024,
        .preemption = true,
    };

    const rows: Config = .{
        .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_critical,
        .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_critical,
        .disk = check_app_path,
        .kernel = check_kernel_path,
        .memory_mib = 1024,
        .preemption = true,
    };

    try check_faults(gpa, kernel, &leases, &.{
        .plans = &plans,
        .replay_all = false,
        .replays = &leased_replays,
        .results = &leased,
        .seeds = &seeds,
    });

    try check_faults(gpa, kernel, &rows, &.{
        .plans = jumps[0..check_lease_controls.len],
        .replay_all = false,
        .replays = &locked_replays,
        .results = &locked,
        .seeds = &check_lease_controls,
    });

    var broken: u32 = 0;

    for (leased[0..check_lease_seeds.len]) |result| {
        if (result.passed()) continue;

        broken += 1;

        try std.testing.expect(result.verdict.failures > 0);
    }

    for (leased[check_lease_seeds.len..]) |result| try std.testing.expect(result.passed());
    for (locked) |result| try std.testing.expect(result.passed());

    try std.testing.expect(broken > 0);
}

test "a shrunk lease failure keeps only a forward clock jump and its reproducer replays it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});
    var shrunk: [1]Shrunk = @splat(.{});

    try check_lease_shrink(gpa, kernel, arena, &results, &replays, &shrunk);

    const original = &results[0];
    const minimal = &shrunk[0];
    const detail = original.detail[0..original.detail_length];
    const events = minimal.attempt.events[0..minimal.attempt.events_count];
    var plan_stream = minimal.choices.stream(.plan);
    const faults = faults_draw(&plan_stream, &check_shrink_config);
    const jump_ns_min: i64 = check_lease_timeout_ns - check_lease_hold_ns_max;
    var recorded: Choices = .{};

    try check_record(arena, check_shrink_seed, original, &recorded);

    try std.testing.expect(std.mem.startsWith(u8, detail, check_lease_lost));
    try std.testing.expect(original.same(&replays[0]));
    try std.testing.expect(minimal.shrunk);
    try std.testing.expect(minimal.replayed);
    try std.testing.expectEqual(attempt_signature(original), attempt_signature(&minimal.attempt));
    try std.testing.expect(minimal.choices.smaller(&recorded));
    try std.testing.expectEqual(faults_module.Disk{}, faults.disk);
    try std.testing.expectEqual(1, events.len);
    try std.testing.expectEqual(faults_module.EventKind.clock_jump, events[0].kind);
    try std.testing.expect(events[0].clock_jump_ns >= jump_ns_min);
    try std.testing.expect(minimal.attempt.verdict.acknowledged < original.verdict.acknowledged);

    try check_shrunk_replay(gpa, kernel, arena, minimal);
}

test "a likelihood curve over the shrunk lease failure turns high where its clock jump is drawn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});
    var shrunk: [1]Shrunk = @splat(.{});

    try check_lease_shrink(gpa, kernel, arena, &results, &replays, &shrunk);

    const minimal = &shrunk[0];

    try std.testing.expect(minimal.shrunk);
    try std.testing.expectEqual(1, minimal.attempt.events_count);

    const likelihood = try check_likelihood(gpa, kernel, arena, &minimal.choices);
    const jump_exit = minimal.attempt.event_points[0].exits;
    const runs = check_likelihood_runs;
    var before: u32 = 0;
    var after: u32 = 0;

    for (likelihood.exits, likelihood.failures, likelihood.varied) |exit, failures, varied| {
        if (exit < jump_exit) {
            try std.testing.expect(varied);
            try std.testing.expect(failures * 2 < runs);

            before += 1;
        } else {
            try std.testing.expect(failures * 2 > runs);

            after += 1;
        }
    }

    try std.testing.expect(before > 0);
    try std.testing.expect(after > 0);
}

test "a shell at the last exit before a power loss counts every acknowledged transfer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const seeds = [_]u64{check_debug_seed};
    var config = check_debug_config;
    var cores: pmu_module.Cores = .{};
    var choices: [1]Choices = .{.{}};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});
    var debugged: Attempt = .{};

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    try check_record(arena_state.allocator(), check_debug_seed, &results[0], &choices[0]);

    config.debug_command = check_debug_command;
    config.debug_exit = results[0].outcome.cycle_first_exits - 1;

    try check_batch(gpa, kernel, &config, &.{
        .choices = &choices,
        .concurrency = 1,
        .cores = cores.slice(),
        .debug = &debugged,
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    const output = debugged.debug.bytes[0..@min(debugged.debug.length, debug_output_max)];
    const committed = try check_debug_count(output);
    const acknowledged = results[0].verdict.acknowledged;

    try std.testing.expectEqual(2, results[0].outcome.cycles);
    try std.testing.expectEqual(null, debugged.failure);
    try std.testing.expectEqual(config.debug_exit.?, debugged.debug.exit);
    try std.testing.expect(acknowledged > 0);
    try std.testing.expect(committed >= acknowledged);
}

test "a partition between a redis primary and its replica loses acked writes after a failover" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var cores: pmu_module.Cores = .{};
    var replicated: [check_replica_seeds.len]Attempt = @splat(.{});
    var replicated_replays: [check_replica_seeds.len]Attempt = @splat(.{});
    var single: [check_replica_seeds.len]Attempt = @splat(.{});
    var single_replays: [check_replica_seeds.len]Attempt = @splat(.{});
    var single_config = check_replica_config;
    var lost: u32 = 0;

    single_config.cmdline = check_cmdline_app ++ " dst.mode=run dst.app=replica dst.replicas=0";

    try check_cores(&cores);

    try check_batch(gpa, kernel, &check_replica_config, &.{
        .concurrency = cores.count,
        .cores = cores.slice(),
        .replay_max = 1,
        .replays = &replicated_replays,
        .results = &replicated,
        .seeds = &check_replica_seeds,
    });

    try check_batch(gpa, kernel, &single_config, &.{
        .concurrency = cores.count,
        .cores = cores.slice(),
        .replay_max = 1,
        .replays = &single_replays,
        .results = &single,
        .seeds = &check_replica_seeds,
    });

    for (&replicated, &single) |*failover, *kept| {
        const detail = failover.detail[0..failover.detail_length];

        try std.testing.expectEqual(null, failover.failure);
        try std.testing.expect(kept.passed());

        if (failover.passed()) continue;

        try std.testing.expect(std.mem.startsWith(u8, detail, check_replica_kept));

        lost += 1;
    }

    try std.testing.expect(lost > 0);
}

test "a node pause freezes the node's cgroup and stops its progress counter until the thaw" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const seeds = [_]u64{check_replica_seeds[0]};
    var path_buffer: [path_max]u8 = undefined;
    var config = check_replica_config;
    var cores: pmu_module.Cores = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});

    config.cmdline = check_cmdline_app ++ " dst.mode=run dst.app=replica dst.replicas=0";
    config.fault_plan = .{ .script = &check_replica_pause };
    config.transcript_output = try check_output(&path_buffer, &directory);

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    const transcript = try check_transcript(gpa, &directory, seeds[0]);
    defer gpa.free(transcript);

    const start = try check_number(transcript, "DST FAULT pause node primary frozen 1 progress ");
    const end = try check_number(transcript, "DST FAULT pause node primary progress ");
    const last = try check_number(transcript, "DST PROGRESS primary ");

    try std.testing.expect(results[0].passed());
    try std.testing.expect(start > 0);
    try std.testing.expectEqual(start, end);
    try std.testing.expect(last > end);
}

test "the ledger runs with its database and its cache each on a node of its own" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const seeds = [_]u64{check_app_seed};
    var path_buffer: [path_max]u8 = undefined;
    var config = check_nodes_config;
    var cores: pmu_module.Cores = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});

    config.transcript_output = try check_output(&path_buffer, &directory);

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    const transcript = try check_transcript(gpa, &directory, seeds[0]);
    defer gpa.free(transcript);

    try check_contains(transcript, "DST NODE db 10.77.0.2");
    try check_contains(transcript, "DST NODE cache 10.77.0.3");
    try std.testing.expect(results[0].passed());
    try std.testing.expect(results[0].verdict.acknowledged > 0);
}

test "the likelihood points double their distance from ready and end one before the last" {
    var exits: [5]u64 = undefined;

    likelihood_exits(&exits, 100, 1701);

    try std.testing.expectEqualSlices(u64, &.{ 200, 300, 500, 900, 1700 }, &exits);

    likelihood_exits(&exits, 100, 106);

    try std.testing.expectEqualSlices(u64, &.{ 101, 102, 103, 104, 105 }, &exits);

    likelihood_exits(exits[0..1], 100, 102);

    try std.testing.expectEqual(101, exits[0]);

    var prng: std.Random.DefaultPrng = .init(0x11e1);

    for (0..256) |_| {
        const count = 1 + prng.random().uintLessThan(usize, exits.len);
        const ready = prng.random().uintLessThan(u64, 1 << 40);
        const span = count + prng.random().uintLessThan(u64, 1 << 30);

        likelihood_exits(exits[0..count], ready, ready + span + 1);

        try std.testing.expect(exits[0] > ready);
        try std.testing.expectEqual(ready + span, exits[count - 1]);

        for (exits[0 .. count - 1], exits[1..count]) |earlier, later| {
            try std.testing.expect(earlier < later);
            try std.testing.expect(later - ready <= 2 * (earlier - ready) + 1);
        }
    }
}

test "a likelihood point counts only the failures that match the reproducer's signature" {
    var failing: Attempt = .{ .failure = error.EventMismatch };
    var other: Attempt = .{ .failure = error.AgentFailed };
    var results: [6]Attempt = undefined;
    var exits: [2]u64 = .{ 10, 20 };
    var failures: [2]u32 = undefined;
    var varied: [2]bool = undefined;
    var probe: Attempt = .{};

    failing.outcome.exits = 1;
    other.outcome.exits = 2;
    results = .{ failing, failing, other, failing, failing, failing };

    var likelihood: Likelihood = .{
        .exits = &exits,
        .failures = &failures,
        .jobs = &.{},
        .probe = &probe,
        .results = &results,
        .signature = attempt_signature(&failing),
        .varied = &varied,
    };

    likelihood_count(&likelihood);

    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, &failures);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &varied);

    for (&results) |*result| result.* = failing;

    likelihood_count(&likelihood);

    try std.testing.expectEqualSlices(u32, &.{ 3, 3 }, &failures);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &varied);
}

test "guided search forks from fresh coverage and solves a maze that uniform seeds miss" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const config = &check_maze_config;
    const holders = snapshot_holders_max_default;
    const guided = try check_explore(gpa, kernel, arena, config, false, check_maze_runs, holders);
    const uniform = try check_explore(gpa, kernel, arena, config, true, check_maze_runs, holders);
    const found = guided.found orelse return error.TestUnexpectedResult;
    const detail = found.attempt.detail[0..found.attempt.detail_length];
    const guided_bits = guided.history[guided.history_count - 1];
    const uniform_bits = uniform.history[uniform.history_count - 1];

    try std.testing.expect(std.mem.startsWith(u8, detail, check_maze_solved));
    try std.testing.expect(uniform.found == null);
    try std.testing.expect(guided_bits > uniform_bits);
    try std.testing.expectEqual(check_maze_runs, guided.runs);
    try std.testing.expectEqual(check_maze_runs, uniform.runs);
    try std.testing.expect(guided.forks_past_ready > 0);
    try std.testing.expectEqual(0, guided.forks_diverged);
    try std.testing.expectEqual(0, uniform.forks);

    try check_found_replay(gpa, kernel, &found);
}

test "numeric guidance climbs a counter whose stages share every line and coverage cannot" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const runs = check_counter_runs;
    const holders = snapshot_holders_max_default;
    const config = &check_counter_config;
    var unguided_config = check_counter_config;

    unguided_config.explore_guidance = false;

    const guided = try check_explore(gpa, kernel, arena, config, false, runs, holders);
    const unguided = try check_explore(gpa, kernel, arena, &unguided_config, false, runs, holders);
    const uniform = try check_explore(gpa, kernel, arena, config, true, runs, holders);
    const found = guided.found orelse return error.TestUnexpectedResult;
    const detail = found.attempt.detail[0..found.attempt.detail_length];

    try std.testing.expect(std.mem.startsWith(u8, detail, check_counter_solved));
    try std.testing.expect(unguided.found == null);
    try std.testing.expect(uniform.found == null);
    try std.testing.expectEqual(1, guided.best_count);
    try std.testing.expectEqual(check_counter_stages, guided.best[0].value);
}

test "every continuation replays its prefix to the recorded fork point before it forks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const config = &check_maze_config;
    const explore = try check_explore(gpa, kernel, arena, config, false, check_fork_runs, 0);
    const forks = check_fork_runs - check_maze_seeds.len;

    try std.testing.expectEqual(forks, explore.forks);
    try std.testing.expect(explore.forks_past_ready > 0);
    try std.testing.expectEqual(0, explore.forks_diverged);
}

test "four processes drawing at once receive whole words and together the stream's first" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const seeds = [_]u64{check_draws_seed};
    const workload = @backingInt(StreamName.workload);
    var path_buffer: [path_max]u8 = undefined;
    var config = check_draws_config;
    var cores: pmu_module.Cores = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});
    var drawn: [check_draws_total]u64 = undefined;
    var expected: [check_draws_total]u64 = undefined;
    var stream: Stream = .init(stream_seeds(check_draws_seed)[workload]);

    config.transcript_output = try check_output(&path_buffer, &directory);

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    const transcript = try check_transcript(gpa, &directory, check_draws_seed);
    defer gpa.free(transcript);

    const count = try check_draws_parse(transcript, &drawn);

    for (&expected) |*word| word.* = stream.word();

    std.mem.sortUnstable(u64, &drawn, {}, std.sort.asc(u64));
    std.mem.sortUnstable(u64, &expected, {}, std.sort.asc(u64));

    try std.testing.expect(results[0].passed());
    try std.testing.expectEqual(check_draws_total, count);
    try std.testing.expectEqual(check_draws_total, results[0].consumed[workload]);
    try std.testing.expectEqualSlices(u64, &expected, &drawn);
}

test "a cleared workload stream runs no transfer and a cleared events stream serves no event" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const seeds = [_]u64{check_events_seed};
    var cores: pmu_module.Cores = .{};
    var choices: [1]Choices = @splat(.{});
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});
    var cleared: [1]Attempt = @splat(.{});
    var cleared_replays: [1]Attempt = @splat(.{});

    try check_cores(&cores);

    try check_batch(gpa, kernel, &check_events_config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    try check_record(arena_state.allocator(), check_events_seed, &results[0], &choices[0]);

    choices[0].counts[@backingInt(StreamName.events)] = 0;
    choices[0].counts[@backingInt(StreamName.workload)] = 0;

    try check_batch(gpa, kernel, &check_events_config, &.{
        .choices = &choices,
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &cleared_replays,
        .results = &cleared,
        .seeds = &seeds,
    });

    try std.testing.expect(results[0].events_count > 0);
    try std.testing.expect(results[0].verdict.acknowledged > 0);
    try std.testing.expectEqual(0, cleared[0].events_count);
    try std.testing.expectEqual(0, cleared[0].verdict.acknowledged);
    try std.testing.expect(cleared[0].passed());
}

test "a fork reproduces the events drawn before it and redraws the ones after it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const seeds = [_]u64{check_events_seed};
    var cores: pmu_module.Cores = .{};
    var parent_choices: Choices = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});

    try check_cores(&cores);

    try check_batch(gpa, kernel, &check_events_config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    try std.testing.expect(results[0].events_count > check_fork_event);
    try check_record(arena, check_events_seed, &results[0], &parent_choices);

    const forked = try arena.create([check_fork_seeds]Attempt);

    try check_forks(gpa, kernel, &results[0], &parent_choices, forked);
    try check_fork_splice(gpa, kernel, arena, &results[0], &parent_choices, &forked[0]);
}

test "a continuation served by a snapshot holder matches the same continuation after a replay" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const seeds = [_]u64{check_events_seed};
    var cores: pmu_module.Cores = .{};
    var parent_choices: Choices = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});
    var stats: HolderStats = .{};

    try check_cores(&cores);

    try check_batch(gpa, kernel, &check_events_config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    try std.testing.expect(results[0].events_count >= check_holder_points);
    try check_record(arena, check_events_seed, &results[0], &parent_choices);

    const held = try arena.create([check_holder_jobs]Attempt);
    const replayed = try arena.create([check_holder_jobs]Attempt);

    try check_holder_batch(gpa, kernel, &results[0], &parent_choices, held, &stats);
    try check_holder_batch(gpa, kernel, &results[0], &parent_choices, replayed, null);

    for (held, replayed) |*from_holder, *from_replay| {
        try std.testing.expectEqual(null, from_holder.failure);
        try std.testing.expect(from_holder.same(from_replay));
        try std.testing.expect(check_events_same(from_holder, from_replay));
    }

    try std.testing.expectEqual(check_holder_points, stats.spawned);
    try std.testing.expectEqual(check_holder_jobs - check_holder_points, stats.served);
}

test "a paused web worker outlives its redis lease and row locks keep every transfer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    const results = try gpa.create([check_kind_seeds.len]Attempt);
    defer gpa.destroy(results);

    const plan = &check_pause_plan;
    const leased = try check_kind_runs(gpa, kernel, &check_lease_config, plan, results);
    const locked = try check_kind_runs(gpa, kernel, &check_rows_config, plan, results);

    try std.testing.expect(leased > 0);
    try std.testing.expectEqual(0, locked);
}

test "a thread pause past the heartbeat deadline is noticed and a shorter one is not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    const plans = [_]Faults{ check_heartbeat_long_plan, check_heartbeat_short_plan };
    const seeds = [_]u64{ check_heartbeat_seed, check_heartbeat_seed };
    var catalog: Catalog = .{};
    var results: [plans.len]Attempt = @splat(.{});
    var replays: [plans.len]Attempt = @splat(.{});

    try check_faults(gpa, kernel, &check_heartbeat_config, &.{
        .catalog = &catalog,
        .plans = &plans,
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    const stalled = catalog.find(.sometimes, check_heartbeat_stalled) orelse {
        return error.PropertyMissing;
    };

    try std.testing.expect(!catalog.unreached(&results[0].verdict.hits, stalled));
    try std.testing.expect(catalog.unreached(&results[1].verdict.hits, stalled));
    try std.testing.expect(results[0].passed());
    try std.testing.expect(results[1].passed());
}

test "a computed critical section loses its lease at the slowest cpu rate and not at the default" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    const results = try gpa.create([check_kind_seeds.len]Attempt);
    defer gpa.destroy(results);

    const config = &check_spin_lease_config;
    const slowest_results = results[0..check_rate_slowest_runs];
    const slowest_plan = &check_rate_slowest_plan;
    const slowest = try check_kind_runs(gpa, kernel, config, slowest_plan, slowest_results);
    const default = try check_kind_runs(gpa, kernel, config, &.{}, results);

    try std.testing.expect(slowest > 0);
    try std.testing.expectEqual(0, default);
}

test "reply-only loss on the redis link loses an accepted task and request-only loss does not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    const results = try gpa.create([check_kind_seeds.len]Attempt);
    defer gpa.destroy(results);

    const config = &check_celery_protected_config;
    const replies = try check_kind_runs(gpa, kernel, config, &check_reply_loss_plan, results);
    const lost_replies = check_kind_lost(results);
    const requests = try check_kind_runs(gpa, kernel, config, &check_request_loss_plan, results);
    const lost_requests = check_kind_lost(results);

    try std.testing.expect(replies > 0);
    try std.testing.expect(lost_replies > 0);
    try std.testing.expectEqual(0, requests);
    try std.testing.expectEqual(0, lost_requests);
}

test "a request-only fault drops only requests on its link and a reply-only one only replies" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const plans = [_]Faults{check_direction_plan};
    const seeds = [_]u64{check_kind_seeds[0]};
    var path_buffer: [path_max]u8 = undefined;
    var config = check_celery_protected_config;
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});

    config.transcript_output = try check_output(&path_buffer, &directory);

    try check_faults(gpa, kernel, &config, &.{
        .plans = &plans,
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    const transcript = try check_transcript(gpa, &directory, seeds[0]);
    defer gpa.free(transcript);

    const ended = "DST FAULT network impairment end redis ";
    const requests = try check_drops(transcript, ended ++ "requests ");
    const replies = try check_drops(transcript, ended ++ "replies ");

    try std.testing.expect(requests.requests > 0);
    try std.testing.expectEqual(0, requests.replies);
    try std.testing.expectEqual(requests.requests, replies.requests);
    try std.testing.expect(replies.replies > 0);
}

test "a throttled web worker inside a computed critical section loses its redis lease" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    const results = try gpa.create([check_kind_seeds.len]Attempt);
    defer gpa.destroy(results);

    const plan = &check_throttle_plan;
    const leased = try check_kind_runs(gpa, kernel, &check_spin_lease_config, plan, results);
    const locked = try check_kind_runs(gpa, kernel, &check_spin_rows_config, plan, results);

    try std.testing.expect(leased > 0);
    try std.testing.expectEqual(0, locked);
}

test "a celery pool kill during worker startup fails the eventually phase and a later kill not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    const early: [check_phase_seeds.len]Faults = @splat(check_startup_kill_plan);
    const late: [check_phase_seeds.len]Faults = @splat(check_running_kill_plan);
    const plans = early ++ late;
    const seeds = check_phase_seeds ++ check_phase_seeds;
    var results: [plans.len]Attempt = @splat(.{});
    var replays: [plans.len]Attempt = @splat(.{});

    try check_faults(gpa, kernel, &check_celery_phase_config, &.{
        .plans = &plans,
        .replay_all = false,
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    for (results[0..check_phase_seeds.len]) |*result| {
        try std.testing.expectEqual(verdict_module.Eventually.failed, result.verdict.eventually);
    }

    for (results[check_phase_seeds.len..]) |*result| {
        try std.testing.expectEqual(verdict_module.Eventually.passed, result.verdict.eventually);
        try std.testing.expect(result.passed());
    }
}

test "deleting the netem qdiscs at the end of the fault window lets the eventually phase pass" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const plans: [check_phase_seeds.len]Faults = @splat(check_long_partition_plan);
    var config = check_partition_phase_config;
    var output_buffer: [path_max]u8 = undefined;
    var results: [plans.len]Attempt = @splat(.{});
    var replays: [plans.len]Attempt = @splat(.{});

    config.transcript_output = try check_output(&output_buffer, &directory);

    try check_faults(gpa, kernel, &config, &.{
        .plans = &plans,
        .replay_all = false,
        .replays = &replays,
        .results = &results,
        .seeds = &check_phase_seeds,
    });

    for (&results, check_phase_seeds) |*result, seed| {
        const transcript = try check_transcript(gpa, &directory, seed);
        defer gpa.free(transcript);

        try check_contains(transcript, "DST FAULT network partition start postgres");
        try check_contains(transcript, "DST QUIET");
        try std.testing.expectEqual(verdict_module.Eventually.passed, result.verdict.eventually);
        try std.testing.expect(result.passed());
    }
}

test "two and four processors boot the ledger and every one of them comes online" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    try check_smp_boot(gpa, kernel, 2);
    try check_smp_boot(gpa, kernel, 4);
}

test "the two-processor ledger gives one fingerprint run after run and at a wider margin" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const seeds = [_]u64{check_app_seed};
    var path_buffer: [path_max]u8 = undefined;
    var config = check_smp_config;
    var cores: pmu_module.Cores = .{};
    var first: [1]Attempt = @splat(.{});
    var replays_first: [1]Attempt = @splat(.{});
    var second: [1]Attempt = @splat(.{});
    var replays_second: [1]Attempt = @splat(.{});

    config.transcript_output = try check_output(&path_buffer, &directory);

    try check_cores(&cores);

    const runs = [_]*[1]Attempt{ &first, &second };
    const runs_replayed = [_]*[1]Attempt{ &replays_first, &replays_second };

    for (runs, runs_replayed) |results, replays| {
        try check_batch(gpa, kernel, &config, &.{
            .concurrency = 1,
            .cores = cores.slice(),
            .replay_all = true,
            .replays = replays,
            .results = results,
            .seeds = &seeds,
        });
    }

    const transcript = try check_transcript(gpa, &directory, check_app_seed);
    defer gpa.free(transcript);

    try check_contains(transcript, "DST CPUS 2");
    try check_cpus_ran(&first[0].outcome, 2);
    try std.testing.expect(first[0].failure == null);
    try std.testing.expect(first[0].same(&replays_first[0]));
    try std.testing.expect(first[0].same(&second[0]));
    try std.testing.expect(second[0].same(&replays_second[0]));
}

test "celery loses accepted transfers to a killed redis, a partition, and the oom killer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    var output_buffer: [path_max]u8 = undefined;
    var results: [check_celery_plans.len]Attempt = @splat(.{});
    var replays: [check_celery_plans.len]Attempt = @splat(.{});

    const config: Config = .{
        .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_celery ++ check_tcp,
        .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_celery ++ check_tcp,
        .disk = check_app_path,
        .kernel = check_kernel_path,
        .memory_mib = 1024,
        .preemption = true,
        .transcript_output = try check_output(&output_buffer, &directory),
    };

    try check_faults(gpa, kernel, &config, &.{
        .plans = &check_celery_plans,
        .replays = &replays,
        .results = &results,
        .seeds = &check_celery_seeds,
    });

    for (results) |result| {
        try std.testing.expect(result.verdict.checked);
        try std.testing.expect(result.verdict.lost > 0);
    }

    try check_celery_evidence(gpa, &directory);
}

test "protected celery keeps every accepted transfer except ones popped and never recorded" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_app_path, .{}) catch return error.SkipZigTest;

    const pops: [check_celery_pop_seeds.len]Faults = @splat(check_celery_pop_plan);
    const plans = check_celery_plans ++ pops;
    const seeds = check_celery_seeds ++ check_celery_pop_seeds;
    var results: [plans.len]Attempt = @splat(.{});
    var replays: [plans.len]Attempt = @splat(.{});

    const config: Config = .{
        .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_celery_protected,
        .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_celery_protected,
        .disk = check_app_path,
        .kernel = check_kernel_path,
        .memory_mib = 1024,
        .preemption = true,
    };

    try check_faults(gpa, kernel, &config, &.{
        .plans = &plans,
        .replay_all = false,
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    var lost: u32 = 0;

    for (results[0..check_celery_plans.len]) |result| try std.testing.expect(result.passed());

    for (results[check_celery_plans.len..]) |result| {
        try std.testing.expect(result.verdict.checked);
        try std.testing.expectEqual(@as(u32, 0), result.verdict.failures);

        lost += result.verdict.lost;
    }

    try std.testing.expect(lost > 0);
}

const check_app_crash_window_ns = 1_500_000_000;
const check_app_jitter_ns_max = 300_000;
const check_app_path = "images/app.ext4";
const check_app_seed = 7;
const check_app_seeds = [_]u64{ 7, 8 };
const check_branches_max = 8;
const check_celery = " dst.app=celery";
const check_celery_durable = " dst.acks_late=1 dst.redis=durable";
const check_celery_pop_seeds = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 };
const check_celery_seed = 4;
const check_celery_seeds = [_]u64{ 31, 32, 33 };
const check_consumed: [choices_module.stream_count]u64 = .{ 3, 1, 0, 4, 0, 0, 0 };
const check_cmdline = check_cmdline_root ++ " init=/init";
const check_cores_max = 4;
const check_critical = " dst.critical_ms=200";
const check_critical_spin = " dst.critical_spin=" ++ check_critical_spins ++ " dst.lease_ms=1000";
const check_critical_spins = "11000000";
const check_counter_runs = 64;

const check_debug_command = "echo COUNT $(psql -U ledger -d ledger -tAc " ++
    "'select count(*) from ledger_transfer')";

const check_debug_ns = 3 * std.time.ns_per_s;
const check_debug_seed = 7;
const check_counter_solved = "the counter reached its last stage";
const check_counter_stages = 18;
const check_cmdline_crash = check_cmdline_root ++ " init=/crash";
const check_cmdline_app = check_cmdline_root ++ " init=/init loglevel=1";
const check_cmdline_root = "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw";
const check_cmdline_verify = check_cmdline_root ++ " init=/verify";
const check_conformance_draws = 64;
const check_conformance_acks = 8;
const check_conformance_path = "images/conformance.ext4";
const check_conformance_properties = 6;
const check_conformance_seed = 1;
const check_docker_crash_window_ns = 3 * std.time.ns_per_s;
const check_docker_eventually_ns = 20 * std.time.ns_per_s;
const check_docker_fault_window_ns = 2 * std.time.ns_per_s;
const check_docker_idle = "the client is idle after every request";
const check_docker_path = "images/docker-zig.ext4";
const check_docker_seeds = [_]u64{ 14, 32, 58, 59 };
const check_tigerstyle_cache = "a warm cache after a crash reports what a cold run reports";
const check_tigerstyle_path = "images/tigerstyle.ext4";
const check_tigerstyle_seeds = [_]u64{ 1, 2, 3, 4 };
const check_tigerstyle_window_ns = 15 * std.time.ns_per_s;
const check_disk_cache_sectors = 4096;
const check_draws_prefix = "DST DRAWS ";
const check_disk_path = "images/rootfs.ext4";
const check_draws_seed = 3;
const check_draws_total = 4000;
const check_events_seed = 5;
const check_fork_event = 2;
const check_fork_runs = 16;
const check_fork_seeds = 8;
const check_heartbeat_seed = 1;
const check_heartbeat_stalled = "the heartbeat stalled past its deadline";
const check_holder_jobs = 8;
const check_holder_points = 2;
const check_kind_seeds = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 };
const check_phase_ns = 10 * std.time.ns_per_s;
const check_phase_seeds = [_]u64{ 1, 2, 3 };
const check_phase_window_ns = 15 * std.time.ns_per_s;
const check_kernel_path = "images/vmlinux";
const check_lease_controls = [_]u64{ 4, 5 };
const check_lease_hold_ns_max = std.time.ns_per_s;
const check_lease_lost = "a transfer lost its account lease before it committed";
const check_likelihood_points = 8;
const check_likelihood_runs = 8;
const check_rate_slowest_runs = 2;
const check_replica_kept = "every acknowledged write survives a failover to the replica";
const check_replica_peer = 1 << 2;
const check_replica_seeds = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 };
const check_lease_seeds = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 };
const check_ledger_seeds = [_]u64{ 21, 22, 23, 24, 25, 26, 28, 27 };
const check_maze = " dst.app=maze dst.coverage=1";
const check_maze_runs = 96;
const check_maze_seeds = [_]u64{ 0, 1, 2, 3 };
const check_maze_solved = "the maze reached its last stage";
const check_ms = std.time.ns_per_ms;
const check_point_branches = 1_000;
const check_oom_kill = "DST KERNEL Out of memory: Killed process";
const check_run_duration_ns = 60 * std.time.ns_per_s;
const check_run_seed = 7;
const check_shrink_runs_max = 48;
const check_shrink_seed = 56;
const check_shrink_window_ns = 10 * std.time.ns_per_s;

const check_smp_branch_exits = [_]u64{
    24_000,
    28_000,
    31_500,
    32_000,
    33_000,
    36_000,
    38_000,
    40_000,
};

const check_spin_exit = 32_000;
const check_spin_step_margin = 512;
const check_sweep_first = 22_000;
const check_sweep_first_smp = 32_250;
const check_sweep_points = 15;
const check_sweep_step = 650;
const check_target_sectors = check_target_size / virtio_block.sector_size;
const check_target_size = 1 << 20;
const transfer_ids_check_max = 8192;
const check_tcp = " dst.pg=tcp";
const check_unit_sectors = 8;

const check_celery_protected = check_celery ++ check_tcp ++ " dst.redis=durable dst.acks_late=1" ++
    " dst.reject_lost=1 dst.task_retry=1";

const check_celery_plans = [_]Faults{
    .{ .script = &.{.{ .delay_ns = 529_321_336, .kind = .kill, .target = .redis_server }} },
    .{
        .script = &.{.{
            .delay_ns = 684_009_909,
            .duration_ns = 7_275_493_506,
            .kind = .network,
            .network_link = .postgres,
            .network_loss_permille = faults_module.permille,
        }},
    },
    .{
        .script = &.{.{
            .delay_ns = 102_919_820,
            .duration_ns = 1_507_972_322,
            .kind = .memory,
            .memory_immune = 1,
            .memory_kills = 2,
        }},
    },
};

const check_celery_pop_plan: Faults = .{
    .script = &.{.{
        .duration_ns = check_run_duration_ns,
        .kind = .network,
        .network_link = .redis,
        .network_loss_permille = 200,
    }},
};

const check_lease_jump_ns = 60 * std.time.ns_per_s;
const check_lease_timeout_ns = 5 * std.time.ns_per_s;

const check_spin_lease_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.locking=redis" ++ check_critical_spin,
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check dst.locking=redis" ++
        check_critical_spin,
    .disk = check_app_path,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_spin_rows_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_critical_spin,
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_critical_spin,
    .disk = check_app_path,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_smp_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.locking=0",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check",
    .cpus = 2,
    .disk = check_app_path,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_counter_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.app=counter dst.coverage=1",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check dst.app=counter dst.coverage=1",
    .disk = check_app_path,
    .jitter_ns_max = check_app_jitter_ns_max,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_debug_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.locking=0",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check",
    .crash_window_ns = check_app_crash_window_ns,
    .debug_ns = check_debug_ns,
    .disk = check_app_path,
    .jitter_ns_max = check_app_jitter_ns_max,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_nodes_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.locking=redis dst.topology=nodes",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check dst.locking=redis dst.topology=nodes",
    .disk = check_app_path,
    .jitter_ns_max = check_app_jitter_ns_max,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_replica_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.app=replica",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check dst.app=replica",
    .disk = check_app_path,
    .fault_plan = .{ .script = &check_replica_partition },
    .jitter_ns_max = check_app_jitter_ns_max,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_replica_partition = [_]Event{.{
    .kind = .network,
    .delay_ns = std.time.ns_per_s,
    .duration_ns = 30 * std.time.ns_per_s,
    .network_link = .redis,
    .network_loss_permille = faults_module.permille,
    .network_peers = check_replica_peer,
}};

const check_replica_pause = [_]Event{.{
    .kind = .pause,
    .delay_ns = std.time.ns_per_s,
    .duration_ns = 2 * std.time.ns_per_s,
    .target = .redis_server,
}};

const check_conformance_script = [_]Event{
    .{ .kind = .clock_jump, .delay_ns = 100 * check_ms, .clock_jump_ns = -5 * std.time.ns_per_s },
    .{
        .kind = .network,
        .delay_ns = 200 * check_ms,
        .duration_ns = 300 * check_ms,
        .network_delay_ns = 1000,
        .network_direction = .replies,
        .network_link = .redis,
        .network_loss_permille = 200,
    },
};

const check_conformance_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.coverage=1",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check",
    .disk = check_conformance_path,
    .fault_plan = .{ .script = &check_conformance_script },
    .kernel = check_kernel_path,
    .memory_mib = 512,
    .preemption = true,
};

const check_tigerstyle_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check",
    .crash_window_ns = check_tigerstyle_window_ns,
    .disk = check_tigerstyle_path,
    .fault_families = .{
        .clock = false,
        .cpu = false,
        .disk_full = false,
        .kill = false,
        .memory = false,
        .network = false,
        .pause = false,
        .thread_pause = false,
        .throttle = false,
    },
    .faults = true,
    .jitter_ns_max = check_app_jitter_ns_max,
    .kernel = check_kernel_path,
    .memory_mib = 512,
    .preemption = true,
};

const check_docker_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check",
    .crash_window_ns = check_docker_crash_window_ns,
    .disk = check_docker_path,
    .eventually_ns = check_docker_eventually_ns,
    .fault_families = .{ .disk_errors = false, .network = false },
    .fault_roster = .docker,
    .fault_window_ns = check_docker_fault_window_ns,
    .faults = true,
    .jitter_ns_max = check_app_jitter_ns_max,
    .kernel = check_kernel_path,
    .memory_mib = 1536,
    .preemption = true,
};

const check_draws_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.app=draws",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check dst.app=draws",
    .disk = check_app_path,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_events_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check",
    .disk = check_app_path,
    .fault_plan = .{ .weights = .{ .clock = 1, .kill = 1, .network = 1 } },
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_celery_protected_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_celery_protected,
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_celery_protected,
    .disk = check_app_path,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_celery_phase_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_celery,
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_celery,
    .disk = check_app_path,
    .eventually_ns = check_phase_ns,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_heartbeat_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.app=heartbeat",
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check dst.app=heartbeat",
    .disk = check_app_path,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_lease_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.locking=redis" ++ check_critical,
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check dst.locking=redis" ++ check_critical,
    .disk = check_app_path,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_maze_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_maze,
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_maze,
    .disk = check_app_path,
    .jitter_ns_max = check_app_jitter_ns_max,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_partition_phase_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_tcp,
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_tcp,
    .disk = check_app_path,
    .eventually_ns = check_phase_ns,
    .fault_window_ns = check_phase_window_ns,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_rows_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run" ++ check_critical,
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check" ++ check_critical,
    .disk = check_app_path,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_shrink_config: Config = .{
    .cmdline = check_cmdline_app ++ " dst.mode=run dst.locking=redis" ++ check_critical,
    .cmdline_reboot = check_cmdline_app ++ " dst.mode=check dst.locking=redis" ++ check_critical,
    .disk = check_app_path,
    .fault_families = .{
        .clock = true,
        .cpu = false,
        .disk_errors = false,
        .disk_full = false,
        .disk_latency = true,
        .kill = false,
        .memory = false,
        .network = false,
        .pause = false,
        .thread_pause = false,
        .throttle = false,
    },
    .fault_window_ns = check_shrink_window_ns,
    .faults = true,
    .kernel = check_kernel_path,
    .memory_mib = 1024,
    .preemption = true,
};

const check_heartbeat_long_plan: Faults = .{
    .script = &.{.{
        .delay_ns = 1000 * check_ms,
        .duration_ns = 800 * check_ms,
        .kind = .thread_pause,
        .target = .workload,
        .thread_choice = 1,
    }},
};

const check_heartbeat_short_plan: Faults = .{
    .script = &.{.{
        .delay_ns = 1000 * check_ms,
        .duration_ns = 200 * check_ms,
        .kind = .thread_pause,
        .target = .workload,
        .thread_choice = 1,
    }},
};

const check_lease_plan: Faults = .{
    .script = &.{.{
        .clock_jump_ns = check_lease_jump_ns,
        .delay_ns = 300 * check_ms,
        .kind = .clock_jump,
    }},
};

const check_long_partition_plan: Faults = .{
    .script = &.{.{
        .delay_ns = 500 * check_ms,
        .duration_ns = check_run_duration_ns,
        .kind = .network,
        .network_link = .postgres,
        .network_loss_permille = faults_module.permille,
    }},
};

const check_pause_plan: Faults = .{
    .script = &.{.{
        .delay_ns = 500 * check_ms,
        .duration_ns = 7000 * check_ms,
        .kind = .pause,
        .target = .gunicorn_worker,
    }},
};

const check_rate_slowest_plan: Faults = .{ .branch_ps = 4 * faults_module.branch_ps_default };

const check_direction_plan: Faults = .{
    .script = &.{
        .{
            .delay_ns = 200 * check_ms,
            .duration_ns = 500 * check_ms,
            .kind = .network,
            .network_direction = .requests,
            .network_link = .redis,
            .network_loss_permille = 300,
        },
        .{
            .delay_ns = 1000 * check_ms,
            .duration_ns = 500 * check_ms,
            .kind = .network,
            .network_direction = .replies,
            .network_link = .redis,
            .network_loss_permille = 300,
        },
    },
};

const check_reply_loss_plan: Faults = .{
    .script = &.{.{
        .duration_ns = check_run_duration_ns,
        .kind = .network,
        .network_direction = .replies,
        .network_link = .redis,
        .network_loss_permille = 200,
    }},
};

const check_request_loss_plan: Faults = .{
    .script = &.{.{
        .duration_ns = check_run_duration_ns,
        .kind = .network,
        .network_direction = .requests,
        .network_link = .redis,
        .network_loss_permille = 200,
    }},
};

const check_running_kill_plan: Faults = .{
    .script = &.{.{ .delay_ns = 5000 * check_ms, .kind = .kill, .target = .celery_worker }},
};

const check_startup_kill_plan: Faults = .{
    .script = &.{.{ .delay_ns = 300 * check_ms, .kind = .kill, .target = .celery_worker }},
};

const check_throttle_plan: Faults = .{
    .script = &.{.{
        .delay_ns = 200 * check_ms,
        .duration_ns = 8000 * check_ms,
        .kind = .throttle,
        .target = .gunicorn_worker,
        .throttle_permille = 10,
    }},
};

const check_ledger_network = [_]Event{
    .{
        .duration_ns = check_run_duration_ns,
        .kind = .network,
        .network_delay_ns = 2 * check_ms,
        .network_jitter_ns = check_ms,
        .network_link = .postgres,
        .network_reorder_permille = 100,
    },
    .{
        .delay_ns = 200 * check_ms,
        .duration_ns = 1000 * check_ms,
        .kind = .network,
        .network_link = .postgres,
        .network_loss_permille = faults_module.permille,
    },
};

const check_ledger_plans = [_]Faults{
    .{ .script = &.{.{ .delay_ns = 300 * check_ms, .kind = .kill, .target = .postgres_backend }} },
    .{
        .script = &.{.{
            .delay_ns = 200 * check_ms,
            .kind = .kill,
            .restart = 1,
            .restart_delay_ns = 300 * check_ms,
            .target = .postmaster,
        }},
    },
    .{
        .script = &.{.{
            .choice = 1,
            .delay_ns = 200 * check_ms,
            .kind = .kill,
            .target = .gunicorn_worker,
        }},
    },
    .{
        .disk = .{
            .error_delay_ns = 100 * check_ms,
            .error_duration_ns = 1000 * check_ms,
            .error_read_permille = 100,
            .error_write_permille = 200,
        },
    },
    .{ .script = &.{.{ .delay_ns = 100 * check_ms, .kind = .disk_full }} },
    .{
        .script = &.{.{
            .duration_ns = 500 * check_ms,
            .kind = .memory,
            .memory_immune = 1,
            .memory_kills = 2,
        }},
    },
    check_lease_plan,
    .{ .script = &check_ledger_network },
};

const CheckDrops = struct {
    replies: u64,
    requests: u64,
};

const CheckOptions = struct {
    branch_exits: []const u64 = &.{},
    cmdline: []const u8 = check_cmdline,
    cmdline_reboot: []const u8 = check_cmdline,
    cpus: u8 = 1,
    crash_exit: ?u64 = null,
    disk_output: []const u8 = "",
    faults: Faults = .{},
    preemption: bool = false,
    step_margin: u64 = pmu_module.skid_margin,
};

const CheckRun = struct {
    branches: [check_branches_max]Branch,
    outcome: Outcome,
    transcript: Io.Writer.Allocating,
};

const CheckScenario = struct {
    catalog: ?*Catalog = null,
    plans: []const Faults,
    replay_all: bool = true,
    replays: []Attempt,
    results: []Attempt,
    seeds: []const u64,
};

const CheckSectors = struct {
    mixed: u64,
    new: u64,
    old: u64,
    size: u64,
};

fn check_batch(
    gpa: std.mem.Allocator,
    kernel: []const u8,
    config: *const Config,
    batch: *const Batch,
) !void {
    assert(kernel.len > 0);
    assert(config.preemption);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var stop: std.atomic.Value(bool) = .init(false);

    const plan: Plan = .{
        .cmdline = try check_cmdline_build(arena, config, config.cmdline),
        .cmdline_reboot = try check_cmdline_build(arena, config, config.cmdline_reboot),
        .config = config,
        .initrd = "",
        .kernel = kernel,
        .stop = &stop,
    };

    try runner_batch(std.testing.io, gpa, &plan, batch);
}

fn check_celery_evidence(gpa: std.mem.Allocator, directory: *const std.testing.TmpDir) !void {
    const killed = try check_transcript(gpa, directory, check_celery_seeds[0]);
    defer gpa.free(killed);

    const partitioned = try check_transcript(gpa, directory, check_celery_seeds[1]);
    defer gpa.free(partitioned);

    const starved = try check_transcript(gpa, directory, check_celery_seeds[2]);
    defer gpa.free(starved);

    try check_contains(killed, "DST FAULT kill redis_server pid ");
    try check_contains(partitioned, "DST FAULT network partition start");
    try check_contains(starved, "DST KERNEL Out of memory: Killed process");
}

fn check_cmdline_build(
    arena: std.mem.Allocator,
    config: *const Config,
    configured: []const u8,
) ![]const u8 {
    assert(config.preemption);
    assert(configured.len > 0);

    return cmdline_build(arena, configured, true, config.cpus, config.eventually_ns);
}

fn check_conformance(language: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const kernel = Io.Dir.cwd().readFileAlloc(io, check_kernel_path, gpa, .unlimited) catch {
        return error.SkipZigTest;
    };

    defer gpa.free(kernel);

    Io.Dir.cwd().access(io, check_conformance_path, .{}) catch return error.SkipZigTest;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const seeds = [_]u64{check_conformance_seed};
    var path_buffer: [path_max]u8 = undefined;
    var cmdline_buffer: [256]u8 = undefined;
    var reboot_buffer: [256]u8 = undefined;
    var config = check_conformance_config;
    var catalog: Catalog = .{};
    var cores: pmu_module.Cores = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});
    const run_format = "{s} dst.app={s}";

    config.cmdline = try std.mem.print(&cmdline_buffer, run_format, .{ config.cmdline, language });

    config.cmdline_reboot = try std.mem.print(&reboot_buffer, run_format, .{
        config.cmdline_reboot,
        language,
    });

    config.transcript_output = try check_output(&path_buffer, &directory);

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .catalog = &catalog,
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    const transcript = try check_transcript(gpa, &directory, check_conformance_seed);
    defer gpa.free(transcript);

    try check_conformance_judge(transcript, &results[0], &catalog);
}

fn check_conformance_judge(
    transcript: []const u8,
    result: *const Attempt,
    catalog: *const Catalog,
) !void {
    const workload = @backingInt(StreamName.workload);
    var drawn: [check_conformance_draws]u64 = undefined;
    var expected: [check_conformance_draws]u64 = undefined;
    var stream: Stream = .init(stream_seeds(check_conformance_seed)[workload]);
    const count = try check_draws_parse(transcript, &drawn);
    const largest = std.mem.max(u64, &drawn);

    for (&expected) |*word| word.* = stream.word();

    std.mem.sortUnstable(u64, &drawn, {}, std.sort.asc(u64));
    std.mem.sortUnstable(u64, &expected, {}, std.sort.asc(u64));

    try check_contains(transcript, "DST SEED 1\r\n");
    try check_passed(result);
    try std.testing.expectEqual(check_conformance_draws, count);
    try std.testing.expectEqual(check_conformance_draws, result.consumed[workload]);
    try std.testing.expectEqualSlices(u64, &expected, &drawn);
    try std.testing.expectEqual(check_conformance_acks, result.verdict.acknowledged);
    try std.testing.expectEqual(check_conformance_acks, result.verdict.present);
    try std.testing.expectEqual(0, result.verdict.lost);
    try std.testing.expectEqual(check_conformance_script.len, result.verdict.event_echoes);
    try std.testing.expectEqual(check_conformance_properties, catalog.count);
    try std.testing.expectEqual(1, result.guidance_count);
    try std.testing.expectEqual(largest, result.guidance[0].value);

    if (result.coverage_fresh_count == 0) return error.CoverageMissing;
}

fn check_contains(transcript: []const u8, needle: []const u8) !void {
    assert(needle.len > 0);

    if (std.mem.find(u8, transcript, needle) != null) return;

    std.debug.print("the transcript lacks '{s}'\n", .{needle});

    return error.EvidenceMissing;
}

fn check_cores(cores: *pmu_module.Cores) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try pmu_module.cores_find(std.testing.io, arena_state.allocator(), cores);

    cores.count = @min(cores.count, check_cores_max);

    assert(cores.count > 0);
    assert(cores.count <= check_cores_max);
}

fn check_count(transcript: []const u8, needle: []const u8) usize {
    assert(needle.len > 0);

    return std.mem.count(u8, transcript, needle);
}

fn check_cpus_online(transcript: []const u8, cpus: u8) !void {
    var line_buffer: [64]u8 = undefined;
    const plural = if (cpus == 1) "" else "s";
    const format = "smp: Brought up 1 node, {d} CPU{s}";
    const line = try std.mem.print(&line_buffer, format, .{ cpus, plural });

    assert(cpus > 0);
    assert(cpus <= machine_module.cpus_max);

    try check_contains(transcript, line);
}

fn check_cpus_ran(outcome: *const Outcome, cpus: u8) !void {
    assert(cpus > 0);
    assert(cpus <= machine_module.cpus_max);

    for (outcome.cpu_branches, outcome.cpu_exits, 0..) |branches, exits, index| {
        try std.testing.expectEqual(index < cpus, branches > 0);
        try std.testing.expectEqual(index < cpus, exits > 0);
    }
}

fn check_debug_count(output: []const u8) !u64 {
    const marker = "COUNT ";

    const start = (std.mem.find(u8, output, marker) orelse {
        std.debug.print("the debug output lacks '{s}': {s}\n", .{ marker, output });

        return error.EvidenceMissing;
    }) + marker.len;

    const digits = std.mem.sliceTo(output[start..], '\r');
    const count = std.mem.trimEnd(u8, digits, "\n");

    return std.fmt.parseInt(u64, count, 10);
}

fn check_draws_parse(transcript: []const u8, words: []u64) !usize {
    var lines = std.mem.splitScalar(u8, transcript, '\n');
    var count: usize = 0;

    assert(words.len > 0);

    for (0..transcript.len + 2) |_| {
        const raw = lines.next() orelse break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, check_draws_prefix)) continue;

        var tokens = std.mem.tokenizeScalar(u8, line[check_draws_prefix.len..], ' ');

        _ = tokens.next();

        for (0..line.len + 2) |_| {
            const token = tokens.next() orelse break;

            if (count == words.len) return error.DrawsOverflow;

            words[count] = try std.fmt.parseInt(u64, token, 16);
            count += 1;
        } else unreachable;
    } else unreachable;

    assert(count <= words.len);

    return count;
}

fn check_drops(transcript: []const u8, prefix: []const u8) !CheckDrops {
    assert(prefix.len > 0);

    const found = std.mem.find(u8, transcript, prefix) orelse {
        std.debug.print("the transcript lacks '{s}'\n", .{prefix});

        return error.EvidenceMissing;
    };

    const line = std.mem.sliceTo(transcript[found..], '\n');
    const dropped = std.mem.find(u8, line, " dropped ") orelse return error.EvidenceMissing;
    const counts = line[dropped..];

    return .{
        .replies = try check_number(counts, " replies "),
        .requests = try check_number(counts, " requests "),
    };
}

fn check_events_same(attempt: *const Attempt, other: *const Attempt) bool {
    const events = std.mem.sliceAsBytes(attempt.events[0..attempt.events_count]);
    const others = std.mem.sliceAsBytes(other.events[0..other.events_count]);

    assert(attempt.events_count <= faults_module.events_max);
    assert(other.events_count <= faults_module.events_max);

    return std.mem.eql(u8, events, others);
}

fn check_explore(
    gpa: std.mem.Allocator,
    kernel: []const u8,
    arena: std.mem.Allocator,
    base: *const Config,
    uniform: bool,
    runs: u32,
    holders_max: u32,
) !*Explore {
    var config = base.*;
    var cores: pmu_module.Cores = .{};
    var results: [check_maze_seeds.len]Attempt = @splat(.{});
    var replays: [check_maze_seeds.len]Attempt = @splat(.{});

    assert(runs >= check_maze_seeds.len);

    config.explore_runs = runs;
    config.explore_uniform = uniform;

    const explore = try runner_explore_init(arena, arena, &config, check_maze_seeds.len);

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = cores.count,
        .cores = cores.slice(),
        .explore = explore,
        .holders_max = holders_max,
        .replays = &replays,
        .results = &results,
        .seeds = &check_maze_seeds,
    });

    assert(explore.runs == runs);

    return explore;
}

fn check_explore_picks(explore: *Explore, early: *const ForkPoint) !void {
    var newest_favored: u32 = 0;
    var newest_spent: u32 = 0;
    var other_spent: u32 = 0;
    var late_picks: u32 = 0;

    assert(explore.corpus_count == 2);
    assert(explore.corpus[1].picks == 0);

    for (0..400) |_| {
        const favored = explore.corpus[1].picks < explore_newest_picks_max;
        const plan = explore_pick(explore);
        const entry = plan.entry orelse return error.TestUnexpectedResult;
        const exits = plan.fork_point.exits;

        if (entry == &explore.corpus[1]) {
            try std.testing.expect(exits == 300 or exits == 700);

            newest_favored += @intFromBool(favored);
            newest_spent += @intFromBool(!favored);
            late_picks += @intFromBool(exits == 700);
        } else {
            try std.testing.expectEqual(early.*, plan.fork_point);

            other_spent += @intFromBool(!favored);
        }
    }

    const newest = newest_favored + newest_spent;
    const spent = newest_spent + other_spent;

    try std.testing.expectEqual(explore_newest_picks_max, newest_favored);
    try std.testing.expectEqual(newest, explore.corpus[1].picks);
    try std.testing.expect(spent > 360);
    try std.testing.expect(newest_spent * 8 > spent * 3);
    try std.testing.expect(newest_spent * 8 < spent * 5);
    try std.testing.expect(late_picks > newest * 3 / 8);
    try std.testing.expect(late_picks < newest * 5 / 8);
}

fn check_faults(
    gpa: std.mem.Allocator,
    kernel: []const u8,
    config: *const Config,
    scenario: *const CheckScenario,
) !void {
    assert(scenario.plans.len == scenario.seeds.len);
    assert(scenario.results.len == scenario.seeds.len);
    assert(scenario.replays.len == scenario.seeds.len);

    var cores: pmu_module.Cores = .{};

    try check_cores(&cores);

    try check_batch(gpa, kernel, config, &.{
        .catalog = scenario.catalog,
        .concurrency = @min(cores.count, scenario.seeds.len),
        .cores = cores.slice(),
        .plans = scenario.plans,
        .replay_all = scenario.replay_all,
        .replays = scenario.replays,
        .results = scenario.results,
        .seeds = scenario.seeds,
    });

    for (scenario.results, scenario.replays, scenario.seeds) |*result, *replay, seed| {
        const replayed = scenario.replay_all or !result.passed();
        const diverged = replayed and !result.same(replay);

        if (result.failure == null) {
            if (!diverged) continue;
        }

        std.debug.print("seed {d}: failure {?} replay {?}, fingerprint {x} {x} {x} replayed " ++
            "as {x} {x} {x}\n", .{
            seed,
            result.failure,
            replay.failure,
            result.outcome.memory_hash,
            result.outcome.disk_hash,
            result.outcome.serial_hash,
            replay.outcome.memory_hash,
            replay.outcome.disk_hash,
            replay.outcome.serial_hash,
        });

        return result.failure orelse error.ReplayDiverged;
    }
}

fn check_fork_splice(
    gpa: std.mem.Allocator,
    kernel: []const u8,
    arena: std.mem.Allocator,
    parent: *const Attempt,
    parent_choices: *const Choices,
    forked: *const Attempt,
) !void {
    const entry: Entry = .{ .choices = parent_choices.*, .fork_points = &.{} };
    const seeds = [_]u64{check_events_seed};
    var spliced: [1]Choices = @splat(.{});
    var cores: pmu_module.Cores = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});

    const plan: ExploreJob = .{
        .entry = &entry,
        .fork_point = parent.event_points[check_fork_event - 1],
        .fork_seed = 1,
        .seed = check_events_seed,
    };

    try explore_record(arena, &plan, forked, &spliced[0]);
    try check_cores(&cores);

    try check_batch(gpa, kernel, &check_events_config, &.{
        .choices = &spliced,
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    try std.testing.expect(results[0].same(forked));
    try std.testing.expect(check_events_same(&results[0], forked));
}

fn check_forks(
    gpa: std.mem.Allocator,
    kernel: []const u8,
    parent: *const Attempt,
    parent_choices: *const Choices,
    forked: *[check_fork_seeds]Attempt,
) !void {
    const choices: [check_fork_seeds]Choices = @splat(parent_choices.*);
    const points: [check_fork_seeds]ForkPoint = @splat(parent.event_points[check_fork_event - 1]);
    const seeds: [check_fork_seeds]u64 = @splat(check_events_seed);
    const kept = std.mem.sliceAsBytes(parent.events[0..check_fork_event]);
    var fork_seeds: [check_fork_seeds]u64 = undefined;
    var replays: [check_fork_seeds]Attempt = @splat(.{});
    var cores: pmu_module.Cores = .{};
    var distinct: u32 = 0;

    for (&fork_seeds, 1..) |*fork_seed, index| fork_seed.* = index;

    @memset(forked, .{});
    try check_cores(&cores);

    try check_batch(gpa, kernel, &check_events_config, &.{
        .choices = &choices,
        .concurrency = cores.count,
        .cores = cores.slice(),
        .fork_points = &points,
        .fork_seeds = &fork_seeds,
        .replays = &replays,
        .results = forked,
        .seeds = &seeds,
    });

    for (forked) |*attempt| {
        const events = std.mem.sliceAsBytes(attempt.events[0..check_fork_event]);

        try std.testing.expectEqual(null, attempt.failure);
        try std.testing.expect(attempt.events_count >= check_fork_event);
        try std.testing.expect(std.mem.eql(u8, kept, events));
        try std.testing.expect(attempt.fork_positions[@backingInt(StreamName.events)] != null);
        try std.testing.expect(attempt.fork_positions[@backingInt(StreamName.workload)] != null);

        distinct += @intFromBool(!check_events_same(attempt, &forked[0]));
    }

    try std.testing.expect(distinct > 0);
}

fn check_found_replay(gpa: std.mem.Allocator, kernel: []const u8, found: *const Found) !void {
    const choices = [_]Choices{found.choices};
    const seeds = [_]u64{found.choices.seed};
    var cores: pmu_module.Cores = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});

    try check_cores(&cores);

    try check_batch(gpa, kernel, &check_maze_config, &.{
        .choices = &choices,
        .concurrency = 1,
        .cores = cores.slice(),
        .replay_all = true,
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    try std.testing.expect(results[0].same(&found.attempt));
    try std.testing.expect(replays[0].same(&found.attempt));
    try std.testing.expectEqual(attempt_signature(&found.attempt), attempt_signature(&results[0]));
}

fn check_holder_batch(
    gpa: std.mem.Allocator,
    kernel: []const u8,
    parent: *const Attempt,
    parent_choices: *const Choices,
    results: *[check_holder_jobs]Attempt,
    stats: ?*HolderStats,
) !void {
    const choices: [check_holder_jobs]Choices = @splat(parent_choices.*);
    const seeds: [check_holder_jobs]u64 = @splat(check_events_seed);
    const seeds_per_point = check_holder_jobs / check_holder_points;
    var fork_points: [check_holder_jobs]ForkPoint = undefined;
    var fork_seeds: [check_holder_jobs]u64 = undefined;
    var replays: [check_holder_jobs]Attempt = @splat(.{});
    var cores: pmu_module.Cores = .{};

    assert(parent.events_count >= check_holder_points);

    for (&fork_points, &fork_seeds, 0..) |*point, *fork_seed, index| {
        point.* = parent.event_points[index / seeds_per_point];
        fork_seed.* = index % seeds_per_point + 1;
    }

    @memset(results, .{});
    try check_cores(&cores);

    try check_batch(gpa, kernel, &check_events_config, &.{
        .choices = &choices,
        .concurrency = 1,
        .cores = cores.slice(),
        .fork_points = &fork_points,
        .fork_seeds = &fork_seeds,
        .holder_stats = stats,
        .holders_max = if (stats != null) check_holder_points else 0,
        .replays = &replays,
        .results = results,
        .seeds = &seeds,
    });
}

fn check_kind_lost(results: []const Attempt) u32 {
    var lost: u32 = 0;

    assert(results.len == check_kind_seeds.len);

    for (results) |*result| lost += result.verdict.lost;

    assert(lost <= check_kind_seeds.len * transfer_ids_check_max);

    return lost;
}

fn check_kind_runs(
    gpa: std.mem.Allocator,
    kernel: []const u8,
    config: *const Config,
    plan: *const Faults,
    results: []Attempt,
) !u32 {
    const plans: [check_kind_seeds.len]Faults = @splat(plan.*);
    var replays: [check_kind_seeds.len]Attempt = @splat(.{});
    var broken: u32 = 0;

    assert(plan.valid());
    assert(results.len <= check_kind_seeds.len);

    @memset(results, .{});

    try check_faults(gpa, kernel, config, &.{
        .plans = plans[0..results.len],
        .replay_all = false,
        .replays = replays[0..results.len],
        .results = results,
        .seeds = check_kind_seeds[0..results.len],
    });

    for (results) |*result| broken += @intFromBool(!result.passed());

    assert(broken <= results.len);

    return broken;
}

fn check_lease_shrink(
    gpa: std.mem.Allocator,
    kernel: []const u8,
    arena: std.mem.Allocator,
    results: *[1]Attempt,
    replays: *[1]Attempt,
    shrunk: *[1]Shrunk,
) !void {
    const seeds = [_]u64{check_shrink_seed};
    const candidates = try arena.create([shrink_parallel_max]Choices);
    var cores: pmu_module.Cores = .{};

    try check_cores(&cores);
    try shrink_candidates_init(arena, candidates);

    try check_batch(gpa, kernel, &check_shrink_config, &.{
        .candidates = candidates,
        .concurrency = cores.count,
        .cores = cores.slice(),
        .pool = arena,
        .replays = replays,
        .results = results,
        .seeds = &seeds,
        .shrink_runs_max = check_shrink_runs_max,
        .shrunk = shrunk,
    });

    assert(results[0].outcome.exits > 0);
    assert(shrunk[0].runs <= check_shrink_runs_max);
}

fn check_ledger_catalog(catalog: *const Catalog, results: []const Attempt) !void {
    assert(results.len > 0);

    const always = [_][]const u8{
        "every balance equals its opening balance plus the transfers that touched it",
        "the money in all accounts is conserved",
        "no account balance is negative",
    };

    const rejected = "a transfer is rejected for insufficient funds";
    const repeated = "a repeated transfer request is recognised as a duplicate";
    const leased = "a transfer lost its account lease before it committed";

    try std.testing.expectEqual(@as(u32, 6), catalog.count);
    try std.testing.expect(catalog.find(.sometimes, rejected) != null);
    try std.testing.expect(catalog.find(.reachable, repeated) != null);
    try std.testing.expect(catalog.find(.@"unreachable", leased) != null);

    for (always) |message| {
        const index = catalog.find(.always, message) orelse return error.PropertyMissing;

        for (results) |*result| {
            try std.testing.expect(!catalog.unreached(&result.verdict.hits, index));
        }
    }
}

fn check_ledger_evidence(
    gpa: std.mem.Allocator,
    directory: *const std.testing.TmpDir,
    results: []const Attempt,
) !void {
    var transcripts: [check_ledger_seeds.len][]u8 = undefined;
    var loaded: usize = 0;
    defer for (transcripts[0..loaded]) |transcript| gpa.free(transcript);

    for (&transcripts, check_ledger_seeds) |*transcript, seed| {
        transcript.* = try check_transcript(gpa, directory, seed);
        loaded += 1;
    }

    var line_buffer: [detail_max]u8 = undefined;
    const backend = try check_pid(transcripts[0], "DST FAULT kill postgres_backend pid ");
    const worker = try check_pid(transcripts[2], "DST FAULT kill gunicorn_worker pid ");
    const recovery = "database system is ready to accept connections";
    const restart = std.mem.find(u8, transcripts[1], "DST FAULT restart postmaster") orelse 0;
    const done = std.mem.find(u8, transcripts[1], "DST WORKLOAD DONE") orelse 0;

    try check_contains(transcripts[0], try std.fmt.bufPrint(&line_buffer, "server process " ++
        "(PID {s}) was terminated by signal 9", .{backend}));

    try check_contains(transcripts[1], "DST FAULT kill postmaster pid ");
    try check_contains(transcripts[1][restart..done], recovery);

    try check_contains(transcripts[2], try std.fmt.bufPrint(&line_buffer, "Worker " ++
        "(pid:{s}) was sent SIGKILL!", .{worker}));

    try check_contains(transcripts[3], "DST KERNEL I/O error");
    try check_contains(transcripts[4], "DST FAULT disk full filled");
    try check_contains(transcripts[4], "No space left on device");
    try check_contains(transcripts[6], "DST FAULT clock jump 60000000000 ns");
    try check_contains(transcripts[7], "DST FAULT network partition end");

    try std.testing.expect(restart > 0);
    try std.testing.expect(done > restart);
    try std.testing.expect(results[3].outcome.disk_errors > 0);
    try std.testing.expect(check_count(transcripts[5], check_oom_kill) >= 2);
}

fn check_likelihood(
    gpa: std.mem.Allocator,
    kernel: []const u8,
    arena: std.mem.Allocator,
    choices: *const Choices,
) !*Likelihood {
    const reproduced = [_]Choices{choices.*};
    const seeds = [_]u64{choices.seed};
    var config = check_shrink_config;
    var cores: pmu_module.Cores = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});

    config.likelihood_points = check_likelihood_points;
    config.likelihood_runs = check_likelihood_runs;

    const likelihood = try runner_likelihood_init(arena, &config);

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .choices = &reproduced,
        .concurrency = cores.count,
        .cores = cores.slice(),
        .holders_max = snapshot_holders_max_default,
        .likelihood = likelihood,
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    try std.testing.expect(!results[0].passed());
    try std.testing.expectEqual(check_likelihood_points, likelihood.probe.probe.count);

    return likelihood;
}

fn check_number(transcript: []const u8, prefix: []const u8) !u64 {
    assert(prefix.len > 0);

    const found = std.mem.find(u8, transcript, prefix) orelse {
        std.debug.print("the transcript lacks '{s}'\n", .{prefix});

        return error.EvidenceMissing;
    };

    const rest = transcript[found + prefix.len ..];
    const digits = rest[0 .. std.mem.findNone(u8, rest, "0123456789") orelse rest.len];

    return std.fmt.parseInt(u64, digits, 10);
}

fn check_output(buffer: *[path_max]u8, directory: *const std.testing.TmpDir) ![]const u8 {
    assert(directory.sub_path.len > 0);

    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/transcript", .{&directory.sub_path});
}

fn check_passed(attempt: *const Attempt) !void {
    if (attempt.passed()) return;

    std.debug.print("the attempt failed with {?} and the verdict said: {s}\n", .{
        attempt.failure,
        attempt.verdict.detail,
    });

    return error.AttemptFailed;
}

fn check_pid(transcript: []const u8, prefix: []const u8) ![]const u8 {
    assert(prefix.len > 0);

    const found = std.mem.find(u8, transcript, prefix) orelse {
        std.debug.print("the transcript lacks '{s}'\n", .{prefix});

        return error.EvidenceMissing;
    };

    const start = found + prefix.len;
    const end = std.mem.findNonePos(u8, transcript, start, "0123456789") orelse transcript.len;
    if (end == start) return error.EvidenceMissing;
    return transcript[start..end];
}

fn check_point(exits: u64) ForkPoint {
    var point: ForkPoint = .{ .branches = exits * check_point_branches, .exits = exits };

    point.cpu_branches[0] = point.branches;

    assert(point.exits == exits);
    assert(point.cpu_branches[1] == 0);

    return point;
}

fn check_record(
    arena: std.mem.Allocator,
    seed: u64,
    attempt: *const Attempt,
    choices: *Choices,
) !void {
    var capacities: [choices_module.stream_count]u32 = undefined;

    for (attempt.consumed, &capacities) |consumed, *capacity| capacity.* = @intCast(consumed);

    try choices.init_capacity(arena, &capacities);
    choices.record(&stream_seeds(seed), &capacities);
    choices.guest_seed = seed;
    choices.seed = seed;

    assert(choices.seed == seed);
    assert(std.mem.eql(u32, &choices.counts, &capacities));
}

fn check_run(gpa: std.mem.Allocator, kernel: []const u8, options: CheckOptions) !CheckRun {
    assert(options.branch_exits.len <= check_branches_max);
    assert(options.cpus == 1 or options.preemption);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var stop: std.atomic.Value(bool) = .init(false);
    var run: CheckRun = .{ .branches = undefined, .outcome = undefined, .transcript = .init(gpa) };
    errdefer run.transcript.deinit();

    const session: Session = .{
        .branch_exits = options.branch_exits,
        .cmdline = try cmdline_build(arena, options.cmdline, true, options.cpus, 0),
        .cmdline_reboot = try cmdline_build(arena, options.cmdline_reboot, true, options.cpus, 0),
        .cpus = options.cpus,
        .crash_delay_ns = null,
        .crash_exit = options.crash_exit,
        .debug = null,
        .disk = check_disk_path,
        .disk_cache_sectors = check_disk_cache_sectors,
        .disk_output = options.disk_output,
        .fault_window_ns = fault_window_ns_default,
        .faults = options.faults,
        .fork_point = null,
        .fork_seed = 0,
        .guest_seed = check_run_seed,
        .initrd = "",
        .jitter_ns_max = 0,
        .kernel = kernel,
        .memory_size = 256 << 20,
        .preemption = options.preemption,
        .probe = null,
        .seed = check_run_seed,
        .serial_output = &run.transcript.writer,
        .stdin_thread = false,
        .step_margin = options.step_margin,
        .stop = &stop,
        .time_limit_ns = time_limit_ns_default,
        .transcript_output = "",
        .watchdog_ns = watchdog_ns_default,
    };

    const branches = run.branches[0..options.branch_exits.len];
    run.outcome = try session_run(std.testing.io, arena, &session, branches);

    return run;
}

fn check_runner(gpa: std.mem.Allocator, kernel: []const u8, config: *const Config) !void {
    assert(kernel.len > 0);
    assert(config.runner);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var stop: std.atomic.Value(bool) = .init(false);

    const plan: Plan = .{
        .cmdline = try check_cmdline_build(arena, config, config.cmdline),
        .cmdline_reboot = try check_cmdline_build(arena, config, config.cmdline_reboot),
        .config = config,
        .initrd = "",
        .kernel = kernel,
        .stop = &stop,
    };

    try runner_run(std.testing.io, gpa, &plan);
}

fn check_sectors(transcript: []const u8) !CheckSectors {
    const marker = "VERIFY size=";
    const start = std.mem.find(u8, transcript, marker) orelse return error.VerifyMissing;
    const line_end = std.mem.findScalarPos(u8, transcript, start, '\n') orelse transcript.len;
    const line = std.mem.trimEnd(u8, transcript[start + "VERIFY ".len .. line_end], "\r");

    var sectors: CheckSectors = .{ .mixed = 0, .new = 0, .old = 0, .size = 0 };
    var fields = std.mem.tokenizeScalar(u8, line, ' ');

    for (0..line.len + 2) |_| {
        const field = fields.next() orelse break;
        const equals = std.mem.findScalar(u8, field, '=') orelse return error.VerifyMalformed;
        const value = try std.fmt.parseInt(u64, field[equals + 1 ..], 10);
        const key = field[0..equals];

        if (std.mem.eql(u8, key, "size")) sectors.size = value;
        if (std.mem.eql(u8, key, "a")) sectors.old = value;
        if (std.mem.eql(u8, key, "b")) sectors.new = value;
        if (std.mem.eql(u8, key, "mixed")) sectors.mixed = value;
    } else unreachable;

    if (std.mem.find(u8, transcript, "STILL RUNNING") != null) return error.CrashMissed;
    if (std.mem.find(u8, transcript, "VERIFY EXT4 ERRORS") != null) return error.Ext4Errors;
    return sectors;
}

fn check_shrunk_replay(
    gpa: std.mem.Allocator,
    kernel: []const u8,
    arena: std.mem.Allocator,
    minimal: *const Shrunk,
) !void {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    var path_buffer: [path_max]u8 = undefined;
    var loaded: [1]Choices = @splat(.{});
    var cores: pmu_module.Cores = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});

    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/reproducer.zon", .{
        &directory.sub_path,
    });

    try reproducer_save(std.testing.io, path, &minimal.choices);
    try reproducer_load(std.testing.io, gpa, arena, path, &loaded[0]);

    try std.testing.expect(!loaded[0].smaller(&minimal.choices));
    try std.testing.expect(!minimal.choices.smaller(&loaded[0]));

    const seeds = [_]u64{loaded[0].seed};

    try check_cores(&cores);

    try check_batch(gpa, kernel, &check_shrink_config, &.{
        .choices = &loaded,
        .concurrency = 1,
        .cores = cores.slice(),
        .replay_all = true,
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    try std.testing.expect(results[0].same(&minimal.attempt));
    try std.testing.expect(replays[0].same(&minimal.attempt));

    var config = check_shrink_config;

    config.cores_max = check_cores_max;
    config.reproducer = path;
    config.runner = true;

    try std.testing.expectError(error.ViolationsFound, check_runner(gpa, kernel, &config));
}

fn check_smp_boot(gpa: std.mem.Allocator, kernel: []const u8, cpus: u8) !void {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    var path_buffer: [path_max]u8 = undefined;
    var line_buffer: [32]u8 = undefined;
    var config = check_smp_config;
    var cores: pmu_module.Cores = .{};
    var results: [1]Attempt = @splat(.{});
    var replays: [1]Attempt = @splat(.{});
    const seeds = [_]u64{check_app_seed};

    config.cmdline = check_cmdline_app ++ " dst.mode=run";
    config.cmdline_reboot = check_cmdline_app ++ " dst.mode=check";
    config.cpus = cpus;
    config.transcript_output = try check_output(&path_buffer, &directory);

    try check_cores(&cores);

    try check_batch(gpa, kernel, &config, &.{
        .concurrency = 1,
        .cores = cores.slice(),
        .replays = &replays,
        .results = &results,
        .seeds = &seeds,
    });

    const transcript = try check_transcript(gpa, &directory, check_app_seed);
    defer gpa.free(transcript);

    const line = try std.mem.print(&line_buffer, "DST CPUS {d}", .{cpus});

    try check_contains(transcript, line);
    try std.testing.expect(results[0].passed());
    try check_cpus_ran(&results[0].outcome, cpus);
}

fn check_spin(gpa: std.mem.Allocator, kernel: []const u8, cpus: u8) !void {
    const cmdline = check_cmdline ++ " spin";
    const branch_exits = [_]u64{check_spin_exit};

    var first = try check_run(gpa, kernel, .{
        .cmdline = cmdline,
        .cpus = cpus,
        .preemption = true,
        .step_margin = check_spin_step_margin,
    });

    defer first.transcript.deinit();

    var second = try check_run(gpa, kernel, .{
        .branch_exits = &branch_exits,
        .cmdline = cmdline,
        .cpus = cpus,
        .preemption = true,
    });

    defer second.transcript.deinit();

    try check_cpus_online(first.transcript.written(), cpus);
    try std.testing.expect(std.mem.find(u8, first.transcript.written(), "SLEEP WOKE") != null);
    try std.testing.expect(std.mem.find(u8, first.transcript.written(), "CHECK DONE") != null);
    try std.testing.expect(first.outcome.branches > 0);
    try std.testing.expectEqualStrings(first.transcript.written(), second.transcript.written());
    try std.testing.expectEqual(first.outcome, second.outcome);
    try std.testing.expectEqual(first.outcome, second.branches[0].outcome);
}

fn check_sweep(gpa: std.mem.Allocator, kernel: []const u8, cpus: u8, first: u64) !void {
    var synced: u32 = 0;
    var unsynced: u32 = 0;

    for (0..check_sweep_points) |point| {
        var run = try check_run(gpa, kernel, .{
            .cmdline = check_cmdline_crash,
            .cmdline_reboot = check_cmdline_verify,
            .cpus = cpus,
            .crash_exit = first + point * check_sweep_step,
            .faults = .{ .disk = .{ .persist_permille = 500 } },
            .preemption = cpus > 1,
        });

        defer run.transcript.deinit();

        const transcript = run.transcript.written();
        const sectors = try check_sectors(transcript);

        try check_cpus_online(transcript, cpus);
        try std.testing.expectEqual(@as(u64, 2), run.outcome.cycles);

        if (std.mem.find(u8, transcript, "SYNCED") == null) {
            unsynced += 1;

            continue;
        }

        synced += 1;

        try std.testing.expectEqual(@as(u64, check_target_size), sectors.size);
        try std.testing.expectEqual(@as(u64, check_target_sectors), sectors.old + sectors.new);
        try std.testing.expectEqual(@as(u64, 0), sectors.mixed);
        try std.testing.expectEqual(@as(u64, 0), sectors.new % check_unit_sectors);
    }

    try std.testing.expect(synced > 0);
    try std.testing.expect(unsynced > 0);
}

fn check_transcript(
    gpa: std.mem.Allocator,
    directory: *const std.testing.TmpDir,
    seed: u64,
) ![]u8 {
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "transcript.{d}", .{seed});

    return directory.dir.readFileAlloc(std.testing.io, name, gpa, .unlimited);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("tidy.zig");
}
