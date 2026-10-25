const std = @import("std");

const ports = @import("ports");

const choices_module = @import("choices.zig");
const coverage_module = @import("coverage.zig");
const faults_module = @import("faults.zig");
const kvm = @import("kvm.zig");
const lapic_module = @import("lapic.zig");
const pic_module = @import("pic.zig");
const pit_module = @import("pit.zig");
const pmu_module = @import("pmu.zig");
const rtc_module = @import("rtc.zig");
const serial_module = @import("serial.zig");
const snapshot = @import("snapshot.zig");
const step_module = @import("step.zig");
const virtio_block = @import("virtio_block.zig");

const assert = std.debug.assert;
const linux = std.os.linux;
const Coverage = coverage_module.Coverage;
const Guidance = coverage_module.Guidance;
const Event = faults_module.Event;
const ForkPoint = snapshot.ForkPoint;
const Ipi = lapic_module.Ipi;
const Lapic = lapic_module.Lapic;
const Pic = pic_module.Pic;
const Pit = pit_module.Pit;
const Pmu = pmu_module.Pmu;
const Rtc = rtc_module.Rtc;
const Serial = serial_module.Serial;
const Stepper = step_module.Stepper;
const Stream = choices_module.Stream;
const Timeline = faults_module.Timeline;
const VirtioBlock = virtio_block.VirtioBlock;

pub const Cpu = struct {
    branches: u64 = 0,
    exits: u64 = 0,
    halt_masked: bool = false,
    halted: bool = false,
    lapic: Lapic,
    nmi_pending: bool = false,
    single_step: bool = false,
    startup: bool = false,
    step_reported: bool = false,
    stepper: Stepper,
    vcpu: kvm.Vcpu,

    pub fn runnable(cpu: *const Cpu) bool {
        return !cpu.halted and !cpu.startup;
    }
};

pub const Error = error{
    CpuNotRunnable,
    DebugTrapUnexpected,
    EntryFailed,
    GuestStalled,
    HaltWithInterruptsDisabled,
    HaltWithoutWakeup,
    InternalError,
    SkidExceeded,
    TimeLimitExceeded,
    UnhandledExit,
    WatchdogFailed,
} || kvm.Error || pmu_module.Error || serial_module.Error || step_module.Error;

pub const Outcome = extern struct {
    branches: u64,
    cpu_branches: [cpus_max]u64,
    cpu_exits: [cpus_max]u64,
    cycle_first_exits: u64,
    cycles: u64,
    disk_errors: u64,
    disk_hash: u64,
    exits: u64,
    memory_hash: u64,
    serial_hash: u64,
    time_ns: u64,
};

pub const Stop = enum {
    crash,
    paused,
    shutdown,
};

