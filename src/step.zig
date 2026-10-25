const std = @import("std");

const boot = @import("boot.zig");
const kvm = @import("kvm.zig");

const assert = std.debug.assert;

pub const Error = error{
    StepModeUnsupported,
    StepOvershoot,
    StepUnsupported,
} || kvm.Error;

pub const Instruction = struct {
    kind: Kind = .other,
    length: u8 = 0,
    vector: u8 = 0,
};

pub const Kind = enum {
    far_transfer,
    int1,
    iret,
    mov_cr3,
    mov_ss,
    other,
    pushf,
    software_interrupt,
    sysenter,
    sysret,
    sysret_compat,
};

pub const Stepper = struct {
    branches: u64 = 0,
    cr3: u64 = 0,
    entry_exception: u64,
    entry_syscall: ?u64 = null,
    handler: ?u64 = null,
    idt_base: u64 = 0,
    pushf_end: ?u64 = null,
    registers_stale: bool = false,
    return_target: ?u64 = null,
    rip: u64 = 0,

    fn arrive(stepper: *Stepper, vcpu: kvm.Vcpu, memory: []u8) Error!void {
        const rip = stepper.rip;
        const handler_entered = stepper.handler == rip;
        const pushf_done = stepper.pushf_end == rip;
        const syscall_entered = stepper.entry_syscall == rip;
        const exception_entered = stepper.entry_exception == rip;

        stepper.handler = null;
        stepper.pushf_end = null;
        stepper.return_target = null;

        if (stepper.registers_stale) try stepper.sregs_refresh(vcpu);

        const scrubbing = handler_entered or pushf_done or syscall_entered or exception_entered;
        if (!scrubbing) return;

        var regs: kvm.Regs = undefined;

        try vcpu.regs_get(&regs);

        assert(regs.rip == rip);

        if (pushf_done) try stepper.flags_scrub(memory, regs.rsp);
        if (handler_entered) try stepper.flags_scrub(memory, regs.rsp + frame_flags_handler);
        if (exception_entered) try stepper.flags_scrub(memory, regs.rsp + frame_flags_entry);

        if (!syscall_entered) return;
        if (regs.r11 & flags_trap == 0) return;

        regs.r11 &= ~flags_trap;

        try vcpu.regs_set(&regs);
    }

    fn flags_scrub(stepper: *const Stepper, memory: []u8, address: u64) Error!void {
        assert(stepper.cr3 != 0);
        assert(flags_trap >> (flags_trap_byte * 8) == flags_trap_bit);

        const physical = boot.translate(memory, stepper.cr3, address + flags_trap_byte) orelse {
            std.log.err("no page under the flags image at {x} stepping {x}", .{
                address,
                stepper.rip,
            });

            return error.StepUnsupported;
        };

        memory[physical] &= ~flags_trap_bit;
    }

    fn gate_target(stepper: *const Stepper, memory: []const u8, vector: u8) ?u64 {
        assert(stepper.cr3 != 0);

        const address = stepper.idt_base + @as(u64, vector) * gate_size;
        const low = boot.translate(memory, stepper.cr3, address) orelse return null;
        const high = boot.translate(memory, stepper.cr3, address + 8) orelse return null;
        const descriptor = std.mem.readInt(u64, memory[low..][0..8], .little);
        const offset_high = std.mem.readInt(u32, memory[high..][0..4], .little);

        assert(gate_size == 16);

        if (descriptor & gate_present == 0) return null;

        const offset_low = descriptor & 0xffff;
        const offset_middle = (descriptor >> 48) & 0xffff;

        return @as(u64, offset_high) << 32 | offset_middle << 16 | offset_low;
    }

    fn mode_unsupported(stepper: *const Stepper) Error {
        std.log.err("stepping reached a segment outside 64-bit mode at {x}", .{stepper.rip});

        return error.StepModeUnsupported;
    }

    fn prepare(stepper: *Stepper, vcpu: kvm.Vcpu, memory: []const u8) Error!void {
        assert(stepper.handler == null);
        assert(stepper.pushf_end == null);

        var code: [instruction_length_max]u8 = undefined;
        const instruction = decode(code_read(memory, stepper.cr3, stepper.rip, &code));

        if (instruction.kind != .mov_ss) {
            return stepper.prepare_instruction(vcpu, memory, stepper.rip, instruction);
        }

        const shadowed = stepper.rip + instruction.length;
        const next = decode(code_read(memory, stepper.cr3, shadowed, &code));

        return stepper.prepare_instruction(vcpu, memory, shadowed, next);
    }

    fn prepare_instruction(
        stepper: *Stepper,
        vcpu: kvm.Vcpu,
        memory: []const u8,
        rip: u64,
        instruction: Instruction,
    ) Error!void {
        assert(stepper.return_target == null);
        assert(!stepper.registers_stale);

        switch (instruction.kind) {
            .other => {},
            .far_transfer, .iret, .mov_cr3 => stepper.registers_stale = true,
            .pushf => stepper.pushf_end = rip + instruction.length,
            .software_interrupt => {
                stepper.handler = stepper.gate_target(memory, instruction.vector);
            },
            .sysret => {
                var regs: kvm.Regs = undefined;

                try vcpu.regs_get(&regs);

                if (regs.rcx == 0) {
                    std.log.err("sysret at {x} returns to address zero", .{rip});

                    return error.StepUnsupported;
                }

                stepper.return_target = regs.rcx;
            },
            .int1, .mov_ss, .sysenter, .sysret_compat => {
                std.log.err("stepping cannot hide the trap flag across {t} at {x}", .{
                    instruction.kind,
                    rip,
                });

                return error.StepUnsupported;
            },
        }
    }

    fn sregs_refresh(stepper: *Stepper, vcpu: kvm.Vcpu) Error!void {
        var sregs: kvm.Sregs = undefined;

        try vcpu.sregs_get(&sregs);

        if (sregs.efer & efer_long_mode_active == 0) return stepper.mode_unsupported();
        if (sregs.cs.l == 0) return stepper.mode_unsupported();

        stepper.cr3 = sregs.cr3;
        stepper.idt_base = sregs.idt.base;
        stepper.registers_stale = false;

        assert(stepper.cr3 != 0);
    }

    pub fn begin(stepper: *Stepper, vcpu: kvm.Vcpu, memory: []u8, branches: u64) Error!void {
        assert(stepper.entry_exception != 0);

        const entry_exception = stepper.entry_exception;
        var lstar = [1]kvm.MsrEntry{.{ .index = kvm.msr_lstar, .reserved = 0, .data = 0 }};
        var regs: kvm.Regs = undefined;

        try vcpu.regs_get(&regs);

        if (try vcpu.msrs_get(&lstar) != lstar.len) return error.StepUnsupported;

        stepper.* = .{
            .branches = branches,
            .entry_exception = entry_exception,
            .entry_syscall = if (lstar[0].data != 0) lstar[0].data else null,
            .registers_stale = true,
            .rip = regs.rip,
        };

        try stepper.arrive(vcpu, memory);

        assert(stepper.cr3 != 0);

        try stepper.prepare(vcpu, memory);
    }

    pub fn breakpoints(stepper: *const Stepper) kvm.Breakpoints {
        assert(stepper.return_target == null or stepper.handler == null);
        assert(stepper.entry_exception != 0);

        var slots: kvm.Breakpoints = .{
            stepper.entry_exception,
            stepper.entry_syscall,
            stepper.return_target orelse stepper.handler,
            null,
        };

        for (&slots) |*slot| {
            const address = slot.* orelse continue;

            if (address == stepper.rip) slot.* = null;
        }

        return slots;
    }

    pub fn observe(
        stepper: *Stepper,
        vcpu: kvm.Vcpu,
        memory: []u8,
        pc: ?u64,
        branches: u64,
    ) Error!void {
        assert(branches >= stepper.branches);

        if (branches - stepper.branches > step_branches_max) {
            std.log.err("a step from {x} retired {d} conditional branches", .{
                stepper.rip,
                branches - stepper.branches,
            });

            return error.StepOvershoot;
        }

        stepper.branches = branches;

        if (pc) |address| {
            stepper.rip = address;
        } else {
            var regs: kvm.Regs = undefined;

            try vcpu.regs_get(&regs);
            stepper.rip = regs.rip;
        }

        try stepper.arrive(vcpu, memory);
        try stepper.prepare(vcpu, memory);
    }
};

