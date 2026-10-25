const std = @import("std");

const choices_module = @import("choices.zig");
const faults_module = @import("faults.zig");
const kvm = @import("kvm.zig");

const assert = std.debug.assert;
const DiskFaults = faults_module.Disk;
const Stream = choices_module.Stream;

pub const LogEntry = struct {
    data: [sector_size]u8,
    sector: u64,
};

pub const VolatileLog = struct {
    count: u32 = 0,
    entries: []LogEntry = &.{},
    logged: []u64 = &.{},
    overflows: u64 = 0,

    fn clear(log: *VolatileLog) void {
        for (log.entries[0..log.count]) |entry| {
            log.logged[entry.sector / 64] &= ~sector_mask(entry.sector);
        }

        log.count = 0;
    }

    fn power_loss(log: *VolatileLog, image: []u8, stream: *Stream, faults: DiskFaults) void {
        assert(faults.persist_permille <= permille);
        assert(std.math.isPowerOfTwo(faults.atomic_sectors));

        const salt = stream.word();

        for (log.entries[0..log.count]) |entry| {
            const unit = entry.sector / faults.atomic_sectors;
            const roll = std.hash.Wyhash.hash(salt, std.mem.asBytes(&unit)) % permille;
            if (roll < faults.persist_permille) continue;

            @memcpy(image[entry.sector * sector_size ..][0..sector_size], &entry.data);
        }

        log.clear();
    }

    fn record(log: *VolatileLog, image: []const u8, offset: u64, length: u64) void {
        if (log.entries.len == 0) return;
        if (length == 0) return;

        const first = offset / sector_size;
        const last = (offset + length - 1) / sector_size;

        assert(last < image.len / sector_size);

        for (first..last + 1) |sector| log.record_sector(image, sector);
    }

    fn record_sector(log: *VolatileLog, image: []const u8, sector: u64) void {
        const word = sector / 64;
        const mask = sector_mask(sector);

        assert(word < log.logged.len);

        if (log.logged[word] & mask != 0) return;

        if (log.count == log.entries.len) {
            log.clear();
            log.overflows += 1;
        }

        log.entries[log.count] = .{
            .data = image[sector * sector_size ..][0..sector_size].*,
            .sector = sector,
        };

        log.count += 1;
        log.logged[word] |= mask;
    }
};

