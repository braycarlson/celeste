const std = @import("std");

const assert = std.debug.assert;

pub const Delivery = enum(u3) {
    fixed = 0,
    lowest = 1,
    smi = 2,
    nmi = 4,
    init = 5,
    startup = 6,
    external = 7,
    _,
};

pub const Ipi = struct {
    delivery: Delivery,
    destination: u8,
    level: bool,
    logical: bool,
    shorthand: Shorthand,
    vector: u8,
};

pub const Lapic = struct {
    dfr: u32 = 0xffff_ffff,
    divide: u32 = 0,
    esr: u32 = 0,
    icr_high: u32 = 0,
    icr_low: u32 = 0,
    id: u8,
    irr: [8]u32 = @splat(0),
    isr: [8]u32 = @splat(0),
    ldr: u32 = 0,
    lvt: [lvt_count]u32 = @splat(lvt_masked),
    svr: u32 = 0xff,
    timer_initial: u32 = 0,
    timer_start_ns: u64 = 0,
    tmr: [8]u32 = @splat(0),
    tpr: u32 = 0,

    fn icr_send(lapic: *Lapic, value: u32) Ipi {
        lapic.icr_low = value & ~icr_pending;

        const ipi: Ipi = .{
            .delivery = @fromBackingInt(@intCast(@as(u3, @truncate(value >> 8)))),
            .destination = @truncate(lapic.icr_high >> 24),
            .level = value & (1 << 14) != 0,
            .logical = value & (1 << 11) != 0,
            .shorthand = @fromBackingInt(@intCast(@as(u2, @truncate(value >> 18)))),
            .vector = @truncate(value),
        };

        assert(lapic.icr_low & icr_pending == 0);

        return ipi;
    }

    fn lvt_write(lapic: *Lapic, register: u32, value: u32) void {
        const index = (register - 0x320) >> 4;

        assert(index < lvt_count);

        lapic.lvt[index] = if (lapic.enabled()) value else value | lvt_masked;
    }

    fn ppr(lapic: *const Lapic) u32 {
        const isr = highest(&lapic.isr) orelse 0;
        const tpr_class = lapic.tpr & 0xf0;
        const isr_class = @as(u32, isr) & 0xf0;

        assert(lapic.tpr <= 0xff);

        return if (tpr_class >= isr_class) lapic.tpr & 0xff else isr_class;
    }

    fn timer_period_ns(lapic: *const Lapic) u64 {
        const shift = divide_shift(lapic.divide);

        assert(shift <= 7);
        assert(lapic.timer_initial != 0);

        return @as(u64, lapic.timer_initial) * (timer_tick_ns << shift);
    }

    pub fn accept(lapic: *Lapic, vector: u8, level: bool) void {
        assert(vector >= vector_min);

        set(&lapic.irr, vector);

        if (level) set(&lapic.tmr, vector) else clear(&lapic.tmr, vector);
    }

    pub fn acknowledge(lapic: *Lapic) u8 {
        const vector = lapic.pending() orelse unreachable;

        clear(&lapic.irr, vector);
        set(&lapic.isr, vector);

        assert(test_bit(&lapic.isr, vector));

        return vector;
    }

    pub fn enabled(lapic: *const Lapic) bool {
        return lapic.svr & svr_enable != 0;
    }

    pub fn eoi(lapic: *Lapic) void {
        const vector = highest(&lapic.isr) orelse return;

        clear(&lapic.isr, vector);

        assert(!test_bit(&lapic.isr, vector));
    }

    pub fn extint(lapic: *const Lapic) bool {
        const lint0 = lapic.lvt[lvt_lint0];
        if (lint0 & lvt_masked != 0) return false;
        return @as(u3, @truncate(lint0 >> 8)) == @backingInt(Delivery.external);
    }

    pub fn logical_match(lapic: *const Lapic, destination: u8) bool {
        assert(lapic.dfr | 0x0fff_ffff == lapic.dfr);

        return (lapic.ldr >> 24) & destination != 0;
    }

    pub fn pending(lapic: *const Lapic) ?u8 {
        if (!lapic.enabled()) return null;

        const vector = highest(&lapic.irr) orelse return null;
        if (@as(u32, vector) & 0xf0 <= lapic.ppr() & 0xf0) return null;
        return vector;
    }

    pub fn read(lapic: *const Lapic, offset: u32, now_ns: u64) u32 {
        assert(offset < page_size);

        const register = offset & 0xff0;

        return switch (register) {
            0x020 => @as(u32, lapic.id) << 24,
            0x030 => version,
            0x080 => lapic.tpr,
            0x0a0 => lapic.ppr(),
            0x0d0 => lapic.ldr,
            0x0e0 => lapic.dfr,
            0x0f0 => lapic.svr,
            0x100...0x170 => lapic.isr[(register - 0x100) >> 4],
            0x180...0x1f0 => lapic.tmr[(register - 0x180) >> 4],
            0x200...0x270 => lapic.irr[(register - 0x200) >> 4],
            0x280 => lapic.esr,
            0x300 => lapic.icr_low,
            0x310 => lapic.icr_high,
            0x320...0x370 => lapic.lvt[(register - 0x320) >> 4],
            0x380 => lapic.timer_initial,
            0x390 => lapic.timer_current(now_ns),
            0x3e0 => lapic.divide,
            else => 0,
        };
    }

    pub fn reset(id: u8, bootstrap: bool) Lapic {
        var lapic: Lapic = .{ .id = id };

        if (bootstrap) lapic.lvt[lvt_lint0] = @as(u32, @backingInt(Delivery.external)) << 8;

        assert(lapic.extint() == bootstrap);

        return lapic;
    }

    pub fn timer_current(lapic: *const Lapic, now_ns: u64) u32 {
        if (lapic.timer_initial == 0) return 0;

        assert(now_ns >= lapic.timer_start_ns);

        const tick_ns = timer_tick_ns << divide_shift(lapic.divide);
        const elapsed = (now_ns - lapic.timer_start_ns) / tick_ns;
        if (elapsed >= lapic.timer_initial) return 0;
        return lapic.timer_initial - @as(u32, @intCast(elapsed));
    }

    pub fn timer_expiry_ns(lapic: *const Lapic) ?u64 {
        if (lapic.timer_initial == 0) return null;
        return lapic.timer_start_ns + lapic.timer_period_ns();
    }

    pub fn timer_fire(lapic: *Lapic, now_ns: u64) void {
        const lvt = lapic.lvt[lvt_timer];
        const vector: u8 = @truncate(lvt);
        const expiry = lapic.timer_expiry_ns() orelse unreachable;

        assert(now_ns >= expiry);

        if (lvt & lvt_masked == 0) {
            if (vector >= vector_min) lapic.accept(vector, false);
        }

        if (lapic.timer_periodic()) {
            lapic.timer_start_ns = expiry;
        } else {
            lapic.timer_initial = 0;
            lapic.timer_start_ns = now_ns;
        }
    }

    pub fn timer_periodic(lapic: *const Lapic) bool {
        return (lapic.lvt[lvt_timer] >> 17) & 0b11 == 0b01;
    }

    pub fn write(lapic: *Lapic, offset: u32, value: u32, now_ns: u64) ?Ipi {
        assert(offset < page_size);

        const register = offset & 0xff0;

        switch (register) {
            0x020 => lapic.id = @truncate(value >> 24),
            0x080 => lapic.tpr = value & 0xff,
            0x0b0 => lapic.eoi(),
            0x0d0 => lapic.ldr = value & 0xff00_0000,
            0x0e0 => lapic.dfr = value | 0x0fff_ffff,
            0x0f0 => lapic.svr = value & 0x13ff,
            0x280 => lapic.esr = 0,
            0x300 => return lapic.icr_send(value),
            0x310 => lapic.icr_high = value & 0xff00_0000,
            0x320...0x370 => lapic.lvt_write(register, value),
            0x380 => {
                lapic.timer_initial = value;
                lapic.timer_start_ns = now_ns;
            },
            0x3e0 => lapic.divide = value & 0b1011,
            else => {},
        }

        return null;
    }
};