pub const exception_entry_symbol = "error_entry";
const efer_long_mode_active = 0x400;
const flags_trap: u64 = 0x100;
const flags_trap_bit: u8 = 0x1;
const flags_trap_byte = 1;
const frame_flags_entry = 32;
const frame_flags_handler = 16;
const gate_present: u64 = 1 << 47;
const gate_size = 16;
const instruction_length_max = 15;
const modrm_register_cr3 = 3;
const modrm_register_far_call = 3;
const modrm_register_far_jump = 5;
const modrm_register_ss = 2;
const step_branches_max = 1;

fn code_read(
    memory: []const u8,
    cr3: u64,
    address: u64,
    buffer: *[instruction_length_max]u8,
) []const u8 {
    assert(cr3 != 0);

    for (buffer, 0..) |*byte, index| {
        const physical = boot.translate(memory, cr3, address +% index) orelse {
            return buffer[0..index];
        };

        byte.* = memory[physical];
    }

    assert(buffer.len == instruction_length_max);

    return buffer;
}

fn decode_group_five(operand: []const u8, length: u8) Instruction {
    assert(length > 0);

    if (operand.len == 0) return .{};

    const register = (operand[0] >> 3) & 0x7;

    switch (register) {
        modrm_register_far_call, modrm_register_far_jump => {},
        else => return .{},
    }

    const operand_length = modrm_length(operand) orelse return .{};
    return .{ .kind = .far_transfer, .length = length + operand_length };
}

