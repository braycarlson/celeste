const std = @import("std");

const assert = std.debug.assert;

pub const Pic = struct {
    elcr: [2]u8 = .{ 0, 0 },
    master: Chip = .{},
    slave: Chip = .{},

    fn cascade_update(pic: *Pic) void {
        const level: u1 = if (pic.slave.pending() != null) 1 else 0;

        pic.master.line_set(cascade_line, level);
    }

    pub fn interrupt_acknowledge(pic: *Pic) u8 {
        const master_irq = pic.master.pending().?;

        pic.master.acknowledge(master_irq);

        if (master_irq != cascade_line) return pic.master.vector_base + @as(u8, master_irq);

        const slave_irq = pic.slave.pending() orelse spurious_line;

        if (pic.slave.pending() != null) pic.slave.acknowledge(slave_irq);

        pic.cascade_update();

        return pic.slave.vector_base + @as(u8, slave_irq);
    }

    pub fn interrupt_pending(pic: *const Pic) bool {
        return pic.master.pending() != null;
    }

    pub fn irq_level_set(pic: *Pic, irq: u4, level: u1) void {
        assert(irq != cascade_line);

        if (irq < 8) {
            pic.master.line_set(@intCast(irq), level);
        } else {
            pic.slave.line_set(@intCast(irq - 8), level);
        }

        pic.cascade_update();
    }

    pub fn irq_pulse(pic: *Pic, irq: u4) void {
        pic.irq_level_set(irq, 1);
        pic.irq_level_set(irq, 0);
    }

    pub fn read(pic: *const Pic, port: u16) u8 {
        return switch (port) {
            master_command => pic.master.command_read(),
            master_data => pic.master.imr,
            slave_command => pic.slave.command_read(),
            slave_data => pic.slave.imr,
            elcr_master => pic.elcr[0],
            elcr_slave => pic.elcr[1],
            else => unreachable,
        };
    }

    pub fn write(pic: *Pic, port: u16, value: u8) void {
        switch (port) {
            master_command => pic.master.command_write(value),
            master_data => pic.master.data_write(value),
            slave_command => pic.slave.command_write(value),
            slave_data => pic.slave.data_write(value),
            elcr_master => pic.elcr[0] = value & 0xf8,
            elcr_slave => pic.elcr[1] = value & 0xde,
            else => unreachable,
        }

        pic.cascade_update();
    }
};

const Chip = struct {
    auto_eoi: bool = false,
    imr: u8 = 0xff,
    init4: bool = false,
    init_state: u8 = 0,
    irr: u8 = 0,
    isr: u8 = 0,
    level_last: u8 = 0,
    read_isr: bool = false,
    single: bool = false,
    vector_base: u8 = 0,

    fn acknowledge(chip: *Chip, irq: u3) void {
        const mask = @as(u8, 1) << irq;

        assert(chip.irr & mask != 0);

        if (!chip.auto_eoi) chip.isr |= mask;

        chip.irr &= ~mask;
    }

    fn command_read(chip: *const Chip) u8 {
        return if (chip.read_isr) chip.isr else chip.irr;
    }

    fn command_write(chip: *Chip, value: u8) void {
        if (value & 0x10 != 0) {
            chip.init_state = 1;
            chip.init4 = value & 0x01 != 0;
            chip.single = value & 0x02 != 0;
            chip.imr = 0;
            chip.isr = 0;
            chip.irr = 0;
            chip.read_isr = false;
            chip.auto_eoi = false;

            return;
        }

        if (value & 0x08 != 0) {
            if (value & 0x02 != 0) chip.read_isr = value & 0x01 != 0;

            return;
        }

        switch (value >> 5) {
            1, 5 => chip.eoi_nonspecific(),
            3, 7 => chip.isr &= ~(@as(u8, 1) << @intCast(value & 0x07)),
            else => {},
        }
    }

    fn data_write(chip: *Chip, value: u8) void {
        switch (chip.init_state) {
            1 => {
                chip.vector_base = value & 0xf8;
                chip.init_state = if (chip.single) icw4_or_done(chip) else 2;
            },
            2 => chip.init_state = icw4_or_done(chip),
            3 => {
                chip.auto_eoi = value & 0x02 != 0;
                chip.init_state = 0;
            },
            else => chip.imr = value,
        }
    }

    fn eoi_nonspecific(chip: *Chip) void {
        if (chip.isr == 0) return;

        chip.isr &= ~(@as(u8, 1) << @intCast(@ctz(chip.isr)));
    }

    fn icw4_or_done(chip: *const Chip) u8 {
        return if (chip.init4) 3 else 0;
    }

    fn line_set(chip: *Chip, line: u3, level: u1) void {
        const mask = @as(u8, 1) << line;

        if (level == 1) {
            if (chip.level_last & mask == 0) chip.irr |= mask;

            chip.level_last |= mask;
        } else {
            chip.level_last &= ~mask;
        }
    }

    fn pending(chip: *const Chip) ?u3 {
        const candidates = chip.irr & ~chip.imr;
        if (candidates == 0) return null;

        const irq: u3 = @intCast(@ctz(candidates));

        if (chip.isr != 0) {
            if (@ctz(chip.isr) <= irq) return null;
        }

        return irq;
    }
};