pub const VirtioBlock = struct {
    device_features_select: u32 = 0,
    driver_features: u64 = 0,
    driver_features_select: u32 = 0,
    errors_from_ns: ?u64 = null,
    errors_injected: u64 = 0,
    errors_until_ns: u64 = 0,
    faults: DiskFaults = .{},
    image: []u8,
    interrupt_status: u32 = 0,
    log: VolatileLog = .{},
    pending: [pending_max]Pending = undefined,
    pending_count: u32 = 0,
    stream: Stream = .init(0),
    queue: Queue = .{},
    queue_select: u32 = 0,
    sequence: u64 = 0,
    status: u32 = 0,

    fn config_read(block: *const VirtioBlock, offset: u64, data: []u8) void {
        var config: [config_size]u8 = @splat(0);

        std.mem.writeInt(u64, config[0..8], block.image.len / sector_size, .little);

        for (data, 0..) |*byte, i| {
            const index = offset + i;
            byte.* = if (index < config_size) config[index] else 0;
        }
    }

    fn device_features_read(block: *const VirtioBlock) u32 {
        return switch (block.device_features_select) {
            0 => @truncate(device_features),
            1 => @truncate(device_features >> 32),
            else => 0,
        };
    }

    fn driver_features_write(block: *VirtioBlock, value: u32) void {
        switch (block.driver_features_select) {
            0 => address_low_set(&block.driver_features, value),
            1 => address_high_set(&block.driver_features, value),
            else => {},
        }
    }

    fn error_due(block: *VirtioBlock, request_type: u32, now_ns: u64) bool {
        const from = block.errors_from_ns orelse return false;
        if (now_ns < from) return false;
        if (now_ns >= block.errors_until_ns) return false;

        const rate: u16 = switch (request_type) {
            request_in => block.faults.error_read_permille,
            request_out, request_flush => block.faults.error_write_permille,
            else => 0,
        };

        assert(rate <= permille);

        if (rate == 0) return false;

        const failed = block.stream.below(permille) < rate;

        block.errors_injected += @intFromBool(failed);

        return failed;
    }

    fn flush(block: *VirtioBlock) u8 {
        block.log.clear();

        return status_ok;
    }

    fn identity_write(memory: []u8, data: []const Descriptor, written: *u32) u8 {
        if (data.len != 1) return status_io_error;

        const guest = guest_slice(memory, data[0].addr, data[0].len) orelse return status_io_error;
        const length = @min(guest.len, identity.len);

        @memcpy(guest[0..length], identity[0..length]);
        written.* += @intCast(length);

        return status_ok;
    }

    fn latency_ns(block: *VirtioBlock) u64 {
        const faults = block.faults;

        if (faults.latency_ns_max == 0) {
            if (faults.stall_permille == 0) return 0;
        }

        const stalled = block.stream.below(permille) < faults.stall_permille;
        const latency = block.stream.at_most(faults.latency_ns_max);
        const stall: u64 = if (stalled) faults.stall_ns else 0;

        return latency + stall;
    }

    fn pending_add(block: *VirtioBlock, head: u16, due_ns: u64) void {
        assert(block.pending_count < pending_max);

        block.pending[block.pending_count] = .{
            .due_ns = due_ns,
            .head = head,
            .sequence = block.sequence,
        };

        block.pending_count += 1;
        block.sequence += 1;
    }

    fn pending_due(block: *const VirtioBlock, now_ns: u64) ?u32 {
        var due: ?u32 = null;

        for (block.pending[0..block.pending_count], 0..) |pending, index| {
            if (pending.due_ns > now_ns) continue;

            if (due) |earliest| {
                if (!pending.before(block.pending[earliest])) continue;
            }

            due = @intCast(index);
        }

        return due;
    }

    fn queue_process(block: *VirtioBlock, memory: []u8, now_ns: u64) bool {
        const queue = &block.queue;
        if (!queue.ready) return false;
        if (queue.num == 0) return false;

        var accepted: u32 = 0;

        while (accepted < queue.num) : (accepted += 1) {
            const avail_idx = guest_u16(memory, queue.avail_addr + 2) orelse break;
            if (avail_idx == queue.avail_last) break;
            if (block.pending_count == pending_max) break;

            const slot = queue.avail_last % queue.num;
            const head = guest_u16(memory, queue.avail_addr + 4 + @as(u64, slot) * 2) orelse break;
            queue.avail_last +%= 1;

            block.pending_add(head, now_ns + block.latency_ns());
        }

        return block.complete_due(memory, now_ns);
    }

    fn request_handle(block: *VirtioBlock, memory: []u8, head: u16, now_ns: u64) u32 {
        var chain: [queue_size_max]Descriptor = undefined;
        const count = block.queue.chain_collect(memory, head, &chain);
        if (count < 2) return 0;

        const header = guest_slice(memory, chain[0].addr, chain[0].len) orelse return 0;
        const status_desc = chain[count - 1];

        if (header.len < request_header_size) return 0;
        if (status_desc.len < 1) return 0;
        if (status_desc.flags & descriptor_flag_write == 0) return 0;

        const request_type = std.mem.readInt(u32, header[0..4], .little);
        const sector = std.mem.readInt(u64, header[8..16], .little);
        const data = chain[1 .. count - 1];
        const failed = block.error_due(request_type, now_ns);
        var written: u32 = 0;

        const status: u8 = if (failed) status_io_error else switch (request_type) {
            request_in => block.transfer(memory, sector, data, .to_guest, &written),
            request_out => block.transfer(memory, sector, data, .to_image, &written),
            request_flush => block.flush(),
            request_get_id => identity_write(memory, data, &written),
            else => status_unsupported,
        };

        const status_slice = guest_slice(memory, status_desc.addr, 1) orelse return written;
        status_slice[0] = status;

        return written + 1;
    }

    fn status_write(block: *VirtioBlock, value: u32) void {
        if (value == 0) {
            block.queue = .{};
            block.interrupt_status = 0;
            block.driver_features = 0;
            block.pending_count = 0;
        }

        block.status = value;
    }

    fn transfer(
        block: *VirtioBlock,
        memory: []u8,
        sector: u64,
        data: []const Descriptor,
        direction: Direction,
        written: *u32,
    ) u8 {
        var offset = sector * sector_size;

        for (data) |descriptor| {
            if (offset + descriptor.len > block.image.len) return status_io_error;

            const guest = guest_slice(memory, descriptor.addr, descriptor.len) orelse {
                return status_io_error;
            };

            const image = block.image[offset..][0..descriptor.len];

            switch (direction) {
                .to_guest => {
                    if (descriptor.flags & descriptor_flag_write == 0) return status_io_error;

                    @memcpy(guest, image);
                    written.* += descriptor.len;
                },
                .to_image => {
                    block.log.record(block.image, offset, descriptor.len);
                    @memcpy(image, guest);
                },
            }

            offset += descriptor.len;
        }

        return status_ok;
    }

    pub fn complete_due(block: *VirtioBlock, memory: []u8, now_ns: u64) bool {
        var completed: u32 = 0;

        while (completed < pending_max) : (completed += 1) {
            const index = block.pending_due(now_ns) orelse break;
            const head = block.pending[index].head;

            block.pending[index] = block.pending[block.pending_count - 1];
            block.pending_count -= 1;

            const written = block.request_handle(memory, head, now_ns);

            block.queue.used_push(memory, head, written);
        }

        if (completed == 0) return false;

        const avail_flags = guest_u16(memory, block.queue.avail_addr) orelse 0;
        const suppress = avail_flags & avail_flag_no_interrupt != 0;
        block.interrupt_status |= interrupt_used_buffer;

        return !suppress;
    }

    pub fn completion_ns_next(block: *const VirtioBlock) ?u64 {
        var next: ?u64 = null;

        for (block.pending[0..block.pending_count]) |pending| {
            next = if (next) |earliest| @min(earliest, pending.due_ns) else pending.due_ns;
        }

        return next;
    }

    pub fn errors_arm(block: *VirtioBlock, now_ns: u64) void {
        if (!block.faults.errors()) {
            block.errors_from_ns = null;

            return;
        }

        const from = now_ns + block.faults.error_delay_ns;

        block.errors_from_ns = from;
        block.errors_until_ns = from + block.faults.error_duration_ns;

        assert(block.errors_until_ns >= from);
        assert(from >= now_ns);
    }

    pub fn power_loss(block: *VirtioBlock) void {
        block.log.power_loss(block.image, &block.stream, block.faults);

        const errors_injected = block.errors_injected;
        const faults = block.faults;
        const image = block.image;
        const log = block.log;
        const stream = block.stream;

        block.* = .{
            .errors_injected = errors_injected,
            .faults = faults,
            .image = image,
            .log = log,
            .stream = stream,
        };

        assert(block.log.count == 0);
        assert(block.pending_count == 0);
        assert(block.errors_from_ns == null);
    }

    pub fn quiet(block: *VirtioBlock) void {
        assert(block.image.len % sector_size == 0);
        assert(block.faults.stall_permille <= permille);

        block.errors_from_ns = null;
        block.faults.stall_ns = 0;
        block.faults.stall_permille = 0;
    }

    pub fn read(block: *const VirtioBlock, offset: u64, data: []u8) void {
        assert(offset + data.len <= mmio_size);
        assert(data.len <= 8);

        if (offset >= config_offset) {
            block.config_read(offset - config_offset, data);

            return;
        }

        const value: u32 = switch (offset) {
            register.magic => magic_value,
            register.version => version_value,
            register.device_id => device_id_block,
            register.vendor_id => vendor_id_value,
            register.device_features => block.device_features_read(),
            register.queue_num_max => queue_size_max,
            register.queue_ready => @intFromBool(block.queue.ready),
            register.interrupt_status => block.interrupt_status,
            register.status => block.status,
            register.config_generation => 0,
            else => 0,
        };

        var bytes: [4]u8 = undefined;

        std.mem.writeInt(u32, &bytes, value, .little);
        @memcpy(data, bytes[0..@min(data.len, 4)]);
    }

    pub fn write(
        block: *VirtioBlock,
        memory: []u8,
        offset: u64,
        data: []const u8,
        now_ns: u64,
    ) bool {
        assert(offset + data.len <= mmio_size);
        assert(data.len <= 8);

        if (offset >= config_offset) return false;
        if (data.len != 4) return false;

        const value = std.mem.readInt(u32, data[0..4], .little);

        switch (offset) {
            register.device_features_select => block.device_features_select = value,
            register.driver_features => block.driver_features_write(value),
            register.driver_features_select => block.driver_features_select = value,
            register.queue_select => block.queue_select = value,
            register.queue_num => if (block.queue_select == 0) {
                block.queue.num = @intCast(@min(value, queue_size_max));
            },
            register.queue_ready => if (block.queue_select == 0) {
                block.queue.ready = value != 0;
            },
            register.queue_notify => return block.queue_process(memory, now_ns),
            register.interrupt_ack => block.interrupt_status &= ~value,
            register.status => block.status_write(value),
            register.queue_desc_low => address_low_set(&block.queue.desc_addr, value),
            register.queue_desc_high => address_high_set(&block.queue.desc_addr, value),
            register.queue_driver_low => address_low_set(&block.queue.avail_addr, value),
            register.queue_driver_high => address_high_set(&block.queue.avail_addr, value),
            register.queue_device_low => address_low_set(&block.queue.used_addr, value),
            register.queue_device_high => address_high_set(&block.queue.used_addr, value),
            else => {},
        }

        return false;
    }
};