fn decode_mov_segment(operand: []const u8, length: u8) Instruction {
    assert(length > 0);

    if (operand.len == 0) return .{};
    if ((operand[0] >> 3) & 0x7 != modrm_register_ss) return .{};

    const operand_length = modrm_length(operand) orelse return .{};
    return .{ .kind = .mov_ss, .length = length + operand_length };
}

fn decode_two_byte(operand: []const u8, length: u8, rex_w: bool) Instruction {
    assert(length > 0);

    if (operand.len == 0) return .{};

    return switch (operand[0]) {
        0x07 => .{ .kind = if (rex_w) .sysret else .sysret_compat, .length = length + 1 },
        0x22 => {
            if (operand.len < 2) return .{};
            if ((operand[1] >> 3) & 0x7 != modrm_register_cr3) return .{};
            return .{ .kind = .mov_cr3, .length = length + 2 };
        },
        0x34 => .{ .kind = .sysenter, .length = length + 1 },
        else => .{},
    };
}

fn modrm_length(operand: []const u8) ?u8 {
    assert(operand.len <= instruction_length_max);

    if (operand.len == 0) return null;

    const modrm = operand[0];
    const mode = modrm >> 6;
    const memory_register = modrm & 0x7;
    var length: u8 = 1;
    if (mode == 3) return length;

    if (memory_register == 4) {
        if (operand.len < 2) return null;

        length += 1;

        if (mode == 0) {
            if (operand[1] & 0x7 == 5) length += 4;
        }
    }

    if (memory_register == 5) {
        if (mode == 0) length += 4;
    }

    if (mode == 1) length += 1;
    if (mode == 2) length += 4;

    assert(length <= 7);

    return length;
}

fn prefix_legacy(byte: u8) bool {
    return switch (byte) {
        0x26, 0x2e, 0x36, 0x3e, 0x64, 0x65, 0x66, 0x67, 0xf0, 0xf2, 0xf3 => true,
        else => false,
    };
}

pub fn decode(code: []const u8) Instruction {
    assert(code.len <= instruction_length_max);

    var index: usize = 0;
    var rex_w = false;

    while (index < code.len) : (index += 1) {
        const byte = code[index];

        if (prefix_legacy(byte)) {
            rex_w = false;

            continue;
        }

        if (byte & 0xf0 != 0x40) break;

        rex_w = byte & 0x08 != 0;
    }

    if (index >= code.len) return .{};

    const length: u8 = @intCast(index + 1);
    const operand = code[index + 1 ..];

    return switch (code[index]) {
        0x0f => decode_two_byte(operand, length, rex_w),
        0x8e => decode_mov_segment(operand, length),
        0x9c => .{ .kind = .pushf, .length = length },
        0xca => {
            if (operand.len < 2) return .{};
            return .{ .kind = .far_transfer, .length = length + 2 };
        },
        0xcb => .{ .kind = .far_transfer, .length = length },
        0xcc => .{ .kind = .software_interrupt, .length = length, .vector = 3 },
        0xcd => {
            if (operand.len == 0) return .{};
            return .{ .kind = .software_interrupt, .length = length + 1, .vector = operand[0] };
        },
        0xcf => .{ .kind = .iret, .length = length },
        0xf1 => .{ .kind = .int1, .length = length },
        0xff => decode_group_five(operand, length),
        else => .{},
    };
}