pub const Machine = struct {
    block: ?*VirtioBlock,
    branch_ps: u64 = faults_module.branch_ps_default,
    branches: u64 = 0,
    branches_base: u64 = 0,
    change_point: ?u64 = null,
    coverage: ?*Coverage = null,
    cpus: [cpus_max]Cpu = undefined,
    cpus_count: u32 = 0,
    crash_delay_ns: ?u64 = null,
    crash_time_ns: ?u64 = null,
    current: u32 = 0,
    cycle: u32 = 0,
    draw_word: u64 = 0,
    events: ?*Stream = null,
    exits: u64 = 0,
    guidance: ?*Guidance = null,
    input_signal: ?linux.fd_t = null,
    jitter: ?*Stream = null,
    jitter_ns_max: u64 = 0,
    memory: []align(kvm.page_size) u8,
    pause_exit: ?u64 = null,
    pic: Pic = .{},
    pit: Pit = .{},
    pmu: ?*Pmu,
    power_loss_ignored: bool = false,
    priority_order: [cpus_max]u8 = undefined,
    ready_pause: bool = false,
    rtc: Rtc = .{},
    schedule: ?*Stream = null,
    seed: u64 = 0,
    serial: *Serial,
    serial_debug: ?*Serial = null,
    step_margin: u64 = pmu_module.skid_margin,
    stop: *const std.atomic.Value(bool),
    tick_due_ns: ?u64 = null,
    time_base_ns: u64 = 0,
    time_limit_ns: u64 = std.math.maxInt(u64),
    time_ns: u64 = 0,
    timeline: ?*Timeline = null,
    watchdog: ?Watchdog = null,
    watchdog_branches: u64 = 0,
    watchdog_exits: u64 = 0,
    watchdog_ns: u64 = 0,
    watchdog_wall_ns: u64 = 0,
    workload: ?*Stream = null,

    fn control_write(machine: *Machine, value: u8) Step {
        switch (value) {
            ports.control_power_loss => if (!machine.power_loss_ignored) return .crash,
            ports.control_event_due => machine.event_due(),
            ports.control_event_wait => machine.event_wait(),
            ports.control_quiet => if (machine.block) |block| block.quiet(),
            ports.control_ready => {
                if (machine.crash_delay_ns) |delay| machine.crash_time_ns = machine.time_ns + delay;
                if (machine.block) |block| block.errors_arm(machine.time_ns);
                if (machine.timeline) |timeline| timeline.ready_ns = machine.time_ns;

                if (machine.ready_pause) {
                    assert(machine.pause_exit == null);

                    machine.pause_exit = machine.exits;
                    machine.ready_pause = false;
                }
            },
            else => {},
        }

        return .@"continue";
    }

    fn coverage_write(machine: *Machine, port: u16, value: u8) void {
        const coverage = machine.coverage orelse return;
        const offset = port - ports.coverage_first;
        const index = coverage.latch_byte(offset, value) orelse return;
        var point: ForkPoint = undefined;

        assert(port >= ports.coverage_first);
        assert(port <= ports.coverage_last);

        machine.fork_point(&point);
        coverage.record(index, if (machine.cycle == 0) &point else null);
    }

    fn cpu_current(machine: *Machine) *Cpu {
        assert(machine.current < machine.cpus_count);

        return &machine.cpus[machine.current];
    }

    fn cpu_current_view(machine: *const Machine) *const Cpu {
        assert(machine.current < machine.cpus_count);

        return &machine.cpus[machine.current];
    }

    fn crash_due(machine: *const Machine) bool {
        const deadline = machine.crash_time_ns orelse return false;
        return machine.time_ns >= deadline;
    }

    fn debug_observe(machine: *Machine, debug: *const kvm.DebugExit) Error!void {
        assert(machine.pmu != null or !machine.cpu_current().single_step);

        if (!machine.cpu_current().single_step) return machine.debug_unexpected(debug);
        if (debug.exception != kvm.exception_debug) return machine.debug_unexpected(debug);

        const cpu = machine.cpu_current();

        try cpu.stepper.observe(cpu.vcpu, machine.memory, debug.pc, machine.branches);

        assert(machine.cpu_current().stepper.rip == debug.pc);
    }

    fn debug_read(machine: *Machine, port: u16) u8 {
        const debug = machine.serial_debug orelse return 0xff;

        assert(port >= debug_port_first);
        assert(port <= debug_port_last);

        return debug.read(port);
    }

    fn debug_unexpected(machine: *Machine, debug: *const kvm.DebugExit) Error {
        assert(machine.cpus_count > 0);
        assert(machine.current < machine.cpus_count);

        std.log.err("unexpected debug exit {d} at {x}, dr6 {x}, stepping {}", .{
            debug.exception,
            debug.pc,
            debug.dr6,
            machine.cpu_current().single_step,
        });

        return error.DebugTrapUnexpected;
    }

    fn devices_poll(machine: *Machine) void {
        if (machine.pit.poll(machine.time_ns)) machine.tick_schedule();

        if (machine.tick_due_ns) |due| {
            if (machine.time_ns >= due) {
                machine.pic.irq_pulse(pit_irq);
                machine.tick_due_ns = null;
            }
        }

        if (machine.block) |block| {
            if (block.complete_due(machine.memory, machine.time_ns)) {
                machine.pic.irq_pulse(virtio_block.irq);
            }
        }

        const serial_level: u1 = if (machine.serial.interrupt_pending()) 1 else 0;

        machine.pic.irq_level_set(machine.serial.irq, serial_level);

        if (machine.serial_debug) |debug| {
            const debug_level: u1 = if (debug.interrupt_pending()) 1 else 0;

            machine.pic.irq_level_set(debug.irq, debug_level);
        }

        if (!machine.smp()) return;

        for (machine.cpus[0..machine.cpus_count]) |*cpu| {
            const expiry = cpu.lapic.timer_expiry_ns() orelse continue;

            if (machine.time_ns >= expiry) cpu.lapic.timer_fire(machine.time_ns);
        }

        machine.wake();
    }

    fn draw_latch(machine: *Machine, value: u8) void {
        const workload = machine.workload orelse return;
        const position = workload.position;

        if (value != ports.draw_latch) return;

        machine.draw_word = workload.word();

        assert(workload.position == position + 1);
    }

    fn event_byte(machine: *const Machine, port: u16) u8 {
        const timeline = machine.timeline orelse return 0xff;

        assert(port >= ports.event_first);
        assert(port <= event_port_last);

        return faults_module.event_byte(&timeline.served, port - ports.event_first);
    }

    fn event_due(machine: *Machine) void {
        const timeline = machine.timeline orelse return;
        const events = machine.events orelse return;
        var point: ForkPoint = undefined;

        assert(timeline.count <= faults_module.events_max);

        machine.fork_point(&point);
        timeline.due(events, machine.time_ns, &point);

        assert(timeline.served.magic == faults_module.event_magic);
    }

    fn event_ns_next(machine: *const Machine) ?u64 {
        const block: ?u64 = if (machine.block) |device| device.completion_ns_next() else null;
        var next = machine.pit.expiry_ns_next();

        for ([_]?u64{ block, machine.crash_time_ns, machine.tick_due_ns }) |candidate| {
            const time = candidate orelse continue;

            next = @min(next orelse time, time);
        }

        if (!machine.smp()) return next;

        for (machine.cpus[0..machine.cpus_count]) |*cpu| {
            const time = cpu.lapic.timer_expiry_ns() orelse continue;

            next = @min(next orelse time, time);
        }

        return next;
    }

    fn event_wait(machine: *Machine) void {
        const timeline = machine.timeline orelse return;
        const events = machine.events orelse return;

        assert(timeline.count <= faults_module.events_max);

        timeline.wait(events, machine.time_ns);

        assert(timeline.served.magic == faults_module.event_magic);
        assert(timeline.served.kind == .none);
    }

    fn exit_count(machine: *Machine) void {
        assert(machine.exits < exits_max);
        assert(machine.time_ns >= machine.time_base_ns);

        machine.exits += 1;

        machine.cpu_current().exits += 1;
        machine.time_base_ns += exit_quantum_ns;
        machine.time_ns += exit_quantum_ns;
    }

    fn exit_handle(machine: *Machine, area: *kvm.Run) Error!Step {
        switch (area.exit_reason) {
            .hlt => return machine.halt_handle(area),
            .io => return machine.io_handle(area),
            .irq_window_open => return .@"continue",
            .mmio => {
                try machine.mmio_handle(area);

                return .@"continue";
            },
            .shutdown => return .shutdown,
            .fail_entry => {
                const reason = area.exit.fail_entry.hardware_entry_failure_reason;

                std.log.err("vm entry failed: reason {x}", .{reason});

                return error.EntryFailed;
            },
            .internal_error => {
                std.log.err("kvm internal error: suberror {d}", .{area.exit.internal.suberror});

                return error.InternalError;
            },
            else => |reason| {
                std.log.err("unhandled exit {d}", .{@backingInt(reason)});

                return error.UnhandledExit;
            },
        }
    }

    fn extint_routed(machine: *const Machine, index: u32) bool {
        assert(index < machine.cpus_count);

        if (!machine.smp()) return true;
        if (index != 0) return false;
        return machine.cpus[0].lapic.extint();
    }

    fn guidance_write(machine: *Machine, port: u16, value: u8) void {
        const guidance = machine.guidance orelse return;
        const offset = port - ports.guidance_first;
        const report = guidance.latch_byte(offset, value) orelse return;
        var point: ForkPoint = undefined;

        assert(port >= ports.guidance_first);
        assert(port <= ports.guidance_last);

        machine.fork_point(&point);
        guidance.record(report, if (machine.cycle == 0) &point else null);
    }

    fn halt_handle(machine: *Machine, area: *kvm.Run) Error!Step {
        if (machine.smp()) {
            const cpu = machine.cpu_current();

            cpu.halted = true;
            cpu.halt_masked = area.if_flag == 0;

            machine.wake();

            return .@"continue";
        }

        if (area.if_flag == 0) return error.HaltWithInterruptsDisabled;
        if (machine.serial.interrupt_pending()) return .@"continue";

        if (machine.serial_debug) |debug| {
            if (debug.interrupt_pending()) return .@"continue";
        }

        const expiry = machine.event_ns_next();

        if (machine.input_signal) |signal| {
            const delay: ?u64 = if (expiry) |time| time -| machine.time_ns else null;

            if (machine.stop.load(.acquire)) return error.Interrupted;
            if (input_wait(signal, delay)) return .@"continue";
            if (machine.stop.load(.acquire)) return error.Interrupted;
        }

        const time = expiry orelse return error.HaltWithoutWakeup;

        if (time > machine.time_ns) {
            machine.time_base_ns += time - machine.time_ns;
            machine.time_ns = time;
        }

        return .@"continue";
    }

    fn interrupt_deliver(machine: *Machine, area: *kvm.Run) Error!void {
        const cpu = machine.cpu_current();

        if (cpu.nmi_pending) {
            cpu.nmi_pending = false;

            try cpu.vcpu.nmi_inject();
        }

        if (!machine.interrupt_pending(machine.current)) {
            area.request_interrupt_window = 0;

            return;
        }

        if (area.ready_for_interrupt_injection == 0) {
            area.request_interrupt_window = 1;

            return;
        }

        const external = machine.extint_routed(machine.current) and machine.pic.interrupt_pending();

        const vector = if (external)
            machine.pic.interrupt_acknowledge()
        else
            cpu.lapic.acknowledge();

        try cpu.vcpu.interrupt_inject(vector);

        area.ready_for_interrupt_injection = 0;
        area.request_interrupt_window = @intFromBool(machine.interrupt_pending(machine.current));
    }

    fn interrupt_pending(machine: *const Machine, index: u32) bool {
        const cpu = &machine.cpus[index];

        assert(index < machine.cpus_count);

        if (machine.extint_routed(index)) {
            if (machine.pic.interrupt_pending()) return true;
        }

        return machine.smp() and cpu.lapic.pending() != null;
    }

    fn io_handle(machine: *Machine, area: *kvm.Run) Error!Step {
        const io = area.exit.io;
        const data = area.io_data();

        assert(data.len == @as(usize, io.size) * io.count);

        for (0..io.count) |i| {
            const chunk = data[i * io.size ..][0..io.size];

            switch (io.direction) {
                .in => {
                    @memset(chunk, 0xff);
                    chunk[0] = machine.port_read(io.port);
                },
                .out => switch (try machine.port_write(io.port, chunk[0])) {
                    .@"continue" => {},
                    .crash, .shutdown => |step| return step,
                },
            }
        }

        return .@"continue";
    }

    fn ipi_deliver(machine: *Machine, ipi: Ipi) Error!void {
        const source = machine.current;

        assert(machine.smp());

        for (machine.cpus[0..machine.cpus_count], 0..) |*cpu, index| {
            const broadcast = ipi.destination == 0xff;
            const physical = cpu.lapic.id == ipi.destination or broadcast;
            const matched = if (ipi.logical) cpu.lapic.logical_match(ipi.destination) else physical;

            const selected = switch (ipi.shorthand) {
                .none => matched,
                .self => index == source,
                .all => true,
                .others => index != source,
            };

            if (!selected) continue;

            switch (ipi.delivery) {
                .fixed, .lowest => if (ipi.vector >= 16) cpu.lapic.accept(ipi.vector, false),
                .nmi => cpu.nmi_pending = true,
                .init => if (ipi.level) cpu_sipi_wait(cpu, index),
                .startup => if (cpu.startup) try cpu_start(cpu, ipi.vector),
                else => {},
            }

            if (ipi.delivery == .lowest) break;
        }

        machine.wake();
    }

    fn lapic_access(machine: *Machine, offset: u64, data: []u8, write: bool) Error!void {
        const lapic = &machine.cpu_current().lapic;
        const register: u32 = @intCast(offset);

        assert(data.len == 4);
        assert(offset < lapic_module.page_size);

        if (!write) {
            std.mem.writeInt(u32, data[0..4], lapic.read(register, machine.time_ns), .little);

            return;
        }

        const value = std.mem.readInt(u32, data[0..4], .little);
        const ipi = lapic.write(register, value, machine.time_ns) orelse return;

        try machine.ipi_deliver(ipi);
    }

    fn mmio_handle(machine: *Machine, area: *kvm.Run) Error!void {
        const mmio = &area.exit.mmio;

        assert(mmio.len <= mmio.data.len);

        const data = mmio.data[0..mmio.len];

        const in_lapic = machine.smp() and mmio.phys_addr >= lapic_module.base and
            mmio.phys_addr + mmio.len <= lapic_module.base + lapic_module.page_size;

        if (in_lapic) {
            const offset = mmio.phys_addr - lapic_module.base;
            return machine.lapic_access(offset, data, mmio.is_write != 0);
        }

        const in_block = mmio.phys_addr >= virtio_block.mmio_base and
            mmio.phys_addr + mmio.len <= virtio_block.mmio_base + virtio_block.mmio_size;

        if (machine.block) |block| {
            if (in_block) {
                const offset = mmio.phys_addr - virtio_block.mmio_base;

                if (mmio.is_write == 0) {
                    block.read(offset, data);
                } else if (block.write(machine.memory, offset, data, machine.time_ns)) {
                    machine.pic.irq_pulse(virtio_block.irq);
                } else {}

                return;
            }
        }

        if (mmio.is_write == 0) @memset(data, 0);
    }

    fn pause_due(machine: *const Machine) bool {
        const exit = machine.pause_exit orelse return false;
        return machine.exits >= exit;
    }

    fn pause_prepare(machine: *Machine) Error!void {
        assert(machine.cpu_current().vcpu.run_area_view().immediate_exit == 0);

        for (machine.cpus[0..machine.cpus_count]) |*cpu| {
            try cpu_park(cpu);
            try cpu.vcpu.io_complete();
        }

        assert(!machine.cpu_current().single_step);
    }

    fn port_read(machine: *Machine, port: u16) u8 {
        return switch (port) {
            pic_module.master_command,
            pic_module.master_data,
            pic_module.slave_command,
            pic_module.slave_data,
            pic_module.elcr_master,
            pic_module.elcr_slave,
            => machine.pic.read(port),
            pit_module.channel_port_base...pit_module.control_port,
            pit_module.speaker_port,
            => machine.pit.read(machine.time_ns, port),
            rtc_module.index_port, rtc_module.data_port => machine.rtc.read(port),
            serial_port_first...serial_port_last => machine.serial.read(port),
            debug_port_first...debug_port_last => machine.debug_read(port),
            i8042_command_port => i8042_status_idle,
            ports.seed_first...ports.seed_last => seed_byte(machine.seed, port),
            ports.event_first...event_port_last => machine.event_byte(port),
            ports.draw_first + 1...ports.draw_last => draw_byte(machine.draw_word, port),
            else => 0xff,
        };
    }

    fn port_write(machine: *Machine, port: u16, value: u8) Error!Step {
        switch (port) {
            pic_module.master_command,
            pic_module.master_data,
            pic_module.slave_command,
            pic_module.slave_data,
            pic_module.elcr_master,
            pic_module.elcr_slave,
            => machine.pic.write(port, value),
            pit_module.channel_port_base...pit_module.control_port,
            pit_module.speaker_port,
            => machine.pit.write(machine.time_ns, port, value),
            rtc_module.index_port, rtc_module.data_port => machine.rtc.write(port, value),
            serial_port_first...serial_port_last => try machine.serial.write(port, value),
            debug_port_first...debug_port_last => {
                if (machine.serial_debug) |debug| try debug.write(port, value);
            },
            i8042_command_port => if (value == i8042_reset) return .shutdown,
            ports.control => return machine.control_write(value),
            ports.draw_first => machine.draw_latch(value),
            ports.coverage_first...ports.coverage_last => {
                machine.coverage_write(port, value);
            },
            ports.guidance_first...ports.guidance_last => {
                machine.guidance_write(port, value);
            },
            else => {},
        }

        return .@"continue";
    }

    fn preemption_arm(machine: *Machine) Error!void {
        const pmu = machine.pmu orelse return;
        const target = machine.preemption_target();
        const remaining = if (target) |branch| branch -| machine.branches else 0;

        assert(machine.step_margin >= pmu_module.skid_margin);

        try machine.single_step_enable(remaining > 0 and remaining <= machine.step_margin);

        const cpu = machine.cpu_current();
        const window = !cpu.single_step and machine.interrupt_pending(machine.current);

        cpu.vcpu.run_area_view().request_interrupt_window = @intFromBool(window);

        if (cpu.single_step) return pmu.disarm();
        if (remaining == 0) return pmu.disarm();

        try pmu.arm(target.?, machine.branches, machine.step_margin);
    }

    fn preemption_target(machine: *const Machine) ?u64 {
        const change = if (machine.runnable_other()) machine.change_point else null;
        const expiry = machine.event_ns_next() orelse return change;
        if (expiry <= machine.time_base_ns) return machine.branches;

        const remaining = expiry - machine.time_base_ns;
        const event = branch_target(machine.branches_base, remaining, machine.branch_ps);

        return if (change) |point| @min(point, event) else event;
    }

    fn priority_demote(machine: *Machine, index: u32) void {
        const order = machine.priority_order[0..machine.cpus_count];
        const position = std.mem.findScalar(u8, order, @intCast(index)) orelse unreachable;

        assert(machine.smp());

        std.mem.copyForwards(u8, order[position .. order.len - 1], order[position + 1 ..]);
        order[order.len - 1] = @intCast(index);

        assert(order[order.len - 1] == index);
    }

    fn priority_first(machine: *const Machine) ?u32 {
        assert(machine.smp());

        for (machine.priority_order[0..machine.cpus_count]) |index| {
            if (!machine.cpus[index].runnable()) continue;

            assert(index < machine.cpus_count);

            return index;
        }

        return null;
    }

    fn runnable_any(machine: *const Machine) bool {
        assert(machine.cpus_count > 0);
        assert(machine.cpus_count <= cpus_max);

        for (machine.cpus[0..machine.cpus_count]) |*cpu| {
            if (cpu.runnable()) return true;
        }

        return false;
    }

    fn runnable_other(machine: *const Machine) bool {
        assert(machine.current < machine.cpus_count);
        assert(machine.cpus_count <= cpus_max);

        for (machine.cpus[0..machine.cpus_count], 0..) |*cpu, index| {
            if (index == machine.current) continue;
            if (cpu.runnable()) return true;
        }

        return false;
    }

    fn schedule_change(machine: *Machine) void {
        const schedule = machine.schedule orelse unreachable;
        var point = machine.change_point orelse machine.branches + change_distance(schedule);

        assert(machine.smp());

        for (0..change_rounds_max) |_| {
            if (machine.branches < point) break;

            machine.priority_demote(machine.current);
            point += change_distance(schedule);
        } else unreachable;

        machine.change_point = point;

        assert(point > machine.branches);
    }

    fn schedule_check(machine: *Machine) Error!bool {
        if (!machine.smp()) return true;

        machine.schedule_change();

        assert(machine.change_point.? > machine.branches);

        const idle = !machine.runnable_any();

        if (idle) try machine.schedule_idle();

        const next = machine.priority_first() orelse return false;
        const switched = next != machine.current;

        if (switched) {
            try cpu_park(machine.cpu_current());
            machine.current = next;
        }

        assert(machine.cpu_current().runnable());

        if (!switched) {
            if (!idle) return true;
        }

        try machine.interrupt_deliver(machine.cpu_current().vcpu.run_area_view());

        return true;
    }

    fn schedule_idle(machine: *Machine) Error!void {
        for (0..idle_rounds_max) |_| {
            if (machine.runnable_any()) return;
            if (machine.wakeable_none()) return error.HaltWithInterruptsDisabled;

            const time = machine.event_ns_next() orelse return error.HaltWithoutWakeup;

            if (machine.crash_due()) return;

            if (time > machine.time_ns) {
                machine.time_base_ns += time - machine.time_ns;
                machine.time_ns = time;
            }

            machine.devices_poll();
        }

        return error.CpuNotRunnable;
    }

    fn single_step_arrived(machine: *Machine) Error!bool {
        const target = machine.preemption_target() orelse return false;
        if (machine.branches < target) return false;

        try machine.single_step_enable(false);

        return true;
    }

    fn single_step_enable(machine: *Machine, enabled: bool) Error!void {
        const cpu = machine.cpu_current();
        const stepping = enabled or (cpu.single_step and !cpu.step_reported);

        if (!stepping) {
            if (!cpu.single_step) return;
        }

        assert(machine.pmu != null);

        if (stepping) {
            if (!cpu.single_step) try cpu.stepper.begin(cpu.vcpu, machine.memory, machine.branches);
        }

        const breakpoints = if (stepping) cpu.stepper.breakpoints() else kvm.breakpoints_none;

        try cpu.vcpu.guest_debug_set(stepping, &breakpoints);
        cpu.single_step = stepping;

        assert(cpu.single_step or !enabled);
    }

    fn skid_check(machine: *const Machine) Error!void {
        const pmu = machine.pmu orelse return;
        const target = pmu.armed_target orelse return;
        if (machine.branches < target) return;

        std.log.err("branches {d} passed armed target {d} before stepping", .{
            machine.branches,
            target,
        });

        return error.SkidExceeded;
    }

    fn smp(machine: *const Machine) bool {
        assert(machine.cpus_count > 0);

        return machine.cpus_count > 1;
    }

    fn step_observe_natural(machine: *Machine) Error!void {
        assert(machine.cpu_current().single_step);
        assert(machine.pmu != null);

        const cpu = machine.cpu_current();

        try cpu.stepper.observe(cpu.vcpu, machine.memory, null, machine.branches);
    }

    fn tick_schedule(machine: *Machine) void {
        assert(machine.time_ns >= machine.time_base_ns);

        if (machine.tick_due_ns != null) return;

        var delay: u64 = 0;

        if (machine.jitter_ns_max > 0) {
            assert(machine.jitter != null);

            delay = machine.jitter.?.at_most(machine.jitter_ns_max);
        }

        machine.tick_due_ns = machine.time_ns + delay;

        assert(machine.tick_due_ns.? >= machine.time_ns);
    }

    fn time_update(machine: *Machine) Error!void {
        const pmu = machine.pmu orelse return;
        const branches = try pmu.count();

        assert(branches >= machine.branches);

        machine.cpu_current().branches += branches - machine.branches;
        machine.branches = branches;

        machine.time_ns = machine.time_base_ns +
            branch_time_ns(machine.branches - machine.branches_base, machine.branch_ps);
    }

    fn wake(machine: *Machine) void {
        assert(machine.smp());
        assert(machine.cpus_count <= cpus_max);

        for (machine.cpus[0..machine.cpus_count], 0..) |*cpu, index| {
            if (!cpu.halted) continue;

            const maskable = !cpu.halt_masked and machine.interrupt_pending(@intCast(index));

            if (!cpu.nmi_pending) {
                if (!maskable) continue;
            }

            cpu.halted = false;
            cpu.halt_masked = false;
        }
    }

    fn wakeable_none(machine: *const Machine) bool {
        assert(machine.smp());
        assert(machine.cpus_count <= cpus_max);

        for (machine.cpus[0..machine.cpus_count]) |*cpu| {
            if (cpu.startup) continue;
            if (!cpu.halted) return false;
            if (!cpu.halt_masked) return false;
            if (cpu.nmi_pending) return false;
        }

        return true;
    }

    fn watchdog_check(machine: *Machine) Error!void {
        if (machine.watchdog_ns == 0) return;

        const now = try wall_ns();

        const progressed = machine.exits != machine.watchdog_exits or
            machine.branches != machine.watchdog_branches;

        assert(now >= machine.watchdog_wall_ns);

        if (progressed) return machine.watchdog_reset(now);
        if (machine.watchdog_wall_ns == 0) return machine.watchdog_reset(now);
        if (now - machine.watchdog_wall_ns < machine.watchdog_ns) return;
        return error.GuestStalled;
    }

    fn watchdog_reset(machine: *Machine, now: u64) void {
        assert(now >= machine.watchdog_wall_ns);

        machine.watchdog_branches = machine.branches;
        machine.watchdog_exits = machine.exits;
        machine.watchdog_wall_ns = now;

        assert(machine.watchdog_wall_ns == now);
    }

    fn window_opened(machine: *const Machine, area: *const kvm.Run) bool {
        assert(machine.cpu_current_view().single_step);
        assert(area.exit_reason == .debug);

        const pending = machine.interrupt_pending(machine.current);
        return area.ready_for_interrupt_injection != 0 and pending;
    }

    pub fn cpus_attach(machine: *Machine, vcpus: []const kvm.Vcpu, entry_exception: u64) void {
        assert(vcpus.len > 0);
        assert(vcpus.len <= cpus_max);

        machine.cpus_count = @intCast(vcpus.len);
        machine.current = 0;

        for (vcpus, 0..) |vcpu, index| {
            machine.cpus[index] = .{
                .lapic = .reset(@intCast(index), index == 0),
                .startup = index != 0,
                .stepper = .{ .entry_exception = entry_exception },
                .vcpu = vcpu,
            };

            machine.priority_order[index] = @intCast(index);
        }

        if (!machine.smp()) return;

        const schedule = machine.schedule orelse unreachable;

        schedule.shuffle(u8, machine.priority_order[0..machine.cpus_count]);
    }

    pub fn fork_point(machine: *const Machine, point: *ForkPoint) void {
        assert(machine.cpus_count > 0);
        assert(machine.cpus_count <= snapshot.vcpus_max);

        point.* = .{ .branches = machine.branches, .exits = machine.exits };

        for (machine.cpus[0..machine.cpus_count], 0..) |*cpu, index| {
            point.cpu_branches[index] = cpu.branches;
        }
    }

    pub fn outcome(machine: *const Machine) Outcome {
        const disk: []const u8 = if (machine.block) |block| block.image else "";
        var branches_total: u64 = 0;
        var exits_total: u64 = 0;

        var result: Outcome = .{
            .branches = machine.branches,
            .cpu_branches = @splat(0),
            .cpu_exits = @splat(0),
            .cycle_first_exits = machine.exits,
            .cycles = 1,
            .disk_errors = if (machine.block) |block| block.errors_injected else 0,
            .disk_hash = std.hash.Wyhash.hash(0, disk),
            .exits = machine.exits,
            .memory_hash = std.hash.Wyhash.hash(0, machine.memory),
            .serial_hash = machine.serial.transcript.value,
            .time_ns = machine.time_ns,
        };

        for (machine.cpus[0..machine.cpus_count], 0..) |*cpu, index| {
            result.cpu_branches[index] = cpu.branches;
            result.cpu_exits[index] = cpu.exits;
            branches_total += cpu.branches;
            exits_total += cpu.exits;
        }

        assert(branches_total == machine.branches);
        assert(exits_total == machine.exits);

        return result;
    }

    pub fn rate_set(machine: *Machine, branch_ps: u64) void {
        const time_ns = machine.time_ns;

        assert(machine.pause_exit == null);
        assert(branch_ps >= faults_module.branch_ps_min);
        assert(branch_ps <= faults_module.branch_ps_max);

        machine.time_base_ns = machine.time_ns;
        machine.branches_base = machine.branches;
        machine.branch_ps = branch_ps;

        assert(machine.time_ns == time_ns);
    }

    pub fn resume_on(machine: *Machine, vcpus: []const kvm.Vcpu, pmu: ?*Pmu) void {
        assert((pmu == null) == (machine.pmu == null));
        assert(machine.pause_exit == null);
        assert(vcpus.len == machine.cpus_count);

        if (pmu) |counter| {
            assert(counter.armed_target == null);
            assert(counter.base_count == machine.branches);
        }

        machine.pmu = pmu;

        for (machine.cpus[0..machine.cpus_count], vcpus) |*cpu, vcpu| {
            cpu.single_step = false;
            cpu.step_reported = false;
            cpu.vcpu = vcpu;
        }
    }

    pub fn run(machine: *Machine) Error!Stop {
        machine.watchdog_wall_ns = 0;

        if (machine.watchdog) |timer| try timer.arm(watchdog_period_ns);
        defer if (machine.watchdog) |timer| timer.disarm();

        while (machine.exits < exits_max) {
            if (machine.stop.load(.acquire)) return error.Interrupted;

            if (machine.pause_due()) {
                try machine.pause_prepare();
                machine.pause_exit = null;

                return .paused;
            }

            if (!try machine.schedule_check()) {
                assert(machine.crash_due());

                return .crash;
            }

            try machine.preemption_arm();

            const area = machine.cpu_current().vcpu.run() catch |err| switch (err) {
                error.Interrupted => {
                    machine.cpu_current().step_reported = false;

                    try machine.time_update();
                    try machine.skid_check();
                    try machine.watchdog_check();

                    continue;
                },
                else => return err,
            };

            machine.cpu_current().step_reported = area.exit_reason == .debug;

            try machine.time_update();

            if (area.exit_reason == .debug) {
                try machine.debug_observe(&area.exit.debug);

                if (!try machine.single_step_arrived()) {
                    if (!machine.window_opened(area)) continue;

                    machine.exit_count();
                }
            } else {
                if (machine.cpu_current().single_step) try machine.step_observe_natural();

                machine.exit_count();

                switch (try machine.exit_handle(area)) {
                    .@"continue" => {},
                    .crash => return .crash,
                    .shutdown => return .shutdown,
                }
            }

            if (machine.crash_due()) return .crash;
            if (machine.time_ns >= machine.time_limit_ns) return error.TimeLimitExceeded;

            machine.devices_poll();
            try machine.interrupt_deliver(area);
        }

        return .shutdown;
    }

    pub fn vcpus_view(machine: *const Machine, out: *[cpus_max]kvm.Vcpu) []const kvm.Vcpu {
        const count = machine.cpus_count;

        assert(count > 0);
        assert(count <= cpus_max);

        for (machine.cpus[0..count], out[0..count]) |*cpu, *vcpu| vcpu.* = cpu.vcpu;

        return out[0..count];
    }
};

