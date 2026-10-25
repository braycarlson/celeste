const std = @import("std");

const assert = std.debug.assert;

pub const Pit = struct {
    channels: [3]Channel = .{ .{}, .{}, .{} },
    speaker: u8 = 0,

    fn control_write(pit: *Pit, time_ns: u64, value: u8) void {
        const select = value >> 6;

        if (select == 3) {
            for (pit.channels[0..], 0..) |*channel, index| {
                const selected = value & (@as(u8, 0x02) << @intCast(index)) != 0;
                if (!selected) continue;

                if (value & 0x20 == 0) channel.latch_count(time_ns);
            }

            return;
        }

        pit.channels[select].control(time_ns, value);
    }

    fn speaker_read(pit: *const Pit, time_ns: u64) u8 {
        const output: u8 = if (pit.channels[2].output_high(time_ns)) 0x20 else 0;
        return pit.speaker | output;
    }

    pub fn expiry_ns_next(pit: *const Pit) ?u64 {
        return pit.channels[0].expiry_ns_next();
    }

    pub fn poll(pit: *Pit, time_ns: u64) bool {
        return pit.channels[0].poll(time_ns);
    }

    pub fn read(pit: *Pit, time_ns: u64, port: u16) u8 {
        return switch (port) {
            channel_port_base...channel_port_last => {
                return pit.channels[port - channel_port_base].read(time_ns);
            },
            control_port => 0xff,
            speaker_port => pit.speaker_read(time_ns),
            else => unreachable,
        };
    }

    pub fn write(pit: *Pit, time_ns: u64, port: u16, value: u8) void {
        switch (port) {
            channel_port_base...channel_port_last => {
                pit.channels[port - channel_port_base].write(time_ns, value);
            },
            control_port => pit.control_write(time_ns, value),
            speaker_port => pit.speaker = value & 0x03,
            else => unreachable,
        }
    }
};

const Channel = struct {
    access: u2 = 3,
    bcd: bool = false,
    count_initial: u32 = 0x10000,
    expired: bool = false,
    latch: ?u16 = null,
    loaded: bool = false,
    mode: u3 = 0,
    periods_seen: u64 = 0,
    read_high: bool = false,
    start_ns: u64 = 0,
    write_low: ?u8 = null,

    fn control(channel: *Channel, time_ns: u64, value: u8) void {
        const access: u2 = @intCast((value >> 4) & 0x03);

        if (access == 0) {
            channel.latch_count(time_ns);

            return;
        }

        channel.access = access;
        channel.mode = @intCast((value >> 1) & 0x07);
        channel.bcd = value & 0x01 != 0;
        channel.latch = null;
        channel.loaded = false;
        channel.read_high = false;
        channel.write_low = null;

        if (channel.mode >= 6) channel.mode -= 4;
    }

    fn count_current(channel: *const Channel, time_ns: u64) u16 {
        if (!channel.loaded) return @truncate(channel.count_initial);

        assert(time_ns >= channel.start_ns);

        const elapsed = ticks_from_ns(time_ns - channel.start_ns);
        const initial: u64 = channel.count_initial;

        const remaining: u64 = switch (channel.mode) {
            2, 3 => initial - (elapsed % initial),
            else => if (elapsed >= initial) 0 else initial - elapsed,
        };

        return @truncate(remaining);
    }

    fn expiry_ns_next(channel: *const Channel) ?u64 {
        if (!channel.loaded) return null;

        const initial: u64 = channel.count_initial;

        const ticks: u64 = switch (channel.mode) {
            2, 3 => (channel.periods_seen + 1) * initial,
            else => if (channel.expired) return null else initial,
        };

        return channel.start_ns + time_ns_from_ticks(ticks);
    }

    fn latch_count(channel: *Channel, time_ns: u64) void {
        if (channel.latch == null) channel.latch = channel.count_current(time_ns);
    }

    fn load(channel: *Channel, time_ns: u64, count: u16) void {
        channel.count_initial = if (count == 0) 0x10000 else count;
        channel.expired = false;
        channel.latch = null;
        channel.loaded = true;
        channel.periods_seen = 0;
        channel.start_ns = time_ns;
    }

    fn output_high(channel: *const Channel, time_ns: u64) bool {
        if (!channel.loaded) return false;

        return switch (channel.mode) {
            0 => channel.count_current(time_ns) == 0,
            3 => channel.count_current(time_ns) > channel.count_initial / 2,
            else => true,
        };
    }

    fn poll(channel: *Channel, time_ns: u64) bool {
        if (!channel.loaded) return false;

        assert(time_ns >= channel.start_ns);

        const elapsed = ticks_from_ns(time_ns - channel.start_ns);
        const initial: u64 = channel.count_initial;

        switch (channel.mode) {
            2, 3 => {
                const periods = elapsed / initial;
                if (periods <= channel.periods_seen) return false;

                channel.periods_seen = periods;

                return true;
            },
            else => {
                if (channel.expired) return false;
                if (elapsed < initial) return false;

                channel.expired = true;

                return true;
            },
        }
    }

    fn read(channel: *Channel, time_ns: u64) u8 {
        const value = channel.latch orelse channel.count_current(time_ns);
        const low: u8 = @truncate(value);
        const high: u8 = @truncate(value >> 8);

        switch (channel.access) {
            1 => {
                channel.latch = null;

                return low;
            },
            2 => {
                channel.latch = null;

                return high;
            },
            else => {
                if (channel.read_high) {
                    channel.read_high = false;
                    channel.latch = null;

                    return high;
                }

                channel.read_high = true;

                return low;
            },
        }
    }

    fn write(channel: *Channel, time_ns: u64, value: u8) void {
        switch (channel.access) {
            1 => channel.load(time_ns, value),
            2 => channel.load(time_ns, @as(u16, value) << 8),
            else => {
                if (channel.write_low) |low| {
                    channel.write_low = null;

                    channel.load(time_ns, low | @as(u16, value) << 8);
                } else {
                    channel.write_low = value;
                }
            },
        }
    }
};