test "decode classifies the instructions that read or load the trap flag" {
    const cases = [_]struct { code: []const u8, kind: Kind, length: u8 }{
        .{ .code = &.{0x9c}, .kind = .pushf, .length = 1 },
        .{ .code = &.{ 0x66, 0x9c }, .kind = .pushf, .length = 2 },
        .{ .code = &.{ 0x41, 0x9c }, .kind = .pushf, .length = 2 },
        .{ .code = &.{0x9d}, .kind = .other, .length = 0 },
        .{ .code = &.{ 0x48, 0xcf }, .kind = .iret, .length = 2 },
        .{ .code = &.{ 0x48, 0x0f, 0x07 }, .kind = .sysret, .length = 3 },
        .{ .code = &.{ 0x0f, 0x07 }, .kind = .sysret_compat, .length = 2 },
        .{ .code = &.{ 0x48, 0x66, 0x0f, 0x07 }, .kind = .sysret_compat, .length = 4 },
        .{ .code = &.{ 0x0f, 0x05 }, .kind = .other, .length = 0 },
        .{ .code = &.{ 0x0f, 0x34 }, .kind = .sysenter, .length = 2 },
        .{ .code = &.{0xcc}, .kind = .software_interrupt, .length = 1 },
        .{ .code = &.{ 0xcd, 0x80 }, .kind = .software_interrupt, .length = 2 },
        .{ .code = &.{0xcd}, .kind = .other, .length = 0 },
        .{ .code = &.{0xf1}, .kind = .int1, .length = 1 },
        .{ .code = &.{ 0x8e, 0xd0 }, .kind = .mov_ss, .length = 2 },
        .{ .code = &.{ 0x8e, 0x54, 0x24, 0x08 }, .kind = .mov_ss, .length = 4 },
        .{ .code = &.{ 0x8e, 0x15, 0, 0, 0, 0 }, .kind = .mov_ss, .length = 6 },
        .{ .code = &.{ 0x8e, 0x14, 0x25, 0, 0x10, 0, 0 }, .kind = .mov_ss, .length = 7 },
        .{ .code = &.{ 0x8e, 0x5c, 0x24, 0x08 }, .kind = .other, .length = 0 },
        .{ .code = &.{ 0x0f, 0x22, 0xd8 }, .kind = .mov_cr3, .length = 3 },
        .{ .code = &.{ 0x0f, 0x22, 0xe0 }, .kind = .other, .length = 0 },
        .{ .code = &.{ 0xff, 0x1c, 0x24 }, .kind = .far_transfer, .length = 3 },
        .{ .code = &.{ 0x48, 0xff, 0x6c, 0x24, 0x08 }, .kind = .far_transfer, .length = 5 },
        .{ .code = &.{ 0xff, 0xd0 }, .kind = .other, .length = 0 },
        .{ .code = &.{ 0xca, 0x08, 0x00 }, .kind = .far_transfer, .length = 3 },
        .{ .code = &.{0xcb}, .kind = .far_transfer, .length = 1 },
        .{ .code = &.{ 0xf3, 0x0f, 0x1e, 0xfa }, .kind = .other, .length = 0 },
        .{ .code = &.{ 0xc4, 0xe2, 0x79, 0x18, 0x06 }, .kind = .other, .length = 0 },
        .{ .code = &.{ 0x66, 0x66, 0x2e }, .kind = .other, .length = 0 },
        .{ .code = &.{}, .kind = .other, .length = 0 },
    };

    for (cases) |case| {
        const instruction = decode(case.code);

        try std.testing.expectEqual(case.kind, instruction.kind);
        try std.testing.expectEqual(case.length, instruction.length);
    }

    try std.testing.expectEqual(@as(u8, 0x80), decode(&.{ 0xcd, 0x80 }).vector);
    try std.testing.expectEqual(@as(u8, 3), decode(&.{0xcc}).vector);
}

test "breakpoints never sit on the instruction about to run" {
    var stepper: Stepper = .{ .entry_exception = 0x1000, .entry_syscall = 0x2000, .rip = 0x1000 };

    try std.testing.expectEqual(kvm.Breakpoints{ null, 0x2000, null, null }, stepper.breakpoints());

    stepper.rip = 0x3000;
    stepper.return_target = 0x4000;

    try std.testing.expectEqual(
        kvm.Breakpoints{ 0x1000, 0x2000, 0x4000, null },
        stepper.breakpoints(),
    );

    stepper.rip = 0x4000;

    const at_return: kvm.Breakpoints = .{ 0x1000, 0x2000, null, null };

    try std.testing.expectEqual(at_return, stepper.breakpoints());
}