pub const Shorthand = enum(u2) {
    none = 0,
    self = 1,
    all = 2,
    others = 3,
};

pub const base = 0xfee0_0000;
pub const page_size = 0x1000;
const icr_pending: u32 = 1 << 12;
const lvt_count = 6;
const lvt_lint0 = 3;
const lvt_masked: u32 = 1 << 16;
const lvt_timer = 0;
const svr_enable: u32 = 1 << 8;
const timer_tick_ns: u64 = 10;
const vector_min = 16;
const version: u32 = 0x0005_0014;

comptime {
    assert(lvt_lint0 < lvt_count);
    assert(timer_tick_ns > 0);
}

fn clear(words: *[8]u32, vector: u8) void {
    words[vector >> 5] &= ~(@as(u32, 1) << @intCast(vector & 31));
}

fn divide_shift(divide: u32) u3 {
    const code = (divide & 0b11) | ((divide >> 1) & 0b100);

    assert(code <= 0b111);

    return if (code == 0b111) 0 else @intCast(code + 1);
}

fn highest(words: *const [8]u32) ?u8 {
    var index: usize = words.len;

    while (index > 0) {
        index -= 1;

        if (words[index] != 0) {
            const bit = 31 - @clz(words[index]);
            return @intCast(index * 32 + bit);
        }
    }

    return null;
}

fn set(words: *[8]u32, vector: u8) void {
    words[vector >> 5] |= @as(u32, 1) << @intCast(vector & 31);
}

fn test_bit(words: *const [8]u32, vector: u8) bool {
    return words[vector >> 5] & (@as(u32, 1) << @intCast(vector & 31)) != 0;
}