const Queue = struct {
    avail_addr: u64 = 0,
    avail_last: u16 = 0,
    desc_addr: u64 = 0,
    num: u16 = 0,
    ready: bool = false,
    used_addr: u64 = 0,

    fn chain_collect(
        queue: *const Queue,
        memory: []const u8,
        head: u16,
        chain: *[queue_size_max]Descriptor,
    ) usize {
        var count: usize = 0;
        var index = head;

        while (count < queue.num) {
            if (index >= queue.num) return 0;

            const descriptor = queue.descriptor_read(memory, index) orelse return 0;
            chain[count] = descriptor;
            count += 1;

            if (descriptor.flags & descriptor_flag_next == 0) return count;

            index = descriptor.next;
        }

        return 0;
    }

    fn descriptor_read(queue: *const Queue, memory: []const u8, index: u16) ?Descriptor {
        const addr = queue.desc_addr + @as(u64, index) * descriptor_size;
        const bytes = guest_slice_const(memory, addr, descriptor_size) orelse return null;

        return .{
            .addr = std.mem.readInt(u64, bytes[0..8], .little),
            .len = std.mem.readInt(u32, bytes[8..12], .little),
            .flags = std.mem.readInt(u16, bytes[12..14], .little),
            .next = std.mem.readInt(u16, bytes[14..16], .little),
        };
    }

    fn used_push(queue: *const Queue, memory: []u8, head: u16, written: u32) void {
        const used_idx = guest_u16(memory, queue.used_addr + 2) orelse return;
        const slot = used_idx % queue.num;
        const entry_addr = queue.used_addr + 4 + @as(u64, slot) * used_entry_size;
        const entry = guest_slice(memory, entry_addr, used_entry_size) orelse return;

        std.mem.writeInt(u32, entry[0..4], head, .little);
        std.mem.writeInt(u32, entry[4..8], written, .little);

        const idx_slice = guest_slice(memory, queue.used_addr + 2, 2) orelse return;

        std.mem.writeInt(u16, idx_slice[0..2], used_idx +% 1, .little);
    }
};