pub const Watchdog = struct {
    timer: i32,

    fn word(watchdog: Watchdog) usize {
        return @bitCast(@as(isize, watchdog.timer));
    }

    pub fn arm(watchdog: Watchdog, period_ns: u64) Error!void {
        assert(period_ns > 0);
        assert(period_ns < std.time.ns_per_s * 60);

        const period: linux.timespec = .{
            .sec = @intCast(period_ns / std.time.ns_per_s),
            .nsec = @intCast(period_ns % std.time.ns_per_s),
        };

        const spec: linux.itimerspec = .{ .it_interval = period, .it_value = period };
        const armed = linux.syscall4(.timer_settime, watchdog.word(), 0, @intFromPtr(&spec), 0);
        if (linux.errno(armed) != .SUCCESS) return error.WatchdogFailed;
    }

    pub fn disarm(watchdog: Watchdog) void {
        const zero: linux.timespec = .{ .sec = 0, .nsec = 0 };
        const spec: linux.itimerspec = .{ .it_interval = zero, .it_value = zero };
        const disarmed = linux.syscall4(.timer_settime, watchdog.word(), 0, @intFromPtr(&spec), 0);

        assert(linux.errno(disarmed) == .SUCCESS);
    }

    pub fn stop(watchdog: Watchdog) void {
        const deleted = linux.syscall1(.timer_delete, watchdog.word());

        assert(linux.errno(deleted) == .SUCCESS);
    }
};