test "stepping that starts or stops anywhere leaves the guest as an unstepped run left it" {
    const handle = try kvm.Kvm.open();
    defer handle.close();

    const cpuid = try std.testing.allocator.create(kvm.Cpuid2);
    defer std.testing.allocator.destroy(cpuid);

    try handle.cpuid_supported(cpuid);

    var reference: TestState = undefined;
    var full: TestState = undefined;

    try test_run(handle, cpuid, .{}, &reference);
    try test_run(handle, cpuid, .{ .start = test_program.entry }, &full);

    try std.testing.expectEqual(@as(u32, 0), reference.steps);
    try std.testing.expect(full.steps > test_program.count);
    try std.testing.expectEqual(test_program.final, full.trace[full.steps - 1]);
    try test_state_expect(&reference, &full);

    const boundaries = [_]u64{
        test_program.common,
        test_program.stub_breakpoint,
        test_program.stub_software,
        test_program.syscall_entry,
        test_program.syscall_return,
    };

    const trace = full.trace[0..full.steps];

    for (boundaries) |boundary| {
        try std.testing.expect(std.mem.findScalar(u64, trace, boundary) != null);
    }

    for (1..full.steps) |stop| {
        var state: TestState = undefined;

        try test_run(handle, cpuid, .{ .start = test_program.entry, .stop = stop }, &state);
        try test_state_expect(&reference, &state);
        try std.testing.expectEqual(stop, state.steps);
    }

    for (test_program.starts[0..test_program.count]) |start| {
        var state: TestState = undefined;

        const stepped = switch (start) {
            test_program.after_fault,
            test_program.after_trap,
            test_program.final,
            test_program.shadowed,
            => false,
            else => true,
        };

        try test_run(handle, cpuid, .{ .start = start }, &state);
        try test_state_expect(&reference, &state);
        try std.testing.expectEqual(stepped, state.steps > 0);
    }
}

const TestOptions = struct {
    start: ?u64 = null,
    stop: ?usize = null,
};

const TestProgram = struct {
    address: u64 = test_code,
    after_fault: u64 = 0,
    after_trap: u64 = 0,
    common: u64 = 0,
    count: u32 = 0,
    entry: u64 = 0,
    final: u64 = 0,
    image: [test_code_size]u8 = @splat(0),
    shadowed: u64 = 0,
    starts: [test_instructions_max]u64 = undefined,
    stub_breakpoint: u64 = 0,
    stub_general_protection: u64 = 0,
    stub_invalid_opcode: u64 = 0,
    stub_page_fault: u64 = 0,
    stub_software: u64 = 0,
    syscall_entry: u64 = 0,
    syscall_return: u64 = 0,
    user_code: u64 = 0,

    fn emit(program: *TestProgram, bytes: []const u8) void {
        assert(program.count < test_instructions_max);
        assert(program.address + bytes.len <= test_code + test_code_size);

        const offset = program.address - test_code;

        @memcpy(program.image[offset..][0..bytes.len], bytes);

        program.starts[program.count] = program.address;
        program.count += 1;
        program.address += bytes.len;
    }

    fn emit_call(program: *TestProgram, target: u64) void {
        const next: i64 = @intCast(program.address + 5);
        const relative: i32 = @intCast(@as(i64, @intCast(target)) - next);
        var bytes: [5]u8 = .{ 0xe8, 0, 0, 0, 0 };

        std.mem.writeInt(i32, bytes[1..5], relative, .little);
        program.emit(&bytes);
    }

    fn emit_load_rbx(program: *TestProgram, value: u32) void {
        var bytes: [7]u8 = .{ 0x48, 0xc7, 0xc3, 0, 0, 0, 0 };

        std.mem.writeInt(u32, bytes[3..7], value, .little);
        program.emit(&bytes);
    }

    fn emit_push(program: *TestProgram, value: u32) void {
        var bytes: [5]u8 = .{ 0x68, 0, 0, 0, 0 };

        std.mem.writeInt(u32, bytes[1..5], value, .little);
        program.emit(&bytes);
    }

    fn emit_store_flags(program: *TestProgram, slot: u64) void {
        program.emit(&test_instruction.pushf);
        program.emit(&test_instruction.pop_rax);
        program.emit_store_rax(slot);
    }

    fn emit_store_rax(program: *TestProgram, slot: u64) void {
        var bytes: [10]u8 = .{ 0x48, 0xa3, 0, 0, 0, 0, 0, 0, 0, 0 };

        std.mem.writeInt(u64, bytes[2..10], slot, .little);
        program.emit(&bytes);
    }
};