const Descriptor = struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const Direction = enum {
    to_guest,
    to_image,
};

const Pending = struct {
    due_ns: u64,
    head: u16,
    sequence: u64,

    fn before(pending: Pending, other: Pending) bool {
        if (pending.due_ns != other.due_ns) return pending.due_ns < other.due_ns;
        return pending.sequence < other.sequence;
    }
};

const register = struct {
    const magic = 0x000;
    const version = 0x004;
    const device_id = 0x008;
    const vendor_id = 0x00c;
    const device_features = 0x010;
    const device_features_select = 0x014;
    const driver_features = 0x020;
    const driver_features_select = 0x024;
    const queue_select = 0x030;
    const queue_num_max = 0x034;
    const queue_num = 0x038;
    const queue_ready = 0x044;
    const queue_notify = 0x050;
    const interrupt_status = 0x060;
    const interrupt_ack = 0x064;
    const status = 0x070;
    const queue_desc_low = 0x080;
    const queue_desc_high = 0x084;
    const queue_driver_low = 0x090;
    const queue_driver_high = 0x094;
    const queue_device_low = 0x0a0;
    const queue_device_high = 0x0a4;
    const config_generation = 0x0fc;
};

pub const irq = 5;
pub const mmio_base = 0xd0000000;
pub const mmio_size = 0x1000;
pub const sector_size = 512;
const avail_flag_no_interrupt = 0x1;
const config_offset = 0x100;
const config_size = 8;
const descriptor_flag_next = 0x1;
const descriptor_flag_write = 0x2;
const descriptor_size = 16;
const device_id_block = 2;
const feature_flush: u64 = 1 << 9;
const feature_version_1: u64 = 1 << 32;
const device_features = feature_version_1 | feature_flush;
const identity = "celeste";
const interrupt_used_buffer = 0x1;
const magic_value = 0x74726976;
const pending_max = queue_size_max;
const permille = faults_module.permille;
const queue_size_max = 256;
const request_flush = 4;
const request_get_id = 8;
const request_header_size = 16;
const request_in = 0;
const request_out = 1;
const status_io_error = 1;
const status_ok = 0;
const status_unsupported = 2;
const used_entry_size = 8;
const vendor_id_value = 0x48595056;
const version_value = 2;

comptime {
    assert(mmio_base % kvm.page_size == 0);
    assert(mmio_size >= config_offset + config_size);
    assert(irq < 16);
}

fn address_high_set(address: *u64, value: u32) void {
    address.* = (address.* & 0xffffffff) | (@as(u64, value) << 32);
}

fn address_low_set(address: *u64, value: u32) void {
    address.* = (address.* & 0xffffffff_00000000) | value;
}

fn guest_slice(memory: []u8, addr: u64, len: u64) ?[]u8 {
    if (addr > memory.len) return null;
    if (len > memory.len - addr) return null;
    return memory[@intCast(addr)..][0..@intCast(len)];
}

