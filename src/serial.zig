const std = @import("std");

const assert = std.debug.assert;
const Writer = std.Io.Writer;

pub const Error = error{SerialOutputFailed};

pub const Serial = struct {
    divisor_low: u8 = 0,
    divisor_high: u8 = 0,
    fifo_control: u8 = 0,
    interrupt_enable: std.atomic.Value(u8) = .init(0),
    irq: u4 = console_irq,
    line_control: u8 = 0,
    modem_control: u8 = 0,
    output: *Writer,
    port_base: u16 = console_port_base,
    receive_head: std.atomic.Value(usize) = .init(0),
    receive_ring: [receive_ring_size]u8 = undefined,
    receive_tail: std.atomic.Value(usize) = .init(0),
    scratch: u8 = 0,
    transcript: std.hash.Fnv1a_64 = .init(),
    transmit_empty_pending: bool = false,

    fn divisor_latch(serial: *const Serial) bool {
        return serial.line_control & line_control_divisor_latch != 0;
    }

    fn interrupt_enable_read(serial: *const Serial) u8 {
        return serial.interrupt_enable.load(.acquire);
    }

    fn interrupt_identification(serial: *Serial) u8 {
        const enable = serial.interrupt_enable.load(.acquire);
        const fifo: u8 = if (serial.fifo_control & 0x01 != 0) identification_fifo_enabled else 0;

        if (enable & interrupt_enable_receive != 0) {
            if (serial.receive_ready()) return fifo | identification_receive_available;
        }

        if (enable & interrupt_enable_transmit != 0) {
            if (serial.transmit_empty_pending) {
                serial.transmit_empty_pending = false;

                return fifo | identification_transmit_empty;
            }
        }

        return fifo | identification_none;
    }

    fn line_status(serial: *Serial) u8 {
        const ready: u8 = if (serial.receive_ready()) line_status_data_ready else 0;
        return line_status_transmit_idle | ready;
    }

    fn receive_interrupt_enabled(serial: *const Serial) bool {
        return serial.interrupt_enable_read() & interrupt_enable_receive != 0;
    }

    fn receive_pop(serial: *Serial) u8 {
        const tail = serial.receive_tail.load(.acquire);
        const head = serial.receive_head.load(.acquire);

        assert(head >= tail);

        if (head == tail) return 0;

        const byte = serial.receive_ring[tail % receive_ring_size];

        serial.receive_tail.store(tail + 1, .release);

        return byte;
    }

    fn receive_ready(serial: *const Serial) bool {
        return serial.receive_head.load(.acquire) != serial.receive_tail.load(.acquire);
    }

    fn register_one_read(serial: *const Serial) u8 {
        return if (serial.divisor_latch()) serial.divisor_high else serial.interrupt_enable_read();
    }

    fn transmit(serial: *Serial, byte: u8) Error!void {
        serial.transcript.update(&.{byte});
        serial.output.writeByte(byte) catch return error.SerialOutputFailed;
        serial.output.flush() catch return error.SerialOutputFailed;
        serial.transmit_empty_pending = true;
    }

    fn transmit_interrupt_enabled(serial: *const Serial) bool {
        return serial.interrupt_enable_read() & interrupt_enable_transmit != 0;
    }

    pub fn interrupt_pending(serial: *const Serial) bool {
        const receive_pending = serial.receive_interrupt_enabled() and serial.receive_ready();
        const transmit_enabled = serial.transmit_interrupt_enabled();
        const transmit_pending = transmit_enabled and serial.transmit_empty_pending;

        return receive_pending or transmit_pending;
    }

    pub fn power_cycle(serial: *Serial) void {
        serial.divisor_high = 0;
        serial.divisor_low = 0;
        serial.fifo_control = 0;

        serial.interrupt_enable.store(0, .release);
        serial.line_control = 0;
        serial.modem_control = 0;
        serial.scratch = 0;
        serial.transmit_empty_pending = false;
    }

    pub fn read(serial: *Serial, port: u16) u8 {
        assert(port >= serial.port_base);
        assert(port < serial.port_base + port_count);

        return switch (port - serial.port_base) {
            0 => if (serial.divisor_latch()) serial.divisor_low else serial.receive_pop(),
            1 => serial.register_one_read(),
            2 => serial.interrupt_identification(),
            3 => serial.line_control,
            4 => serial.modem_control,
            5 => serial.line_status(),
            6 => modem_status_default,
            7 => serial.scratch,
            else => unreachable,
        };
    }

    pub fn receive(serial: *Serial, byte: u8) void {
        const head = serial.receive_head.load(.acquire);
        const tail = serial.receive_tail.load(.acquire);

        assert(head >= tail);
        assert(head - tail <= receive_ring_size);

        if (head - tail == receive_ring_size) return;

        serial.receive_ring[head % receive_ring_size] = byte;
        serial.receive_head.store(head + 1, .release);
    }

    pub fn write(serial: *Serial, port: u16, value: u8) Error!void {
        assert(port >= serial.port_base);
        assert(port < serial.port_base + port_count);

        switch (port - serial.port_base) {
            0 => if (serial.divisor_latch()) {
                serial.divisor_low = value;
            } else {
                try serial.transmit(value);
            },
            1 => if (serial.divisor_latch()) {
                serial.divisor_high = value;
            } else {
                serial.interrupt_enable.store(value & 0x0f, .release);
            },
            2 => serial.fifo_control = value,
            3 => serial.line_control = value,
            4 => serial.modem_control = value,
            5, 6 => {},
            7 => serial.scratch = value,
            else => unreachable,
        }
    }
};