const TestState = struct {
    memory_hash: u64,
    regs: kvm.Regs,
    steps: u32,
    trace: [test_steps_max]u64,
};

const test_instruction = struct {
    const add_rsp_8 = [_]u8{ 0x48, 0x83, 0xc4, 0x08 };
    const advance_return_2 = [_]u8{ 0x48, 0x83, 0x44, 0x24, 0x08, 0x02 };
    const cli = [_]u8{0xfa};
    const halt = [_]u8{0xf4};
    const int3 = [_]u8{0xcc};
    const int_software = [_]u8{ 0xcd, test_vector_software };
    const iretq = [_]u8{ 0x48, 0xcf };
    const load_byte_rbx = [_]u8{ 0x8a, 0x03 };
    const mov_ax_ss = [_]u8{ 0x8e, 0xd0 };
    const mov_r11_rax = [_]u8{ 0x4c, 0x89, 0xd8 };
    const mov_ss_ax = [_]u8{ 0x66, 0x8c, 0xd0 };
    const nop = [_]u8{0x90};
    const pop_rax = [_]u8{0x58};
    const push_minus_one = [_]u8{ 0x6a, 0xff };
    const pushf = [_]u8{0x9c};
    const ret = [_]u8{0xc3};
    const sti = [_]u8{0xfb};
    const syscall = [_]u8{ 0x0f, 0x05 };
    const sysretq = [_]u8{ 0x48, 0x0f, 0x07 };
    const ud2 = [_]u8{ 0x0f, 0x0b };
};

const test_code = 0x10000;
const test_code_size = 0x400;
const test_cr0 = 0x80050033;
const test_cr4 = 0x20;
const test_descriptor_kernel_code = 0x00af9b000000ffff;
const test_descriptor_kernel_data = 0x00cf93000000ffff;
const test_descriptor_user_code = 0x00affb000000ffff;
const test_descriptor_user_data = 0x00cff3000000ffff;
const test_efer = 0x501;
const test_exits_max = 4096;
const test_flags_user = 0x202;
const test_gdt = 0x4000;
const test_idt = 0x5000;
const test_instructions_max = 128;
const test_memory_size = 4 << 20;
const test_msr_star = 0xc0000081;
const test_msr_syscall_mask = 0xc0000084;
const test_page_directory = 0x3000;
const test_page_directory_pointer = 0x2000;
const test_page_map = 0x1000;
const test_selector_kernel_code = 0x08;
const test_selector_kernel_data = 0x10;
const test_selector_tss = 0x28;
const test_selector_user_code = 0x23;
const test_selector_user_data = 0x1b;
const test_slot_kernel = 0x20000;
const test_slot_shadow = 0x20008;
const test_slot_syscall = 0x20010;
const test_slot_user = 0x20018;
const test_stack_interrupt = 0x80000;
const test_stack_kernel = 0x70000;
const test_stack_user = 0x60000;
const test_star = 0x0010_0008_0000_0000;
const test_steps_max = 256;
const test_syscall_mask = 0x257700;
const test_tss = 0x6000;
const test_unmapped = 0x800000;
const test_vector_breakpoint = 3;
const test_vector_general_protection = 13;
const test_vector_invalid_opcode = 6;
const test_vector_page_fault = 14;
const test_vector_software = 0x81;

const test_program: TestProgram = blk: {
    @setEvalBranchQuota(100_000);

    var program: TestProgram = .{};

    test_program_handlers(&program);
    test_program_user(&program);
    test_program_kernel(&program);

    break :blk program;
};

fn test_gate_write(memory: []u8, vector: u8, handler: u64, user: bool) void {
    assert(handler != 0);
    assert(handler < test_memory_size);

    const attributes: u64 = if (user) 0xee else 0x8e;
    var low: u64 = handler & 0xffff;

    low |= test_selector_kernel_code << 16;
    low |= attributes << 40;
    low |= ((handler >> 16) & 0xffff) << 48;

    const offset = test_idt + @as(usize, vector) * gate_size;

    std.mem.writeInt(u64, memory[offset..][0..8], low, .little);
    std.mem.writeInt(u64, memory[offset + 8 ..][0..8], handler >> 32, .little);
}