fn guest_slice_const(memory: []const u8, addr: u64, len: u64) ?[]const u8 {
    if (addr > memory.len) return null;
    if (len > memory.len - addr) return null;
    return memory[@intCast(addr)..][0..@intCast(len)];
}

fn guest_u16(memory: []const u8, addr: u64) ?u16 {
    const bytes = guest_slice_const(memory, addr, 2) orelse return null;
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn sector_mask(sector: u64) u64 {
    return @as(u64, 1) << @intCast(sector % 64);
}

test "a read request copies sectors into the guest and completes with status ok" {
    var image: [sector_size * 4]u8 = undefined;

    for (&image, 0..) |*byte, i| byte.* = @truncate(i / sector_size + 1);

    var memory: [0x3000]u8 = @splat(0);
    var block: VirtioBlock = .{ .image = &image };

    try std.testing.expectEqual(@as(u64, 4), capacity_read(&block));

    _ = block.write(&memory, register.queue_num, &le32(4), 0);
    _ = block.write(&memory, register.queue_desc_low, &le32(0x1000), 0);
    _ = block.write(&memory, register.queue_driver_low, &le32(0x1800), 0);
    _ = block.write(&memory, register.queue_device_low, &le32(0x1c00), 0);
    _ = block.write(&memory, register.queue_ready, &le32(1), 0);

    std.mem.writeInt(u32, memory[0x2000..][0..4], request_in, .little);
    std.mem.writeInt(u64, memory[0x2008..][0..8], 2, .little);
    chain_write(&memory, 1024, descriptor_flag_next | descriptor_flag_write);
    memory[0x2010] = 0xff;

    std.mem.writeInt(u16, memory[0x1804..][0..2], 0, .little);
    std.mem.writeInt(u16, memory[0x1802..][0..2], 1, .little);

    const notified = block.write(&memory, register.queue_notify, &le32(0), 0);

    try std.testing.expect(notified);
    try std.testing.expectEqual(@as(u8, status_ok), memory[0x2010]);
    try std.testing.expectEqual(@as(u8, 3), memory[0x2400]);
    try std.testing.expectEqual(@as(u8, 4), memory[0x2400 + 512]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, memory[0x1c02..][0..2], .little));
    const used_len = std.mem.readInt(u32, memory[0x1c08..][0..4], .little);

    try std.testing.expectEqual(@as(u32, 1025), used_len);
    try std.testing.expectEqual(@as(u32, interrupt_used_buffer), block.interrupt_status);

    _ = block.write(&memory, register.interrupt_ack, &le32(interrupt_used_buffer), 0);

    try std.testing.expectEqual(@as(u32, 0), block.interrupt_status);

    const renotified = block.write(&memory, register.queue_notify, &le32(0), 0);

    try std.testing.expect(!renotified);
}

test "a write past the end of the image fails with an io error and leaves the image intact" {
    var image: [sector_size]u8 = @splat(0xaa);
    var memory: [0x3000]u8 = @splat(0);
    var block: VirtioBlock = .{ .image = &image };

    _ = block.write(&memory, register.queue_num, &le32(4), 0);
    _ = block.write(&memory, register.queue_desc_low, &le32(0x1000), 0);
    _ = block.write(&memory, register.queue_driver_low, &le32(0x1800), 0);
    _ = block.write(&memory, register.queue_device_low, &le32(0x1c00), 0);
    _ = block.write(&memory, register.queue_ready, &le32(1), 0);

    std.mem.writeInt(u32, memory[0x2000..][0..4], request_out, .little);
    std.mem.writeInt(u64, memory[0x2008..][0..8], 1, .little);
    chain_write(&memory, 512, descriptor_flag_next);
    std.mem.writeInt(u16, memory[0x1802..][0..2], 1, .little);

    const notified = block.write(&memory, register.queue_notify, &le32(0), 0);

    try std.testing.expect(notified);
    try std.testing.expectEqual(@as(u8, status_io_error), memory[0x2010]);
    try std.testing.expectEqual(@as(u8, 0xaa), image[0]);
}