const SignalEvent = extern struct {
    value: u64,
    signal: i32,
    notify: i32,
    thread: i32,
    padding: [11]i32,
};

const Step = enum {
    @"continue",
    crash,
    shutdown,
};

pub const watchdog_period_ns = 250 * std.time.ns_per_ms;
pub const watchdog_signal: linux.SIG = .ALRM;

pub const cmdline_required = "nolapic idle=halt lpj=3400000 no_timer_check" ++
    " random.trust_bootloader=on mitigations=off";

pub const cmdline_required_smp = "noapic idle=halt lpj=3400000 no_timer_check" ++
    " random.trust_bootloader=on mitigations=off";

pub const cpus_max = 8;
pub const cmdline_block = "virtio_mmio.device=4K@0xd0000000:5";
const picoseconds_per_ns = 1000;
const change_branches_min = 50_000;
const change_branches_spread = 900_000;
const change_rounds_max = 1 << 24;
const event_port_last = ports.event_first + @sizeOf(Event) - 1;
const exit_quantum_ns = 1_000;
const exits_max = 1 << 40;
const i8042_command_port = 0x64;
const i8042_reset = 0xfe;
const i8042_status_idle = 0x00;
const idle_rounds_max = 1 << 20;
const pit_irq = 0;
const debug_port_first = serial_module.debug_port_base;
const debug_port_last = serial_module.debug_port_base + serial_module.port_count - 1;
const serial_port_first = serial_module.console_port_base;
const serial_port_last = serial_module.console_port_base + serial_module.port_count - 1;
const signal_notify_thread = 4;

