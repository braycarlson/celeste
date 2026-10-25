const std = @import("std");

const assert = std.debug.assert;

pub const Rtc = struct {
    index: u7 = 0,
    registers: [128]u8 = registers_initial,

    pub fn init(seconds: u64) Rtc {
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
        const day = epoch.getEpochDay();
        const day_seconds = epoch.getDaySeconds();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        var rtc: Rtc = .{};
        rtc.registers[register_seconds] = bcd(day_seconds.getSecondsIntoMinute());
        rtc.registers[register_minutes] = bcd(day_seconds.getMinutesIntoHour());
        rtc.registers[register_hours] = bcd(day_seconds.getHoursIntoDay());
        rtc.registers[register_weekday] = bcd(@intCast((day.day + epoch_weekday) % 7 + 1));
        rtc.registers[register_day] = bcd(@as(u8, month_day.day_index) + 1);
        rtc.registers[register_month] = bcd(month_day.month.numeric());
        rtc.registers[register_year] = bcd(@intCast(year_day.year % 100));
        rtc.registers[century] = bcd(@intCast(year_day.year / 100));

        assert(year_day.year >= 2000);
        assert(year_day.year < 2100);

        return rtc;
    }

    pub fn read(rtc: *const Rtc, port: u16) u8 {
        return switch (port) {
            index_port => rtc.index,
            data_port => rtc.registers[rtc.index],
            else => unreachable,
        };
    }

    pub fn write(rtc: *Rtc, port: u16, value: u8) void {
        switch (port) {
            index_port => rtc.index = @truncate(value),
            data_port => {
                if (rtc.index == status_c) return;
                if (rtc.index == status_d) return;

                rtc.registers[rtc.index] = value;
            },
            else => unreachable,
        }
    }
};

pub const data_port = 0x71;
pub const index_port = 0x70;
const century = 0x32;
const epoch_weekday = 4;
const register_day = 0x07;
const register_hours = 0x04;
const register_minutes = 0x02;
const register_month = 0x08;
const register_seconds = 0x00;
const register_weekday = 0x06;
const register_year = 0x09;
const status_a = 0x0a;
const status_b = 0x0b;
const status_c = 0x0c;
const status_d = 0x0d;

const registers_initial = blk: {
    var registers: [128]u8 = @splat(0);
    registers[0x00] = 0x00;
    registers[0x02] = 0x00;
    registers[0x04] = 0x00;
    registers[0x06] = 0x05;
    registers[0x07] = 0x01;
    registers[0x08] = 0x01;
    registers[0x09] = 0x26;
    registers[status_a] = 0x26;
    registers[status_b] = 0x02;
    registers[status_d] = 0x80;
    registers[century] = 0x20;

    break :blk registers;
};

fn bcd(value: u8) u8 {
    assert(value < 100);

    return (value / 10) << 4 | value % 10;
}

test "init at the start of 2026 reproduces the fixed register table" {
    const rtc: Rtc = .init(1767225600);

    try std.testing.expectEqualSlices(u8, &registers_initial, &rtc.registers);
}

test "init encodes a later timestamp as BCD date, time, and weekday" {
    const rtc: Rtc = .init(1773582330);

    try std.testing.expectEqual(@as(u8, 0x30), rtc.registers[register_seconds]);
    try std.testing.expectEqual(@as(u8, 0x45), rtc.registers[register_minutes]);
    try std.testing.expectEqual(@as(u8, 0x13), rtc.registers[register_hours]);
    try std.testing.expectEqual(@as(u8, 0x01), rtc.registers[register_weekday]);
    try std.testing.expectEqual(@as(u8, 0x15), rtc.registers[register_day]);
    try std.testing.expectEqual(@as(u8, 0x03), rtc.registers[register_month]);
    try std.testing.expectEqual(@as(u8, 0x26), rtc.registers[register_year]);
    try std.testing.expectEqual(@as(u8, 0x20), rtc.registers[century]);
}

test "the clock reads a fixed BCD date and never reports an update in progress" {
    var rtc: Rtc = .{};

    rtc.write(index_port, 0x09);
    try std.testing.expectEqual(@as(u8, 0x26), rtc.read(data_port));

    rtc.write(index_port, status_a);
    try std.testing.expectEqual(@as(u8, 0), rtc.read(data_port) & 0x80);

    rtc.write(index_port, status_c);
    rtc.write(data_port, 0xff);
    try std.testing.expectEqual(@as(u8, 0), rtc.read(data_port));

    rtc.write(index_port, 0x80 | status_b);
    try std.testing.expectEqual(@as(u8, 0x02), rtc.read(data_port));
}