test "a flushed write survives power loss and an unflushed one reverts" {
    var image: [sector_size * 8]u8 = @splat(0xaa);
    var memory: [test_memory_size]u8 = @splat(0);
    var entries: [8]LogEntry = undefined;
    var logged: [1]u64 = @splat(0);

    var block: VirtioBlock = .{
        .faults = .{ .persist_permille = 0 },
        .image = &image,
        .log = .{ .entries = &entries, .logged = &logged },
    };

    test_queue_ready(&block, &memory);
    test_write_submit(&memory, 0, 2, 1, 0xbb);

    try std.testing.expect(test_notify(&block, &memory, 0));
    try std.testing.expectEqual(@as(u8, 0xbb), image[2 * sector_size]);

    block.power_loss();

    try std.testing.expectEqual(@as(u8, 0xaa), image[2 * sector_size]);

    @memset(&memory, 0);
    test_queue_ready(&block, &memory);
    test_write_submit(&memory, 0, 2, 1, 0xbb);
    test_submit(&memory, 1, request_flush, 0, 0);

    try std.testing.expect(test_notify(&block, &memory, 0));

    block.power_loss();

    try std.testing.expectEqual(@as(u8, 0xbb), image[2 * sector_size]);
    try std.testing.expectEqual(@as(u8, 0xaa), image[3 * sector_size]);
}

test "power loss keeps or reverts each atomic unit whole across seeds" {
    for ([_]u32{ 1, 8 }) |atomic_sectors| {
        var kept: u32 = 0;
        var reverted: u32 = 0;

        for (0..64) |seed| {
            var image: [sector_size * 64]u8 = @splat(0xaa);
            var memory: [test_memory_size]u8 = @splat(0);
            var entries: [64]LogEntry = undefined;
            var logged: [1]u64 = @splat(0);

            var block: VirtioBlock = .{
                .faults = .{ .atomic_sectors = atomic_sectors, .persist_permille = 500 },
                .image = &image,
                .log = .{ .entries = &entries, .logged = &logged },
                .stream = .init(seed),
            };

            test_queue_ready(&block, &memory);

            for (0..4) |slot| test_write_submit(&memory, @intCast(slot), slot * 8, 8, 0xbb);

            _ = test_notify(&block, &memory, 0);

            block.power_loss();

            const unit_size = atomic_sectors * sector_size;

            for (0..32 / atomic_sectors) |unit| {
                const bytes = image[unit * unit_size ..][0..unit_size];

                if (std.mem.allEqual(u8, bytes, 0xbb)) {
                    kept += 1;
                } else {
                    try std.testing.expect(std.mem.allEqual(u8, bytes, 0xaa));
                    reverted += 1;
                }
            }

            try std.testing.expect(std.mem.allEqual(u8, image[32 * sector_size ..], 0xaa));
        }

        try std.testing.expect(kept > 0);
        try std.testing.expect(reverted > 0);
    }
}

test "completions never arrive before they are due and latency reorders them" {
    var reordered: u32 = 0;

    for (0..32) |seed| {
        var image: [sector_size * 16]u8 = @splat(0xaa);
        var memory: [test_memory_size]u8 = @splat(0);

        var block: VirtioBlock = .{
            .faults = .{ .latency_ns_max = 1000 },
            .image = &image,
            .stream = .init(seed),
        };

        test_queue_ready(&block, &memory);

        for (0..4) |slot| test_submit(&memory, @intCast(slot), request_in, slot, 1);

        _ = test_notify(&block, &memory, 0);

        var now: u64 = 0;

        for (0..4) |_| {
            const next = block.completion_ns_next() orelse break;

            try std.testing.expect(next > now);
            try std.testing.expect(!block.complete_due(&memory, next - 1));
            try std.testing.expect(block.complete_due(&memory, next));

            now = next;
        }

        try std.testing.expectEqual(@as(?u64, null), block.completion_ns_next());
        try std.testing.expectEqual(@as(u16, 4), test_used_count(&memory));

        for (0..4) |entry| {
            const head = test_used_head(&memory, entry);

            if (head != entry * 3) reordered += 1;
        }
    }

    try std.testing.expect(reordered > 0);
}

test "a full log writes back what it holds and keeps recording" {
    var image: [sector_size * 32]u8 = @splat(0xaa);
    var memory: [test_memory_size]u8 = @splat(0);
    var entries: [2]LogEntry = undefined;
    var logged: [1]u64 = @splat(0);

    var block: VirtioBlock = .{
        .faults = .{ .atomic_sectors = 1, .persist_permille = 0 },
        .image = &image,
        .log = .{ .entries = &entries, .logged = &logged },
    };

    test_queue_ready(&block, &memory);

    for (0..3) |slot| test_write_submit(&memory, @intCast(slot), slot, 1, 0xbb);

    try std.testing.expect(test_notify(&block, &memory, 0));
    try std.testing.expectEqual(@as(u64, 1), block.log.overflows);
    try std.testing.expectEqual(@as(u32, 1), block.log.count);

    block.power_loss();

    try std.testing.expect(std.mem.allEqual(u8, image[0 .. 2 * sector_size], 0xbb));
    try std.testing.expect(std.mem.allEqual(u8, image[2 * sector_size ..], 0xaa));
}