pub const elcr_master = 0x4d0;
pub const elcr_slave = 0x4d1;
pub const master_command = 0x20;
pub const master_data = 0x21;
pub const slave_command = 0xa0;
pub const slave_data = 0xa1;
const cascade_line = 2;
const spurious_line = 7;

fn linux_init(pic: *Pic) void {
    pic.write(master_command, 0x11);
    pic.write(master_data, 0x30);
    pic.write(master_data, 0x04);
    pic.write(master_data, 0x01);
    pic.write(slave_command, 0x11);
    pic.write(slave_data, 0x38);
    pic.write(slave_data, 0x02);
    pic.write(slave_data, 0x01);
    pic.write(master_data, 0xe8);
    pic.write(slave_data, 0xff);
}

test "edge on an unmasked line delivers the base vector and clears on acknowledge" {
    var pic: Pic = .{};

    linux_init(&pic);

    pic.irq_level_set(0, 1);
    try std.testing.expect(pic.interrupt_pending());
    try std.testing.expectEqual(@as(u8, 0x30), pic.interrupt_acknowledge());
    try std.testing.expect(!pic.interrupt_pending());

    pic.irq_level_set(0, 0);
    pic.irq_level_set(0, 1);
    try std.testing.expect(!pic.interrupt_pending());

    pic.write(master_command, 0x60);
    try std.testing.expect(pic.interrupt_pending());
    try std.testing.expectEqual(@as(u8, 0x30), pic.interrupt_acknowledge());
}

test "a masked line stays pending until unmasked and priority favours the lower line" {
    var pic: Pic = .{};

    linux_init(&pic);

    pic.write(master_data, 0xff);
    pic.irq_pulse(4);
    pic.irq_pulse(1);
    try std.testing.expect(!pic.interrupt_pending());

    pic.write(master_data, 0xe9);
    try std.testing.expectEqual(@as(u8, 0x31), pic.interrupt_acknowledge());
    try std.testing.expect(!pic.interrupt_pending());

    pic.write(master_command, 0x20);
    try std.testing.expectEqual(@as(u8, 0x34), pic.interrupt_acknowledge());
    try std.testing.expectEqual(@as(u8, 0xe9), pic.read(master_data));
}

test "a slave line arrives through the cascade with the slave base" {
    var pic: Pic = .{};

    linux_init(&pic);

    pic.write(slave_data, 0xfe);
    pic.irq_pulse(8);
    try std.testing.expect(pic.interrupt_pending());
    try std.testing.expectEqual(@as(u8, 0x38), pic.interrupt_acknowledge());
    try std.testing.expect(!pic.interrupt_pending());
}