pub const channel_port_base = 0x40;
pub const channel_port_last = channel_port_base + 2;
pub const control_port = 0x43;
pub const frequency_hz = 1_193_182;
pub const speaker_port = 0x61;
const second_ns = 1_000_000_000;

fn ticks_from_ns(ns: u64) u64 {
    const scaled: u128 = @as(u128, ns) * frequency_hz;
    return @intCast(scaled / second_ns);
}

fn time_ns_from_ticks(ticks: u64) u64 {
    const scaled: u128 = @as(u128, ticks) * second_ns + frequency_hz - 1;
    return @intCast(scaled / frequency_hz);
}

test "ticks and nanoseconds round trip without losing a tick" {
    for ([_]u64{ 1, 1193, 65536, 1_000_000, 123_456_789 }) |ticks| {
        try std.testing.expectEqual(ticks, ticks_from_ns(time_ns_from_ticks(ticks)));
    }
}

test "a periodic channel fires once per period and reports the next expiry" {
    var pit: Pit = .{};
    const latch_1000hz: u16 = 1193;

    pit.write(0, control_port, 0x34);
    pit.write(0, channel_port_base, @truncate(latch_1000hz));
    pit.write(0, channel_port_base, @truncate(latch_1000hz >> 8));

    const first = pit.expiry_ns_next().?;

    try std.testing.expect(first >= 999_000);
    try std.testing.expect(first <= 1_001_000);
    try std.testing.expect(!pit.poll(first - 1));
    try std.testing.expect(pit.poll(first));
    try std.testing.expect(!pit.poll(first));
    try std.testing.expectEqual(time_ns_from_ticks(2 * latch_1000hz), pit.expiry_ns_next().?);
    try std.testing.expect(pit.poll(first * 3));
}

test "a latched count reads back low byte then high byte" {
    var pit: Pit = .{};

    pit.write(0, control_port, 0x34);
    pit.write(0, channel_port_base, 0x00);
    pit.write(0, channel_port_base, 0x10);

    const half = time_ns_from_ticks(0x800);

    pit.write(half, control_port, 0x00);

    const low = pit.read(half, channel_port_base);
    const high = pit.read(half, channel_port_base);

    try std.testing.expectEqual(@as(u16, 0x1000 - 0x800), low | @as(u16, high) << 8);
}

test "a one shot channel fires once and then has no expiry" {
    var pit: Pit = .{};

    pit.write(0, control_port, 0x30);
    pit.write(0, channel_port_base, 0x10);
    pit.write(0, channel_port_base, 0x00);

    const expiry = pit.expiry_ns_next().?;

    try std.testing.expect(pit.poll(expiry));
    try std.testing.expectEqual(@as(?u64, null), pit.expiry_ns_next());
    try std.testing.expect(!pit.poll(expiry * 2));
}