test "power loss drops requests still in flight and resets the device" {
    var image: [sector_size * 8]u8 = @splat(0xaa);
    var memory: [test_memory_size]u8 = @splat(0);

    var block: VirtioBlock = .{
        .faults = .{ .stall_ns = 1_000_000, .stall_permille = permille },
        .image = &image,
    };

    test_queue_ready(&block, &memory);
    test_write_submit(&memory, 0, 1, 1, 0xbb);

    try std.testing.expect(!test_notify(&block, &memory, 0));
    try std.testing.expectEqual(@as(?u64, 1_000_000), block.completion_ns_next());
    try std.testing.expectEqual(@as(u8, 0xaa), image[sector_size]);

    block.power_loss();

    try std.testing.expectEqual(@as(?u64, null), block.completion_ns_next());
    try std.testing.expectEqual(@as(u32, 0), block.status);
    try std.testing.expect(!block.queue.ready);
    try std.testing.expect(std.mem.allEqual(u8, &image, 0xaa));
}

test "an injected error fails only requests inside the window and changes nothing" {
    var image: [sector_size * 8]u8 = @splat(0xaa);
    var memory: [test_memory_size]u8 = @splat(0);
    var entries: [8]LogEntry = undefined;
    var logged: [1]u64 = @splat(0);

    var block: VirtioBlock = .{
        .faults = .{
            .error_delay_ns = 100,
            .error_duration_ns = 1000,
            .error_read_permille = permille,
            .error_write_permille = permille,
            .persist_permille = 0,
        },
        .image = &image,
        .log = .{ .entries = &entries, .logged = &logged },
    };

    block.errors_arm(0);
    test_queue_ready(&block, &memory);
    test_write_submit(&memory, 0, 1, 1, 0xbb);

    try std.testing.expect(test_notify(&block, &memory, 99));
    try std.testing.expectEqual(@as(u8, status_ok), test_status(&memory, 0));
    try std.testing.expectEqual(@as(u8, 0xbb), image[sector_size]);

    test_write_submit(&memory, 1, 2, 1, 0xcc);
    test_submit(&memory, 2, request_in, 1, 1);
    @memset(memory[test_data + 0x2000 ..][0..sector_size], 0xee);

    try std.testing.expect(test_notify(&block, &memory, 100));
    try std.testing.expectEqual(@as(u8, status_io_error), test_status(&memory, 1));
    try std.testing.expectEqual(@as(u8, status_io_error), test_status(&memory, 2));
    try std.testing.expectEqual(@as(u8, 0xaa), image[2 * sector_size]);
    try std.testing.expectEqual(@as(u8, 0xee), memory[test_data + 0x2000]);
    try std.testing.expectEqual(@as(u32, 1), block.log.count);

    test_write_submit(&memory, 3, 3, 1, 0xdd);

    try std.testing.expect(test_notify(&block, &memory, 1100));
    try std.testing.expectEqual(@as(u8, status_ok), test_status(&memory, 3));
    try std.testing.expectEqual(@as(u8, 0xdd), image[3 * sector_size]);
    try std.testing.expectEqual(@as(u64, 2), block.errors_injected);

    block.power_loss();

    try std.testing.expectEqual(@as(?u64, null), block.errors_from_ns);
    try std.testing.expectEqual(@as(u64, 2), block.errors_injected);
    try std.testing.expect(std.mem.allEqual(u8, &image, 0xaa));
}

test "a failed flush keeps the volatile log so a power loss can still revert" {
    var image: [sector_size * 8]u8 = @splat(0xaa);
    var memory: [test_memory_size]u8 = @splat(0);
    var entries: [8]LogEntry = undefined;
    var logged: [1]u64 = @splat(0);

    var block: VirtioBlock = .{
        .faults = .{
            .error_duration_ns = 1000,
            .error_write_permille = permille,
            .persist_permille = 0,
        },
        .image = &image,
        .log = .{ .entries = &entries, .logged = &logged },
    };

    test_queue_ready(&block, &memory);
    test_write_submit(&memory, 0, 4, 1, 0xbb);

    try std.testing.expect(test_notify(&block, &memory, 0));

    block.errors_arm(0);
    test_submit(&memory, 1, request_flush, 0, 0);

    try std.testing.expect(test_notify(&block, &memory, 10));
    try std.testing.expectEqual(@as(u8, status_io_error), test_status(&memory, 1));
    try std.testing.expectEqual(@as(u32, 1), block.log.count);

    block.power_loss();

    try std.testing.expectEqual(@as(u8, 0xaa), image[4 * sector_size]);
}

const test_avail = 0x2000;
const test_data = 0x8000;
const test_desc = 0x1000;
const test_header = 0x4000;
const test_memory_size = 0x20000;
const test_queue_num = 64;
const test_used = 0x3000;