fn branch_target(branches_base: u64, remaining_ns: u64, branch_ps: u64) u64 {
    const needed = std.math.divCeil(u64, remaining_ns * picoseconds_per_ns, branch_ps) catch
        unreachable;

    assert(branch_ps > 0);
    assert(branch_time_ns(needed, branch_ps) >= remaining_ns);

    return branches_base + needed;
}

fn branch_time_ns(branches: u64, branch_ps: u64) u64 {
    assert(branch_ps > 0);

    return branches * branch_ps / picoseconds_per_ns;
}

fn change_distance(stream: *Stream) u64 {
    const distance = change_branches_min + stream.at_most(change_branches_spread);

    assert(distance >= change_branches_min);
    assert(distance <= change_branches_min + change_branches_spread);

    return distance;
}

fn cpu_park(cpu: *Cpu) Error!void {
    if (cpu.single_step) try cpu.vcpu.guest_debug_set(false, &kvm.breakpoints_none);

    cpu.single_step = false;
    cpu.step_reported = false;

    assert(!cpu.single_step);
}

fn cpu_sipi_wait(cpu: *Cpu, index: usize) void {
    assert(index < cpus_max);

    if (index == 0) return;

    cpu.startup = true;
    cpu.halted = false;
    cpu.halt_masked = false;

    assert(!cpu.runnable());
}

