const std = @import("std");

const kvm = @import("kvm.zig");

const assert = std.debug.assert;

pub const Error = error{MsrRefused} || kvm.Error;

pub const ForkPoint = struct {
    branches: u64 = 0,
    cpu_branches: [vcpus_max]u64 = @splat(0),
    exits: u64 = 0,
};

pub const VcpuState = struct {
    debugregs: kvm.Debugregs,
    events: kvm.VcpuEvents,
    msrs: [kvm.msrs_max]kvm.MsrEntry,
    msrs_count: u32,
    ready_for_interrupt_injection: u8,
    regs: kvm.Regs,
    request_interrupt_window: u8,
    sregs: kvm.Sregs,
    xcrs: kvm.Xcrs,
    xsave: kvm.Xsave,
};

pub const VcpuStates = struct {
    count: u32 = 0,
    states: [vcpus_max]VcpuState = undefined,

    pub fn apply_all(states: *const VcpuStates, vcpus: []const kvm.Vcpu) Error!void {
        assert(states.count > 0);
        assert(vcpus.len == states.count);

        for (vcpus, states.states[0..states.count]) |vcpu, *state| try apply(vcpu, state);
    }

    pub fn capture_all(
        states: *VcpuStates,
        vcpus: []const kvm.Vcpu,
        msr_list: *const kvm.MsrList,
    ) Error!void {
        assert(vcpus.len > 0);
        assert(vcpus.len <= vcpus_max);

        for (vcpus, states.states[0..vcpus.len]) |vcpu, *state| try capture(vcpu, msr_list, state);

        states.count = @intCast(vcpus.len);
    }
};

pub const vcpus_max = 8;

fn msr_round_trips(vcpu: kvm.Vcpu, index: u32) kvm.Error!bool {
    var entry = [1]kvm.MsrEntry{.{ .index = index, .reserved = 0, .data = 0 }};
    if (try vcpu.msrs_get(&entry) != 1) return false;
    return try vcpu.msrs_set(&entry) == 1;
}

pub fn apply(vcpu: kvm.Vcpu, state: *const VcpuState) Error!void {
    assert(state.msrs_count > 0);
    assert(state.msrs_count <= kvm.msrs_max);
    assert(state.regs.rflags & 0x2 != 0);

    const msrs = state.msrs[0..state.msrs_count];
    var events = state.events;
    events.flags |= kvm.vcpu_events_valid_nmi_pending;

    try vcpu.regs_set(&state.regs);
    try vcpu.sregs_set(&state.sregs);
    try vcpu.xsave_set(&state.xsave);
    try vcpu.xcrs_set(&state.xcrs);
    try vcpu.debugregs_set(&state.debugregs);

    const written = try vcpu.msrs_set(msrs);

    if (written != msrs.len) {
        std.log.err("KVM refused MSR {x} with {x}", .{ msrs[written].index, msrs[written].data });

        return error.MsrRefused;
    }

    try vcpu.events_set(&events);

    const area = vcpu.run_area_view();

    area.ready_for_interrupt_injection = state.ready_for_interrupt_injection;
    area.request_interrupt_window = state.request_interrupt_window;
}

pub fn capture(vcpu: kvm.Vcpu, msr_list: *const kvm.MsrList, state: *VcpuState) Error!void {
    assert(msr_list.nmsrs > 0);
    assert(msr_list.nmsrs <= kvm.msrs_max);
    assert(vcpu.run_area_view().immediate_exit == 0);

    const msrs = state.msrs[0..msr_list.nmsrs];

    for (msrs, msr_list.indices[0..msr_list.nmsrs]) |*entry, index| {
        entry.* = .{ .index = index, .reserved = 0, .data = 0 };
    }

    state.msrs_count = msr_list.nmsrs;
    state.ready_for_interrupt_injection = vcpu.run_area_view().ready_for_interrupt_injection;
    state.request_interrupt_window = vcpu.run_area_view().request_interrupt_window;

    try vcpu.regs_get(&state.regs);
    try vcpu.sregs_get(&state.sregs);
    try vcpu.xsave_get(&state.xsave);
    try vcpu.xcrs_get(&state.xcrs);
    try vcpu.debugregs_get(&state.debugregs);

    const read = try vcpu.msrs_get(msrs);

    if (read != msrs.len) {
        std.log.err("KVM refused to read MSR {x}", .{msrs[read].index});

        return error.MsrRefused;
    }

    try vcpu.events_get(&state.events);
}

pub fn msrs_probe(vcpu: kvm.Vcpu, msr_list: *kvm.MsrList) kvm.Error!void {
    assert(msr_list.nmsrs > 0);
    assert(msr_list.nmsrs <= kvm.msrs_max);

    var kept: u32 = 0;

    for (msr_list.indices[0..msr_list.nmsrs]) |index| {
        if (!try msr_round_trips(vcpu, index)) continue;

        msr_list.indices[kept] = index;
        kept += 1;
    }

    msr_list.nmsrs = kept;

    assert(kept > 0);
}
