const std = @import("std");

const ports = @import("ports");

const snapshot = @import("snapshot.zig");

const assert = std.debug.assert;
const ForkPoint = snapshot.ForkPoint;

pub const Coverage = struct {
    bits: Bits,
    fresh: [fresh_max]u32 = undefined,
    fresh_count: u32 = 0,
    fresh_dropped: u32 = 0,
    fresh_points: [fresh_max]?ForkPoint = undefined,
    known: ?*const Bits = null,
    latch: u32 = 0,

    pub fn latch_byte(coverage: *Coverage, offset: u16, value: u8) ?u32 {
        assert(offset < ports.coverage_count);
        assert(coverage.latch < bits_count);

        switch (offset) {
            0 => coverage.latch = value,
            1 => coverage.latch |= @as(u32, value) << 8,
            2 => {
                const index = coverage.latch | @as(u32, value) << 16;

                coverage.latch = 0;

                return index;
            },
            else => unreachable,
        }

        return null;
    }

    pub fn record(coverage: *Coverage, index: u32, point: ?*const ForkPoint) void {
        assert(index < bits_count);

        const word = index / 64;
        const mask = @as(u64, 1) << @intCast(index % 64);
        if (coverage.bits[word] & mask != 0) return;

        coverage.bits[word] |= mask;

        if (coverage.known) |known| {
            if (known[word] & mask != 0) return;
        }

        if (coverage.fresh_count < coverage.fresh.len) {
            coverage.fresh[coverage.fresh_count] = index;
            coverage.fresh_points[coverage.fresh_count] = if (point) |at| at.* else null;
            coverage.fresh_count += 1;
        } else {
            coverage.fresh_dropped += 1;
        }

        assert(coverage.bits[word] & mask != 0);
    }

    pub fn reset_fresh(coverage: *Coverage, known: ?*const Bits) void {
        coverage.fresh_count = 0;
        coverage.fresh_dropped = 0;
        coverage.known = known;
        coverage.latch = 0;

        assert(coverage.fresh_count == 0);
    }
};

pub const Bits = [words_count]u64;

pub const Guidance = struct {
    count: u32 = 0,
    dropped: u32 = 0,
    entries: [guidance_max]Maximum = undefined,
    latch: [ports.guidance_count]u8 = @splat(0),

    pub fn latch_byte(guidance: *Guidance, offset: u16, value: u8) ?Report {
        assert(offset < ports.guidance_count);
        assert(guidance.count <= guidance_max);

        guidance.latch[offset] = value;

        if (offset != ports.guidance_count - 1) return null;

        const report: Report = .{
            .crc = std.mem.readInt(u32, guidance.latch[0..4], .little),
            .value = std.mem.readInt(u64, guidance.latch[4..12], .little),
        };

        guidance.latch = @splat(0);

        return report;
    }

    pub fn record(guidance: *Guidance, report: Report, point: ?*const ForkPoint) void {
        assert(guidance.count <= guidance_max);

        for (guidance.entries[0..guidance.count]) |*entry| {
            if (entry.crc != report.crc) continue;
            if (report.value <= entry.value) return;

            entry.value = report.value;
            entry.point = if (point) |at| at.* else null;

            return;
        }

        if (guidance.count == guidance_max) {
            guidance.dropped += 1;

            return;
        }

        guidance.entries[guidance.count] = .{
            .crc = report.crc,
            .point = if (point) |at| at.* else null,
            .value = report.value,
        };

        guidance.count += 1;
    }

    pub fn reset(guidance: *Guidance) void {
        guidance.count = 0;
        guidance.dropped = 0;
        guidance.latch = @splat(0);

        assert(guidance.count == 0);
    }

    pub fn slice(guidance: *const Guidance) []const Maximum {
        assert(guidance.count <= guidance_max);

        return guidance.entries[0..guidance.count];
    }
};

pub const Maximum = struct {
    crc: u32,
    point: ?ForkPoint,
    value: u64,
};

pub const Report = struct {
    crc: u32,
    value: u64,
};

pub const bits_count = 1 << 24;
pub const fresh_max = 1024;
pub const guidance_max = 16;
pub const words_count = bits_count / 64;

comptime {
    assert(bits_count % 64 == 0);
    assert(bits_count == 1 << (ports.coverage_count * 8));
}

pub fn count(bits: *const Bits) u64 {
    var total: u64 = 0;

    for (bits) |word| total += @popCount(word);

    assert(total <= bits_count);

    return total;
}

pub const Merged = struct {
    added: u32 = 0,
    points_count: u32 = 0,
};

pub fn merge(
    target: *Bits,
    fresh: []const u32,
    points: []const ?ForkPoint,
    added_points: []ForkPoint,
) Merged {
    var merged: Merged = .{};

    assert(fresh.len == points.len);
    assert(added_points.len >= fresh.len);

    for (fresh, points) |index, point_fresh| {
        assert(index < bits_count);

        const mask = @as(u64, 1) << @intCast(index % 64);
        if (target[index / 64] & mask != 0) continue;

        target[index / 64] |= mask;
        merged.added += 1;

        const point = point_fresh orelse continue;

        added_points[merged.points_count] = point;
        merged.points_count += 1;
    }

    assert(merged.added <= fresh.len);
    assert(merged.points_count <= merged.added);

    return merged;
}