fn capacity_read(block: *const VirtioBlock) u64 {
    var bytes: [8]u8 = undefined;

    block.read(config_offset, &bytes);

    return std.mem.readInt(u64, &bytes, .little);
}

fn chain_write(memory: []u8, data_len: u32, data_flags: u16) void {
    const header: Descriptor = .{
        .addr = 0x2000,
        .len = 16,
        .flags = descriptor_flag_next,
        .next = 1,
    };

    const data: Descriptor = .{ .addr = 0x2400, .len = data_len, .flags = data_flags, .next = 2 };

    const status: Descriptor = .{
        .addr = 0x2010,
        .len = 1,
        .flags = descriptor_flag_write,
        .next = 0,
    };

    descriptor_write(memory, 0x1000, 0, header);
    descriptor_write(memory, 0x1000, 1, data);
    descriptor_write(memory, 0x1000, 2, status);
}

fn descriptor_write(memory: []u8, table: u64, index: u16, descriptor: Descriptor) void {
    const bytes = memory[table + index * descriptor_size ..][0..descriptor_size];

    std.mem.writeInt(u64, bytes[0..8], descriptor.addr, .little);
    std.mem.writeInt(u32, bytes[8..12], descriptor.len, .little);
    std.mem.writeInt(u16, bytes[12..14], descriptor.flags, .little);
    std.mem.writeInt(u16, bytes[14..16], descriptor.next, .little);
}

fn le32(value: u32) [4]u8 {
    var bytes: [4]u8 = undefined;

    std.mem.writeInt(u32, &bytes, value, .little);

    return bytes;
}

fn test_notify(block: *VirtioBlock, memory: []u8, now_ns: u64) bool {
    return block.write(memory, register.queue_notify, &le32(0), now_ns);
}

fn test_queue_ready(block: *VirtioBlock, memory: []u8) void {
    _ = block.write(memory, register.queue_num, &le32(test_queue_num), 0);
    _ = block.write(memory, register.queue_desc_low, &le32(test_desc), 0);
    _ = block.write(memory, register.queue_driver_low, &le32(test_avail), 0);
    _ = block.write(memory, register.queue_device_low, &le32(test_used), 0);
    _ = block.write(memory, register.queue_ready, &le32(1), 0);
}

fn test_status(memory: []const u8, slot: u16) u8 {
    return memory[test_header + @as(u64, slot) * 0x40 + 0x20];
}

fn test_submit(memory: []u8, slot: u16, request_type: u32, sector: u64, sectors: u32) void {
    assert(slot * 3 + 2 < test_queue_num);

    const head = slot * 3;
    const header = test_header + @as(u64, slot) * 0x40;
    const data = test_data + @as(u64, slot) * 0x1000;
    const data_write: u16 = if (request_type == request_in) descriptor_flag_write else 0;
    const status_index = if (sectors == 0) head + 1 else head + 2;

    std.mem.writeInt(u32, memory[header..][0..4], request_type, .little);
    std.mem.writeInt(u64, memory[header + 8 ..][0..8], sector, .little);
    memory[header + 0x20] = 0xff;

    descriptor_write(memory, test_desc, head, .{
        .addr = header,
        .len = request_header_size,
        .flags = descriptor_flag_next,
        .next = head + 1,
    });

    if (sectors > 0) {
        descriptor_write(memory, test_desc, head + 1, .{
            .addr = data,
            .len = sectors * sector_size,
            .flags = descriptor_flag_next | data_write,
            .next = head + 2,
        });
    }

    descriptor_write(memory, test_desc, status_index, .{
        .addr = header + 0x20,
        .len = 1,
        .flags = descriptor_flag_write,
        .next = 0,
    });

    const avail_idx = std.mem.readInt(u16, memory[test_avail + 2 ..][0..2], .little);
    const ring_offset = test_avail + 4 + @as(u64, avail_idx % test_queue_num) * 2;

    std.mem.writeInt(u16, memory[ring_offset..][0..2], head, .little);
    std.mem.writeInt(u16, memory[test_avail + 2 ..][0..2], avail_idx +% 1, .little);
}

fn test_used_count(memory: []const u8) u16 {
    return std.mem.readInt(u16, memory[test_used + 2 ..][0..2], .little);
}

fn test_used_head(memory: []const u8, entry: u64) u32 {
    return std.mem.readInt(u32, memory[test_used + 4 + entry * used_entry_size ..][0..4], .little);
}

fn test_write_submit(memory: []u8, slot: u16, sector: u64, sectors: u32, fill: u8) void {
    @memset(memory[test_data + @as(u64, slot) * 0x1000 ..][0 .. sectors * sector_size], fill);
    test_submit(memory, slot, request_out, sector, sectors);
}