fn cpu_start(cpu: *Cpu, vector: u8) Error!void {
    var regs: kvm.Regs = undefined;
    var sregs: kvm.Sregs = undefined;

    assert(cpu.startup);

    try cpu.vcpu.regs_get(&regs);
    try cpu.vcpu.sregs_get(&sregs);
    sregs.cs.selector = @as(u16, vector) << 8;
    sregs.cs.base = @as(u64, vector) << 12;
    regs.rip = 0;

    try cpu.vcpu.sregs_set(&sregs);
    try cpu.vcpu.regs_set(&regs);
    cpu.startup = false;
    cpu.halted = false;

    assert(cpu.runnable());
}

fn draw_byte(word: u64, port: u16) u8 {
    assert(port > ports.draw_first);
    assert(port <= ports.draw_last);

    const shift: u6 = @intCast((port - ports.draw_first - 1) * 8);
    return @truncate(word >> shift);
}

fn input_wait(signal: linux.fd_t, delay_ns: ?u64) bool {
    assert(signal >= 0);

    var poll = [1]linux.pollfd{.{ .fd = signal, .events = linux.POLL.IN }};
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };

    if (delay_ns) |delay| {
        timeout = .{
            .sec = @intCast(delay / std.time.ns_per_s),
            .nsec = @intCast(delay % std.time.ns_per_s),
        };
    }

    const rc = linux.ppoll(&poll, poll.len, if (delay_ns != null) &timeout else null, null);
    if (linux.errno(rc) != .SUCCESS) return false;
    if (rc == 0) return false;

    var count: u64 = 0;
    _ = linux.read(signal, std.mem.asBytes(&count), @sizeOf(u64));

    return true;
}

fn seed_byte(seed: u64, port: u16) u8 {
    assert(port >= ports.seed_first);
    assert(port <= ports.seed_last);

    const shift: u6 = @intCast((port - ports.seed_first) * 8);
    return @truncate(seed >> shift);
}

fn stop_request_later(stop: *std.atomic.Value(bool), thread: linux.pid_t) void {
    assert(thread > 0);
    assert(!stop.load(.acquire));

    const delay: linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };

    _ = linux.nanosleep(&delay, null);

    stop.store(true, .release);
    _ = linux.tgkill(linux.getpid(), thread, watchdog_signal);
}

fn wall_ns() Error!u64 {
    var now: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS) return error.WatchdogFailed;

    assert(now.sec >= 0);
    assert(now.nsec >= 0);

    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn watchdog_handler(_: linux.SIG) callconv(.c) void {}

pub fn watchdog_start() Error!Watchdog {
    const action: linux.Sigaction = .{
        .handler = .{ .handler = watchdog_handler },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };

    _ = linux.sigaction(watchdog_signal, &action, null);

    const event: SignalEvent = .{
        .value = 0,
        .signal = @backingInt(watchdog_signal),
        .notify = signal_notify_thread,
        .thread = linux.gettid(),
        .padding = @splat(0),
    };

    var timer: i32 = 0;
    const clock: usize = @backingInt(linux.CLOCK.MONOTONIC);
    const created = linux.syscall3(.timer_create, clock, @intFromPtr(&event), @intFromPtr(&timer));
    if (linux.errno(created) != .SUCCESS) return error.WatchdogFailed;

    assert(timer >= 0);
    assert(event.thread > 0);

    return .{ .timer = timer };
}