fn test_enabled() Lapic {
    var lapic: Lapic = .{ .id = 1 };

    _ = lapic.write(0x0f0, svr_enable | 0xff, 0);

    return lapic;
}

test "a higher class preempts, the task priority holds back, and an end of interrupt unmasks" {
    var lapic = test_enabled();

    lapic.accept(0x31, false);
    lapic.accept(0x41, false);

    try std.testing.expectEqual(0x41, lapic.pending());
    try std.testing.expectEqual(0x41, lapic.acknowledge());
    try std.testing.expectEqual(null, lapic.pending());
    try std.testing.expectEqual(0x40, lapic.read(0x0a0, 0));

    _ = lapic.write(0x0b0, 0, 0);

    try std.testing.expectEqual(0x31, lapic.pending());

    _ = lapic.write(0x080, 0x50, 0);

    try std.testing.expectEqual(null, lapic.pending());

    _ = lapic.write(0x080, 0x20, 0);

    try std.testing.expectEqual(0x31, lapic.acknowledge());
    try std.testing.expectEqual(@as(u32, 1) << 0x11, lapic.read(0x110, 0));
}

test "the divide register follows the documented table" {
    const table = [_][2]u32{
        .{ 0b0000, 2 },
        .{ 0b0001, 4 },
        .{ 0b0010, 8 },
        .{ 0b0011, 16 },
        .{ 0b1000, 32 },
        .{ 0b1001, 64 },
        .{ 0b1010, 128 },
        .{ 0b1011, 1 },
    };

    for (table) |row| {
        try std.testing.expectEqual(row[1], @as(u32, 1) << divide_shift(row[0]));
    }
}

test "a one-shot timer counts down once and a periodic timer keeps its phase" {
    var lapic = test_enabled();

    _ = lapic.write(0x3e0, 0b1011, 0);
    _ = lapic.write(0x320, 0x40, 0);
    _ = lapic.write(0x380, 1000, 0);

    try std.testing.expectEqual(500, lapic.timer_current(5_000));
    try std.testing.expectEqual(10_000, lapic.timer_expiry_ns());

    lapic.timer_fire(10_300);

    try std.testing.expectEqual(0x40, lapic.pending());
    try std.testing.expectEqual(null, lapic.timer_expiry_ns());
    try std.testing.expectEqual(0, lapic.timer_current(20_000));

    _ = lapic.write(0x320, 0x50 | 1 << 17, 20_000);
    _ = lapic.write(0x380, 100, 20_000);

    lapic.timer_fire(21_050);

    try std.testing.expectEqual(22_000, lapic.timer_expiry_ns());
    try std.testing.expectEqual(95, lapic.timer_current(21_050));
}

test "an interrupt command decodes init, startup, logical, and shorthand fields" {
    var lapic = test_enabled();

    _ = lapic.write(0x310, 0x02 << 24, 0);

    const init = lapic.write(0x300, 0x0000_c500, 0).?;
    const startup = lapic.write(0x300, 0x0000_069a, 0).?;
    const broadcast = lapic.write(0x300, 0x000c_08fd, 0).?;

    try std.testing.expectEqual(Delivery.init, init.delivery);
    try std.testing.expect(init.level);
    try std.testing.expectEqual(2, init.destination);
    try std.testing.expectEqual(Delivery.startup, startup.delivery);
    try std.testing.expectEqual(0x9a, startup.vector);
    try std.testing.expect(broadcast.logical);
    try std.testing.expectEqual(Shorthand.others, broadcast.shorthand);
    try std.testing.expectEqual(0, lapic.read(0x300, 0) & icr_pending);
}

test "the bootstrap processor resets in virtual wire mode and the others masked" {
    const bootstrap: Lapic = .reset(0, true);
    const other: Lapic = .reset(1, false);

    try std.testing.expect(bootstrap.extint());
    try std.testing.expect(!other.extint());
    try std.testing.expect(!bootstrap.enabled());
    try std.testing.expectEqual(@as(u32, 1) << 24, other.read(0x020, 0));
}

test "a software-disabled apic masks every vector table write and blocks delivery" {
    var lapic: Lapic = .{ .id = 0 };

    _ = lapic.write(0x350, 0x700, 0);

    lapic.accept(0x40, false);

    try std.testing.expect(!lapic.extint());
    try std.testing.expectEqual(null, lapic.pending());

    _ = lapic.write(0x0f0, svr_enable | 0xff, 0);
    _ = lapic.write(0x350, 0x700, 0);
    _ = lapic.write(0x0d0, 0x02 << 24, 0);

    try std.testing.expect(lapic.extint());
    try std.testing.expectEqual(0x40, lapic.pending());
    try std.testing.expect(lapic.logical_match(0x03));
    try std.testing.expect(!lapic.logical_match(0x01));
}
