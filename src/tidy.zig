const std = @import("std");

const Order = struct {
    name: []const u8 = "",
    public: bool = false,
    started: bool = false,
};

const Source = struct {
    name: []const u8,
    text: []const u8,
};

const paths = [_][]const u8{
    "guest/projects/conformance/zig/main.zig",
    "guest/projects/docker-zig/harness/driver.zig",
    "guest/projects/tigerstyle/harness/driver.zig",
    "guest/sdk/zig/dst.zig",
    "src/boot.zig",
    "src/choices.zig",
    "src/coverage.zig",
    "src/cpuid.zig",
    "src/faults.zig",
    "src/kvm.zig",
    "src/lapic.zig",
    "src/machine.zig",
    "src/main.zig",
    "src/pic.zig",
    "src/pit.zig",
    "src/pmu.zig",
    "src/ports.zig",
    "src/rtc.zig",
    "src/serial.zig",
    "src/snapshot.zig",
    "src/step.zig",
    "src/tidy.zig",
    "src/verdict.zig",
    "src/virtio_block.zig",
};

const function_openers = [_][]const u8{ "fn ", "pub fn ", "    fn ", "    pub fn " };

const run_breakers = [_][]const u8{
    "comptime",
    "const ",
    "pub const ",
    "pub var ",
    "test ",
    "var ",
};

const bare_assert = "std.debug." ++ "assert(";
const function_lines_max = 70;
const line_columns_max = 100;
const order_depths = 2;

test "sources respect line length, whitespace, and function length" {
    const gpa = std.testing.allocator;

    for (paths) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
        defer gpa.free(text);

        const source: Source = .{ .name = path, .text = text };
        var lines = std.mem.splitScalar(u8, source.text, '\n');
        var line_number: u32 = 0;
        var function_start: ?u32 = null;
        var function_close: []const u8 = "";

        for (0..source.text.len + 2) |_| {
            const line = lines.next() orelse break;
            line_number += 1;

            try line_check(source.name, line_number, line);

            if (function_opens(line)) {
                function_start = line_number;
                function_close = if (line[0] == ' ') "    }" else "}";
            }

            const start = function_start orelse continue;
            const length = line_number - start;

            if (!std.mem.eql(u8, line, function_close)) continue;
            if (length > function_lines_max) return fail(source.name, start, "function");

            function_start = null;
        } else unreachable;
    }
}

fn fail(name: []const u8, line_number: u32, reason: []const u8) error{TidyViolation} {
    std.debug.print("{s}:{d}: {s}\n", .{ name, line_number, reason });

    return error.TidyViolation;
}

fn function_opens(line: []const u8) bool {
    for (function_openers) |opener| {
        if (std.mem.startsWith(u8, line, opener)) return true;
    }

    return false;
}

fn order_before(public: bool, function: []const u8, prior_public: bool, prior: []const u8) bool {
    if (public != prior_public) return prior_public;
    return std.mem.order(u8, function, prior) == .lt;
}

fn order_check(
    name: []const u8,
    line_number: u32,
    line: []const u8,
    depth: usize,
    order: *Order,
) error{TidyViolation}!void {
    const indent = depth * 4;
    if (line.len <= indent) return;
    if (!std.mem.allEqual(u8, line[0..indent], ' ')) return order_reset(order, depth);
    if (line[indent] == ' ') return;

    const body = line[indent..];
    const public = std.mem.startsWith(u8, body, "pub fn ");
    const prefix = if (public) "pub fn " else "fn ";

    if (!std.mem.startsWith(u8, body, prefix)) {
        if (run_breaks(body)) order.* = .{};

        return;
    }

    const name_start = prefix.len;
    const name_end = std.mem.findScalarPos(u8, body, name_start, '(') orelse return;
    const function = body[name_start..name_end];

    if (order.started) {
        const before = order_before(public, function, order.public, order.name);
        if (before) return fail(name, line_number, "order");
    }

    order.* = .{ .name = function, .public = public, .started = true };
}

fn order_reset(order: *Order, depth: usize) void {
    if (depth > 0) order.* = .{};
}

fn run_breaks(body: []const u8) bool {
    for (run_breakers) |breaker| {
        if (std.mem.startsWith(u8, body, breaker)) return true;
    }

    return false;
}

test "functions and methods run private first, then alphabetically" {
    const gpa = std.testing.allocator;

    for (paths) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
        defer gpa.free(text);

        const source: Source = .{ .name = path, .text = text };
        var lines = std.mem.splitScalar(u8, source.text, '\n');
        var line_number: u32 = 0;
        var orders: [order_depths]Order = @splat(.{});

        for (0..source.text.len + 2) |_| {
            const line = lines.next() orelse break;
            line_number += 1;

            for (&orders, 0..) |*order, depth| {
                try order_check(source.name, line_number, line, depth, order);
            }
        } else unreachable;
    }
}

fn line_check(name: []const u8, line_number: u32, line: []const u8) error{TidyViolation}!void {
    if (line.len > line_columns_max) return fail(name, line_number, "line too long");
    if (std.mem.findScalar(u8, line, '\t') != null) return fail(name, line_number, "tab");
    if (std.mem.endsWith(u8, line, " ")) return fail(name, line_number, "trailing whitespace");
    if (std.mem.endsWith(u8, line, "\r")) return fail(name, line_number, "carriage return");
    if (std.mem.find(u8, line, bare_assert)) |_| return fail(name, line_number, "assert");
}