fn test_program_handlers(program: *TestProgram) void {
    program.common = program.address;

    program.emit(&test_instruction.ret);

    program.stub_invalid_opcode = program.address;

    program.emit(&test_instruction.push_minus_one);
    program.emit_call(program.common);
    program.emit(&test_instruction.advance_return_2);
    program.emit(&test_instruction.add_rsp_8);
    program.emit(&test_instruction.iretq);

    program.stub_breakpoint = program.address;

    program.emit(&test_instruction.push_minus_one);
    program.emit_call(program.common);
    program.emit(&test_instruction.add_rsp_8);
    program.emit(&test_instruction.iretq);

    program.stub_software = program.address;

    program.emit(&test_instruction.push_minus_one);
    program.emit_call(program.common);
    program.emit(&test_instruction.add_rsp_8);
    program.emit(&test_instruction.iretq);

    program.stub_page_fault = program.address;

    program.emit_call(program.common);
    program.emit(&test_instruction.advance_return_2);
    program.emit(&test_instruction.add_rsp_8);
    program.emit(&test_instruction.iretq);

    program.stub_general_protection = program.address;

    program.emit_call(program.common);
    program.final = program.address;

    program.emit(&test_instruction.halt);

    program.syscall_entry = program.address;

    program.emit(&test_instruction.mov_r11_rax);
    program.emit_store_rax(test_slot_syscall);
    program.emit(&test_instruction.sysretq);
}

fn test_program_kernel(program: *TestProgram) void {
    program.entry = program.address;

    program.emit_store_flags(test_slot_kernel);
    program.emit(&test_instruction.ud2);
    program.after_trap = program.address;

    program.emit(&test_instruction.int3);
    program.emit(&test_instruction.int_software);
    program.emit(&test_instruction.mov_ss_ax);
    program.emit(&test_instruction.mov_ax_ss);
    program.shadowed = program.address;

    program.emit_store_flags(test_slot_shadow);
    program.emit(&test_instruction.sti);
    program.emit(&test_instruction.nop);
    program.emit(&test_instruction.cli);
    program.emit_push(test_selector_user_data);
    program.emit_push(test_stack_user);
    program.emit_push(test_flags_user);
    program.emit_push(test_selector_user_code);
    program.emit_push(@intCast(program.user_code));
    program.emit(&test_instruction.iretq);
}

fn test_program_user(program: *TestProgram) void {
    program.user_code = program.address;

    program.emit_store_flags(test_slot_user);
    program.emit(&test_instruction.syscall);
    program.syscall_return = program.address;

    program.emit_load_rbx(test_unmapped);
    program.emit(&test_instruction.load_byte_rbx);
    program.after_fault = program.address;

    program.emit(&test_instruction.int_software);
    program.emit(&test_instruction.halt);
}

fn test_run(
    handle: kvm.Kvm,
    cpuid: *const kvm.Cpuid2,
    options: TestOptions,
    state: *TestState,
) !void {
    const vm = try handle.vm_create();
    defer vm.close();

    const memory = try kvm.guest_memory_alloc(test_memory_size);
    defer kvm.guest_memory_free(memory);

    try vm.memory_region_set(0, 0, memory);

    const vcpu = try vm.vcpu_create(0);
    defer vcpu.close();

    test_tables_write(memory);
    try test_vcpu_setup(vcpu, cpuid);

    var stepper: Stepper = .{ .entry_exception = test_program.common };
    var start = options.start;
    var stepping = false;

    state.steps = 0;

    for (0..test_exits_max) |_| {
        const idle: kvm.Breakpoints = .{ start, null, null, null };
        const breakpoints = if (stepping) stepper.breakpoints() else idle;

        try vcpu.guest_debug_set(stepping, &breakpoints);

        const area = try vcpu.run();

        if (area.exit_reason == .hlt) {
            try vcpu.regs_get(&state.regs);
            state.memory_hash = std.hash.Wyhash.hash(0, memory);

            return;
        }

        if (area.exit_reason != .debug) return error.UnexpectedExit;

        if (!stepping) {
            if (area.exit.debug.pc != start) return error.UnexpectedDebugExit;

            start = null;
            stepping = true;

            try stepper.begin(vcpu, memory, 0);

            continue;
        }

        if (state.steps == test_steps_max) return error.TooManySteps;

        try stepper.observe(vcpu, memory, area.exit.debug.pc, 0);
        state.trace[state.steps] = area.exit.debug.pc;
        state.steps += 1;

        if (options.stop) |stop| {
            if (state.steps == stop) stepping = false;
        }
    }

    return error.ProgramDidNotHalt;
}

fn test_segment(selector: u16, segment_type: u8, privilege: u8, long: u8) kvm.Segment {
    assert(segment_type <= 0xf);
    assert(privilege <= 3);

    return .{
        .base = 0,
        .limit = 0xffffffff,
        .selector = selector,
        .type = segment_type,
        .present = 1,
        .dpl = privilege,
        .db = if (long == 1) 0 else 1,
        .s = 1,
        .l = long,
        .g = 1,
        .avl = 0,
        .unusable = 0,
        .padding = 0,
    };
}