test "a halt waits for input or the deadline and drains the signal" {
    const flags = linux.EFD.CLOEXEC | linux.EFD.NONBLOCK;
    const rc = linux.eventfd(0, flags);

    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));

    const signal: linux.fd_t = @intCast(rc);
    defer _ = linux.close(signal);

    const one: u64 = 1;

    try std.testing.expect(!input_wait(signal, std.time.ns_per_ms));

    _ = linux.write(signal, std.mem.asBytes(&one), @sizeOf(u64));

    try std.testing.expect(input_wait(signal, std.time.ns_per_s));
    try std.testing.expect(!input_wait(signal, std.time.ns_per_ms));
}

test "the branch target is the smallest count whose time reaches the expiry at any rate" {
    var prng: std.Random.DefaultPrng = .init(0x7a7e);
    const random = prng.random();

    for (0..64) |_| {
        const branch_ps = random.intRangeAtMost(u64, 100, 10_000);
        const branches_base = random.uintAtMost(u64, 1 << 40);
        const remaining_ns = random.uintAtMost(u64, 20_000);
        const target = branch_target(branches_base, remaining_ns, branch_ps);
        var brute = branches_base;

        for (0..remaining_ns * picoseconds_per_ns / 100 + 2) |_| {
            if (branch_time_ns(brute - branches_base, branch_ps) >= remaining_ns) break;

            brute += 1;
        } else unreachable;

        try std.testing.expectEqual(brute, target);
    }

    try std.testing.expectEqual(5, branch_target(5, 0, 1000));
    try std.testing.expectEqual(1007, branch_target(7, 1000, 1000));
    try std.testing.expectEqual(4007, branch_target(7, 1000, 250));
    try std.testing.expectEqual(257, branch_target(7, 1000, 4000));
}

test "a rate change keeps the time and scales only the branches after it" {
    const memory = try kvm.guest_memory_alloc(kvm.page_size);
    defer kvm.guest_memory_free(memory);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var serial: Serial = .{ .output = &discard.writer };
    var stop: std.atomic.Value(bool) = .init(false);

    var machine: Machine = .{
        .block = null,
        .branches = 5000,
        .memory = memory,
        .pmu = null,
        .serial = &serial,
        .stop = &stop,
        .time_base_ns = 300,
        .time_ns = 5300,
    };

    machine.rate_set(4000);

    try std.testing.expectEqual(5300, machine.time_ns);
    try std.testing.expectEqual(5000, machine.branches_base);

    machine.branches = 5100;

    machine.time_ns = machine.time_base_ns +
        branch_time_ns(machine.branches - machine.branches_base, machine.branch_ps);

    try std.testing.expectEqual(5700, machine.time_ns);
    const target = branch_target(machine.branches_base, 1000, machine.branch_ps);

    try std.testing.expectEqual(5250, target);
}

test "the seed ports read the seed back little endian" {
    const seed: u64 = 0x0807060504030201;

    for (ports.seed_first..ports.seed_last + 1, 1..) |port, expected| {
        try std.testing.expectEqual(@as(u8, @intCast(expected)), seed_byte(seed, @intCast(port)));
    }
}

comptime {
    assert(cpus_max == snapshot.vcpus_max);
    assert(exit_quantum_ns > 0);
    assert(@sizeOf(Event) <= ports.event_block_size);
    assert(event_port_last <= ports.event_last);
    assert(event_port_last < serial_port_first or ports.event_first > serial_port_last);
    assert(pit_irq != serial_module.console_irq);
    assert(pit_irq != serial_module.debug_irq);
    assert(virtio_block.irq != serial_module.console_irq);
    assert(virtio_block.irq != serial_module.debug_irq);
    assert(virtio_block.irq != pit_irq);
}

test "the watchdog stops a guest that spins without an exit" {
    const spin = [_]u8{ 0xeb, 0xfe };
    const code_addr = 0x1000;
    const handle = try kvm.Kvm.open();
    defer handle.close();

    const vm = try handle.vm_create();
    defer vm.close();

    const memory = try kvm.guest_memory_alloc(0x10000);
    defer kvm.guest_memory_free(memory);

    @memcpy(memory[code_addr..][0..spin.len], &spin);
    try vm.memory_region_set(0, 0, memory);

    const vcpu = try vm.vcpu_create(0);
    defer vcpu.close();

    var sregs: kvm.Sregs = undefined;

    try vcpu.sregs_get(&sregs);
    sregs.cs.base = 0;
    sregs.cs.selector = 0;

    try vcpu.sregs_set(&sregs);

    var regs = std.mem.zeroes(kvm.Regs);

    regs.rip = code_addr;
    regs.rflags = 0x2;

    try vcpu.regs_set(&regs);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var serial: Serial = .{ .output = &discard.writer };
    var stop: std.atomic.Value(bool) = .init(false);

    var machine: Machine = .{
        .block = null,
        .memory = memory,
        .pmu = null,
        .serial = &serial,
        .stop = &stop,
        .watchdog = try watchdog_start(),
        .watchdog_ns = 3 * watchdog_period_ns,
    };

    defer machine.watchdog.?.stop();

    machine.cpus_attach(&.{vcpu}, code_addr);

    try std.testing.expectError(error.GuestStalled, machine.run());
    try std.testing.expectEqual(@as(u64, 0), machine.exits);
}

test "a stop request ends a halt that waits for input and every later run" {
    const halt = [_]u8{ 0xfb, 0xf4, 0xeb, 0xfd };
    const code_addr = 0x1000;
    const handle = try kvm.Kvm.open();
    defer handle.close();

    const vm = try handle.vm_create();
    defer vm.close();

    const memory = try kvm.guest_memory_alloc(0x10000);
    defer kvm.guest_memory_free(memory);

    @memcpy(memory[code_addr..][0..halt.len], &halt);
    try vm.memory_region_set(0, 0, memory);

    const vcpu = try vm.vcpu_create(0);
    defer vcpu.close();

    var sregs: kvm.Sregs = undefined;

    try vcpu.sregs_get(&sregs);
    sregs.cs.base = 0;
    sregs.cs.selector = 0;

    try vcpu.sregs_set(&sregs);

    var regs = std.mem.zeroes(kvm.Regs);

    regs.rip = code_addr;
    regs.rflags = 0x2;

    try vcpu.regs_set(&regs);

    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);

    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));

    const signal: linux.fd_t = @intCast(rc);
    defer _ = linux.close(signal);

    const watchdog = try watchdog_start();
    defer watchdog.stop();

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var serial: Serial = .{ .output = &discard.writer };
    var stop: std.atomic.Value(bool) = .init(false);

    var machine: Machine = .{
        .block = null,
        .input_signal = signal,
        .memory = memory,
        .pmu = null,
        .serial = &serial,
        .stop = &stop,
    };

    machine.cpus_attach(&.{vcpu}, code_addr);

    const requester = try std.Thread.spawn(.{}, stop_request_later, .{ &stop, linux.gettid() });
    defer requester.join();

    try std.testing.expectError(error.Interrupted, machine.run());
    try std.testing.expect(machine.exits > 0);

    const exits = machine.exits;

    try std.testing.expectError(error.Interrupted, machine.run());
    try std.testing.expectEqual(exits, machine.exits);
}