pub const console_irq = 4;
pub const console_port_base = 0x3f8;
pub const debug_irq = 3;
pub const debug_port_base = 0x2f8;
pub const port_count = 8;
pub const receive_ring_size = 256;
const identification_fifo_enabled = 0xc0;
const identification_none = 0x01;
const identification_receive_available = 0x04;
const identification_transmit_empty = 0x02;
const interrupt_enable_receive = 0x01;
const interrupt_enable_transmit = 0x02;
const line_control_divisor_latch = 0x80;
const line_status_data_ready = 0x01;
const line_status_transmit_idle = 0x60;
const modem_status_default = 0xb0;

comptime {
    assert(receive_ring_size > 0);
    assert(std.math.isPowerOfTwo(receive_ring_size));
    assert(console_irq < 16);
    assert(debug_irq < 16);
    assert(console_irq != debug_irq);
    assert(debug_port_base + port_count <= console_port_base);
}

test "receive and pop round trip through the ring in order" {
    const base = console_port_base;
    var discard: Writer.Discarding = .init(&.{});
    var serial: Serial = .{ .output = &discard.writer };

    try std.testing.expectEqual(@as(u8, line_status_transmit_idle), serial.read(base + 5));

    serial.receive('a');
    serial.receive('b');

    const ready = line_status_transmit_idle | line_status_data_ready;

    try std.testing.expectEqual(@as(u8, ready), serial.read(base + 5));
    try std.testing.expectEqual(@as(u8, 'a'), serial.read(base));
    try std.testing.expectEqual(@as(u8, 'b'), serial.read(base));
    try std.testing.expectEqual(@as(u8, line_status_transmit_idle), serial.read(base + 5));
    try std.testing.expectEqual(@as(u8, 0), serial.read(base));
}

test "a full ring drops the overrun byte and keeps the rest" {
    const base = console_port_base;
    var discard: Writer.Discarding = .init(&.{});
    var serial: Serial = .{ .output = &discard.writer };

    for (0..receive_ring_size + 1) |i| {
        serial.receive(@intCast(i & 0xff));
    }

    try std.testing.expectEqual(@as(usize, receive_ring_size), serial.receive_head.load(.acquire));

    for (0..receive_ring_size) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i & 0xff)), serial.read(base));
    }

    try std.testing.expectEqual(@as(u8, line_status_transmit_idle), serial.read(base + 5));
}

test "transmit reaches the output and raises the empty interrupt when enabled" {
    const base = console_port_base;
    var buffer: [8]u8 = undefined;
    var output: Writer = .fixed(&buffer);
    var serial: Serial = .{ .output = &output };

    try serial.write(base, 'h');
    try serial.write(base, 'i');
    try std.testing.expectEqualStrings("hi", output.buffered());
    try std.testing.expect(!serial.interrupt_pending());

    try serial.write(base + 1, interrupt_enable_transmit);
    try std.testing.expect(serial.interrupt_pending());
    try std.testing.expectEqual(@as(u8, identification_transmit_empty), serial.read(base + 2));
    try std.testing.expect(!serial.interrupt_pending());
}

test "divisor latch selects the baud registers" {
    const base = console_port_base;
    var discard: Writer.Discarding = .init(&.{});
    var serial: Serial = .{ .output = &discard.writer };

    try serial.write(base + 3, line_control_divisor_latch);
    try serial.write(base, 0x0c);
    try serial.write(base + 1, 0x00);
    try serial.write(base + 3, 0x03);

    try std.testing.expectEqual(@as(u8, 0x0c), serial.read(base + 0) | serial.divisor_low);
    try std.testing.expectEqual(@as(u8, 0), serial.interrupt_enable.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0x03), serial.read(base + 3));
}

test "a full output fails the transmit and keeps every byte written before it" {
    const base = console_port_base;
    var buffer: [2]u8 = undefined;
    var output: Writer = .fixed(&buffer);
    var serial: Serial = .{ .output = &output };

    try serial.write(base, 'o');
    try serial.write(base, 'k');

    const overflow = serial.write(base, '!');
    const kept = output.buffered();

    try std.testing.expectError(error.SerialOutputFailed, overflow);
    try std.testing.expectEqualStrings("ok", kept);
}

test "a second instance answers at its own base and keeps its own receive ring" {
    var console_buffer: [4]u8 = undefined;
    var debug_buffer: [4]u8 = undefined;
    var console_output: Writer = .fixed(&console_buffer);
    var debug_output: Writer = .fixed(&debug_buffer);
    var console: Serial = .{ .output = &console_output };

    var debug: Serial = .{
        .irq = debug_irq,
        .output = &debug_output,
        .port_base = debug_port_base,
    };

    debug.receive('x');

    const idle: u8 = line_status_transmit_idle;

    try std.testing.expectEqual(idle, console.read(console_port_base + 5));
    try std.testing.expectEqual(@as(u8, 'x'), debug.read(debug_port_base));
    try std.testing.expectEqual(@as(u8, 0), console.read(console_port_base));

    try debug.write(debug_port_base, 'y');
    try debug.write(debug_port_base + 1, interrupt_enable_transmit);

    try std.testing.expectEqualStrings("y", debug_output.buffered());
    try std.testing.expectEqualStrings("", console_output.buffered());
    try std.testing.expect(debug.interrupt_pending());
    try std.testing.expect(!console.interrupt_pending());
}