fn test_state_expect(reference: *const TestState, state: *const TestState) !void {
    assert(reference.steps == 0);

    try std.testing.expectEqual(reference.regs, state.regs);
    try std.testing.expectEqual(reference.memory_hash, state.memory_hash);
}

fn test_tables_write(memory: []u8) void {
    assert(memory.len == test_memory_size);
    assert(test_code + test_code_size <= test_slot_kernel);

    const pages: u64 = 0x87;
    const tables: u64 = 0x7;
    const tss_descriptor: u64 = 0x67 | (test_tss << 16) | (0x89 << 40);
    const directory_pointer = test_page_directory_pointer | tables;
    const directory = test_page_directory | tables;

    std.mem.writeInt(u64, memory[test_page_map..][0..8], directory_pointer, .little);
    std.mem.writeInt(u64, memory[test_page_directory_pointer..][0..8], directory, .little);

    for (0..test_memory_size >> 21) |index| {
        const entry = test_page_directory + index * 8;

        std.mem.writeInt(u64, memory[entry..][0..8], (index << 21) | pages, .little);
    }

    const descriptors = [_]u64{
        0,
        test_descriptor_kernel_code,
        test_descriptor_kernel_data,
        test_descriptor_user_data,
        test_descriptor_user_code,
        tss_descriptor,
    };

    for (descriptors, 0..) |descriptor, index| {
        std.mem.writeInt(u64, memory[test_gdt + index * 8 ..][0..8], descriptor, .little);
    }

    std.mem.writeInt(u64, memory[test_tss + 4 ..][0..8], test_stack_interrupt, .little);

    const program = &test_program;

    test_gate_write(memory, test_vector_breakpoint, program.stub_breakpoint, true);
    test_gate_write(memory, test_vector_general_protection, program.stub_general_protection, false);
    test_gate_write(memory, test_vector_invalid_opcode, program.stub_invalid_opcode, false);
    test_gate_write(memory, test_vector_page_fault, program.stub_page_fault, false);
    test_gate_write(memory, test_vector_software, program.stub_software, true);

    @memcpy(memory[test_code..][0..test_code_size], &program.image);
}

fn test_vcpu_setup(vcpu: kvm.Vcpu, cpuid: *const kvm.Cpuid2) !void {
    assert(test_program.entry != 0);
    assert(test_program.syscall_entry != 0);

    var sregs: kvm.Sregs = undefined;

    try vcpu.cpuid_set(cpuid);
    try vcpu.sregs_get(&sregs);

    sregs.cs = test_segment(test_selector_kernel_code, 0xb, 0, 1);
    sregs.ds = test_segment(test_selector_kernel_data, 0x3, 0, 0);
    sregs.es = sregs.ds;
    sregs.fs = sregs.ds;
    sregs.gs = sregs.ds;
    sregs.ss = sregs.ds;
    sregs.tr = test_segment(test_selector_tss, 0xb, 0, 0);
    sregs.tr.base = test_tss;
    sregs.tr.limit = 0x67;
    sregs.tr.s = 0;
    sregs.tr.g = 0;
    sregs.ldt.unusable = 1;
    sregs.gdt = .{ .base = test_gdt, .limit = 7 * 8 - 1, .padding = .{ 0, 0, 0 } };
    sregs.idt = .{ .base = test_idt, .limit = 0xfff, .padding = .{ 0, 0, 0 } };
    sregs.cr0 = test_cr0;
    sregs.cr3 = test_page_map;
    sregs.cr4 = test_cr4;
    sregs.efer = test_efer;

    try vcpu.sregs_set(&sregs);

    const msrs = [_]kvm.MsrEntry{
        .{ .index = test_msr_star, .reserved = 0, .data = test_star },
        .{ .index = kvm.msr_lstar, .reserved = 0, .data = test_program.syscall_entry },
        .{ .index = test_msr_syscall_mask, .reserved = 0, .data = test_syscall_mask },
    };

    if (try vcpu.msrs_set(&msrs) != msrs.len) return error.MsrRefused;

    var regs = std.mem.zeroes(kvm.Regs);

    regs.rip = test_program.entry;
    regs.rsp = test_stack_kernel;
    regs.rflags = 0x2;

    try vcpu.regs_set(&regs);
}