test "a bit is fresh once against the known bits and carries a fork point only from cycle zero" {
    const allocator = std.testing.allocator;
    const known = try allocator.create(Bits);
    defer allocator.destroy(known);

    const coverage = try allocator.create(Coverage);
    defer allocator.destroy(coverage);

    known.* = @splat(0);
    coverage.* = .{ .bits = @splat(0) };

    const points = [_]ForkPoint{
        test_point(100),
        test_point(200),
        test_point(300),
        test_point(400),
    };

    coverage.record(7, &points[0]);
    try std.testing.expectEqual(1, coverage.fresh_count);

    known[0] = 1 << 9;

    coverage.reset_fresh(known);

    coverage.record(7, &points[1]);
    coverage.record(9, &points[2]);
    coverage.record(1 << 23, &points[3]);
    coverage.record(1 << 23, &points[3]);
    coverage.record(65, null);

    const fresh = coverage.fresh[0..coverage.fresh_count];
    const fresh_points = coverage.fresh_points[0..coverage.fresh_count];

    try std.testing.expectEqual(2, coverage.fresh_count);
    try std.testing.expectEqualSlices(u32, &.{ 1 << 23, 65 }, fresh);
    try std.testing.expectEqual(points[3], fresh_points[0].?);
    try std.testing.expectEqual(null, fresh_points[1]);
    try std.testing.expectEqual(4, count(&coverage.bits));

    known[(1 << 23) / 64] |= @as(u64, 1) << @intCast((1 << 23) % 64);

    var added_points: [2]ForkPoint = undefined;
    const first = merge(known, fresh, fresh_points, &added_points);

    try std.testing.expectEqual(1, first.added);
    try std.testing.expectEqual(0, first.points_count);
    try std.testing.expectEqual(0, merge(known, fresh, fresh_points, &added_points).added);
    try std.testing.expectEqual(3, count(known));

    known.* = @splat(0);

    const second = merge(known, fresh, fresh_points, &added_points);

    try std.testing.expectEqual(2, second.added);
    try std.testing.expectEqual(1, second.points_count);
    try std.testing.expectEqual(points[3], added_points[0]);
}

test "a guidance report commits on its last byte and keeps only a higher value per message" {
    var guidance: Guidance = .{};
    const point_low = test_point(10);
    const point_high = test_point(20);
    const crc: u32 = 0xdeadbeef;
    var bytes: [ports.guidance_count]u8 = undefined;
    var report: ?Report = null;

    std.mem.writeInt(u32, bytes[0..4], crc, .little);
    std.mem.writeInt(u64, bytes[4..12], 7, .little);

    for (bytes, 0..) |byte, offset| report = guidance.latch_byte(@intCast(offset), byte);

    try std.testing.expectEqual(crc, report.?.crc);
    try std.testing.expectEqual(7, report.?.value);

    guidance.record(report.?, &point_low);
    guidance.record(.{ .crc = crc, .value = 5 }, &point_high);
    guidance.record(.{ .crc = crc, .value = 9 }, &point_high);
    guidance.record(.{ .crc = crc + 1, .value = 1 }, null);

    const maxima = guidance.slice();

    try std.testing.expectEqual(2, maxima.len);
    try std.testing.expectEqual(9, maxima[0].value);
    try std.testing.expectEqual(point_high, maxima[0].point.?);
    try std.testing.expectEqual(null, maxima[1].point);

    for (0..guidance_max) |index| {
        guidance.record(.{ .crc = @intCast(index + 100), .value = 1 }, null);
    }

    try std.testing.expectEqual(guidance_max, guidance.count);
    try std.testing.expectEqual(2, guidance.dropped);
}

test "three port bytes commit one index and a lone low byte commits nothing" {
    const allocator = std.testing.allocator;
    const coverage = try allocator.create(Coverage);
    defer allocator.destroy(coverage);

    coverage.* = .{ .bits = @splat(0) };

    const index: u32 = 0xabcdef;
    const stray = coverage.latch_byte(0, 0x11);
    const low = coverage.latch_byte(0, @truncate(index));
    const middle = coverage.latch_byte(1, @truncate(index >> 8));
    const high = coverage.latch_byte(2, @truncate(index >> 16));

    try std.testing.expectEqual(null, stray);
    try std.testing.expectEqual(null, low);
    try std.testing.expectEqual(null, middle);
    try std.testing.expectEqual(index, high.?);
    try std.testing.expectEqual(0, coverage.latch);
}

fn test_point(exits: u64) ForkPoint {
    var point: ForkPoint = .{ .branches = exits * 1000, .exits = exits };

    point.cpu_branches[0] = point.branches;

    assert(point.exits == exits);

    return point;
}