test "the running processor keeps the cpu until a change point sends it below every other" {
    const memory = try kvm.guest_memory_alloc(kvm.page_size);
    defer kvm.guest_memory_free(memory);

    const rounds = 2000;

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var serial: Serial = .{ .output = &discard.writer };
    var stop: std.atomic.Value(bool) = .init(false);
    var schedule: Stream = .init(0x5eed);
    var stints: [rounds]u32 = undefined;
    var machine: Machine = undefined;

    test_machine_smp(&machine, memory, &serial, &stop, &schedule);

    try std.testing.expect(try machine.schedule_check());

    for (&stints) |*stint| {
        const point = machine.change_point orelse unreachable;
        const previous = machine.current;

        machine.branches = point - 1;

        try std.testing.expect(try machine.schedule_check());
        try std.testing.expectEqual(previous, machine.current);
        try std.testing.expectEqual(point, machine.change_point orelse unreachable);
        try std.testing.expectEqual(point, machine.preemption_target() orelse unreachable);

        machine.branches = point;

        try std.testing.expect(try machine.schedule_check());

        const distance = (machine.change_point orelse unreachable) - point;

        try std.testing.expect(machine.current != previous);
        try std.testing.expect(distance >= change_branches_min);
        try std.testing.expect(distance <= change_branches_min + change_branches_spread);

        stint.* = machine.current;
    }

    for (stints[0 .. rounds - 3], stints[3..]) |stint, later| {
        try std.testing.expectEqual(stint, later);
    }
}

test "a halted processor yields at once and a woken one above the runner takes the cpu back" {
    const memory = try kvm.guest_memory_alloc(kvm.page_size);
    defer kvm.guest_memory_free(memory);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var serial: Serial = .{ .output = &discard.writer };
    var stop: std.atomic.Value(bool) = .init(false);
    var schedule: Stream = .init(0x5eed);
    var machine: Machine = undefined;

    test_machine_smp(&machine, memory, &serial, &stop, &schedule);

    try std.testing.expect(try machine.schedule_check());

    const top = machine.current;
    const order = machine.priority_order;
    const point = machine.change_point orelse unreachable;
    const count = machine.cpus_count;

    try std.testing.expectEqual(@as(u32, order[0]), top);

    machine.cpus[top].halted = true;

    try std.testing.expect(try machine.schedule_check());

    try std.testing.expectEqual(@as(u32, order[1]), machine.current);
    try std.testing.expectEqual(point, machine.change_point orelse unreachable);
    try std.testing.expectEqualSlices(u8, order[0..count], machine.priority_order[0..count]);

    machine.cpus[order[2]].halted = true;

    try std.testing.expectEqual(null, machine.preemption_target());

    machine.cpus[top].halted = false;

    try std.testing.expect(try machine.schedule_check());

    try std.testing.expectEqual(top, machine.current);
}

test "a halt with interrupts masked wakes only for an nmi and stops the machine when all are" {
    const memory = try kvm.guest_memory_alloc(kvm.page_size);
    defer kvm.guest_memory_free(memory);

    const vcpus: [3]kvm.Vcpu = @splat(.{ .fd = -1, .run_area = memory });
    const vector_fixed = 0x40;

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var serial: Serial = .{ .output = &discard.writer };
    var stop: std.atomic.Value(bool) = .init(false);
    var schedule: Stream = .init(0x5eed);

    var machine: Machine = .{
        .block = null,
        .memory = memory,
        .pmu = null,
        .schedule = &schedule,
        .serial = &serial,
        .stop = &stop,
    };

    machine.cpus_attach(&vcpus, 0);

    const masked = &machine.cpus[0];
    const open = &machine.cpus[1];

    open.startup = false;

    for ([_]*Cpu{ masked, open }) |cpu| {
        _ = cpu.lapic.write(0x0f0, 0x1ff, 0);

        cpu.lapic.accept(vector_fixed, false);
        cpu.halted = true;
    }

    masked.halt_masked = true;

    machine.wake();

    try std.testing.expect(masked.halted);
    try std.testing.expect(!open.halted);
    try std.testing.expect(!machine.wakeable_none());

    open.halted = true;
    open.halt_masked = true;

    try std.testing.expect(machine.wakeable_none());
    try std.testing.expectError(error.HaltWithInterruptsDisabled, machine.schedule_check());

    masked.nmi_pending = true;

    machine.wake();

    try std.testing.expect(!masked.halted);
    try std.testing.expect(!masked.halt_masked);
    try std.testing.expect(!machine.wakeable_none());
}

test "change points form one sequence however late a lone runnable processor applies them" {
    const memory = try kvm.guest_memory_alloc(kvm.page_size);
    defer kvm.guest_memory_free(memory);

    const vcpus: [3]kvm.Vcpu = @splat(.{ .fd = -1, .run_area = memory });
    const rounds = 300;

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var serial: Serial = .{ .output = &discard.writer };
    var stop: std.atomic.Value(bool) = .init(false);
    var schedules: [2]Stream = .{ .init(0x5eed), .init(0x5eed) };
    var machines: [2]Machine = undefined;

    for (&machines, &schedules) |*machine, *schedule| {
        test_machine_smp(machine, memory, &serial, &stop, schedule);

        for (machine.cpus[1..vcpus.len]) |*cpu| cpu.halted = true;

        try std.testing.expect(try machine.schedule_check());
    }

    const exact = &machines[0];
    const late = &machines[1];

    for (0..rounds) |round| {
        exact.branches = exact.change_point orelse unreachable;

        try std.testing.expect(try exact.schedule_check());

        if (round % 3 != 2) continue;

        late.branches = exact.branches + change_branches_min - 1;

        try std.testing.expect(try late.schedule_check());

        exact.branches = late.branches;

        try std.testing.expect(try exact.schedule_check());

        try std.testing.expectEqual(exact.change_point, late.change_point);

        try std.testing.expectEqualSlices(
            u8,
            exact.priority_order[0..vcpus.len],
            late.priority_order[0..vcpus.len],
        );
    }

    for (&machines) |*machine| {
        machine.cpus[2].halted = false;

        try std.testing.expect(try machine.schedule_check());
    }

    try std.testing.expectEqual(exact.current, late.current);

    try std.testing.expectEqualSlices(
        u8,
        exact.priority_order[0..vcpus.len],
        late.priority_order[0..vcpus.len],
    );
}

fn test_machine_smp(
    machine: *Machine,
    memory: []align(kvm.page_size) u8,
    serial: *Serial,
    stop: *const std.atomic.Value(bool),
    schedule: *Stream,
) void {
    const vcpus: [3]kvm.Vcpu = @splat(.{ .fd = -1, .run_area = memory });

    assert(memory.len >= kvm.page_size);

    machine.* = .{
        .block = null,
        .memory = memory,
        .pmu = null,
        .schedule = schedule,
        .serial = serial,
        .stop = stop,
    };

    machine.cpus_attach(&vcpus, 0);

    for (machine.cpus[1..vcpus.len]) |*cpu| cpu.startup = false;

    assert(machine.smp());
}
