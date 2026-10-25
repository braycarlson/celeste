const std = @import("std");

const kvm = @import("kvm.zig");

const assert = std.debug.assert;

pub const Error = error{HostUnsupported};

pub const Missing = struct {
    bits: u32 = 0,
    function: u32 = 0,
    register: []const u8 = "",
};

const Leaf = struct {
    eax: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    function: u32,
    index: u32 = 0,
    indexed: bool = false,

    fn entry(leaf: Leaf) kvm.CpuidEntry2 {
        return .{
            .function = leaf.function,
            .index = leaf.index,
            .flags = if (leaf.indexed) flag_significant_index else 0,
            .eax = leaf.eax,
            .ebx = leaf.ebx,
            .ecx = leaf.ecx,
            .edx = leaf.edx,
            .padding = .{ 0, 0, 0 },
        };
    }
};

const Requirement = struct {
    eax: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    function: u32,
    index: u32 = 0,
};

const address_bits_physical = 39;
const address_bits_virtual = 48;
const brand = "DST Virtual CPU";
const flag_significant_index = 0x1;
const leaf_max_basic = 0xd;
const leaf_max_extended = 0x80000008;
const vendor_ebx = 0x756e6547;
const vendor_ecx = 0x6c65746e;
const vendor_edx = 0x49656e69;
const version_family = 6;
const version_model = 0x6f;
const xcr0_supported: u32 = 0x7;
const xsave_size = 576 + 256;

const leaf1_ecx: u32 = bit(0) | bit(1) | bit(9) | bit(12) | bit(13) | bit(17) | bit(19) |
    bit(20) | bit(22) | bit(23) | bit(25) | bit(26) | bit(28) | bit(29);

const leaf1_edx: u32 = bit(0) | bit(1) | bit(2) | bit(3) | bit(5) | bit(6) | bit(8) |
    bit(11) | bit(12) | bit(13) | bit(15) | bit(16) | bit(17) | bit(19) | bit(23) | bit(24) |
    bit(25) | bit(26);

const leaf7_ebx: u32 = bit(0) | bit(3) | bit(5) | bit(7) | bit(8) | bit(9) | bit(10) |
    bit(19) | bit(20) | bit(23);

const leaf80000001_ecx: u32 = bit(0) | bit(5) | bit(8);
const leaf80000001_edx: u32 = bit(11) | bit(20) | bit(26) | bit(27) | bit(29);

const requirements = [_]Requirement{
    .{ .function = 1, .ecx = leaf1_ecx, .edx = leaf1_edx },
    .{ .function = 7, .ebx = leaf7_ebx },
    .{ .function = 0xd, .eax = xcr0_supported },
    .{ .function = 0x80000001, .ecx = leaf80000001_ecx, .edx = leaf80000001_edx },
};

const leaves = [_]Leaf{
    .{
        .function = 0,
        .eax = leaf_max_basic,
        .ebx = vendor_ebx,
        .ecx = vendor_ecx,
        .edx = vendor_edx,
    },
    .{
        .function = 1,
        .eax = version_family << 8 | (version_model & 0xf) << 4 | (version_model >> 4) << 16,
        .ebx = 8 << 8 | 1 << 16,
        .ecx = leaf1_ecx,
        .edx = leaf1_edx,
    },
    .{ .function = 2, .eax = 0x0000ff01 },
    .{ .function = 3 },
    cache(0, 1, 1, 8, 64),
    cache(1, 2, 1, 8, 64),
    cache(2, 3, 2, 8, 2048),
    cache(3, 3, 3, 16, 32768),
    .{ .function = 4, .index = 4, .indexed = true },
    .{ .function = 5 },
    .{ .function = 6 },
    .{ .function = 7, .indexed = true, .ebx = leaf7_ebx },
    .{ .function = 8 },
    .{ .function = 9 },
    .{ .function = 0xa },
    .{ .function = 0xb, .indexed = true, .ebx = 1, .ecx = 1 << 8 },
    .{ .function = 0xb, .index = 1, .indexed = true, .ebx = 1, .ecx = 2 << 8 | 1 },
    .{ .function = 0xb, .index = 2, .indexed = true, .ecx = 2 },
    .{ .function = 0xc },
    .{
        .function = 0xd,
        .indexed = true,
        .eax = xcr0_supported,
        .ebx = xsave_size,
        .ecx = xsave_size,
    },
    .{ .function = 0xd, .index = 1, .indexed = true, .eax = bit(0) },
    .{ .function = 0xd, .index = 2, .indexed = true, .eax = 256, .ebx = 576 },
    .{ .function = 0x80000000, .eax = leaf_max_extended },
    .{ .function = 0x80000001, .ecx = leaf80000001_ecx, .edx = leaf80000001_edx },
    brand_leaf(0),
    brand_leaf(1),
    brand_leaf(2),
    .{ .function = 0x80000005 },
    .{ .function = 0x80000006, .ecx = 1024 << 16 | 0x6 << 12 | 64 },
    .{ .function = 0x80000007 },
    .{ .function = 0x80000008, .eax = address_bits_virtual << 8 | address_bits_physical },
};

comptime {
    assert(leaves.len <= kvm.cpuid_entries_max);
    assert(brand.len < 48);
}

fn addresses_missing(missing: *Missing, eax: u32) error{HostUnsupported} {
    missing.* = .{ .function = 0x80000008, .register = "eax", .bits = eax };

    assert(missing.function == 0x80000008);
    assert(missing.bits == eax);

    return error.HostUnsupported;
}

fn bit(comptime position: u5) u32 {
    return @as(u32, 1) << position;
}

fn brand_leaf(comptime part: u32) Leaf {
    var bytes: [48]u8 = @splat(0);

    @memcpy(bytes[0..brand.len], brand);

    const chunk = bytes[part * 16 ..][0..16];

    return .{
        .function = 0x80000002 + part,
        .eax = std.mem.readInt(u32, chunk[0..4], .little),
        .ebx = std.mem.readInt(u32, chunk[4..8], .little),
        .ecx = std.mem.readInt(u32, chunk[8..12], .little),
        .edx = std.mem.readInt(u32, chunk[12..16], .little),
    };
}

fn cache(
    comptime index: u32,
    comptime kind: u32,
    comptime level: u32,
    comptime ways: u32,
    comptime sets: u32,
) Leaf {
    return .{
        .function = 4,
        .index = index,
        .indexed = true,
        .eax = kind | level << 5 | bit(8),
        .ebx = (ways - 1) << 22 | (64 - 1),
        .ecx = sets - 1,
    };
}

fn host_check(host: *const kvm.Cpuid2, missing: *Missing) Error!void {
    const vendor = host_find(host, 0, 0) orelse return error.HostUnsupported;
    const vendor_match = vendor.ebx == vendor_ebx and vendor.ecx == vendor_ecx;
    const intel = vendor_match and vendor.edx == vendor_edx;

    if (!intel) {
        missing.* = .{ .register = "vendor" };

        return error.HostUnsupported;
    }

    for (requirements) |requirement| {
        const entry = host_find(host, requirement.function, requirement.index) orelse {
            missing.* = .{ .function = requirement.function, .register = "leaf" };

            return error.HostUnsupported;
        };

        try requirement_check(requirement, entry, missing);
    }

    const addresses = host_find(host, 0x80000008, 0) orelse return error.HostUnsupported;
    const physical = addresses.eax & 0xff;
    const virtual = addresses.eax >> 8 & 0xff;

    if (physical < address_bits_physical) return addresses_missing(missing, addresses.eax);
    if (virtual < address_bits_virtual) return addresses_missing(missing, addresses.eax);
}

fn host_find(host: *const kvm.Cpuid2, function: u32, index: u32) ?kvm.CpuidEntry2 {
    for (host.entries[0..host.nent]) |entry| {
        if (entry.function != function) continue;
        if (entry.index == index) return entry;
    }

    return null;
}

fn requirement_check(
    requirement: Requirement,
    entry: kvm.CpuidEntry2,
    missing: *Missing,
) Error!void {
    const absent = [_]u32{
        requirement.eax & ~entry.eax,
        requirement.ebx & ~entry.ebx,
        requirement.ecx & ~entry.ecx,
        requirement.edx & ~entry.edx,
    };

    for (absent, [_][]const u8{ "eax", "ebx", "ecx", "edx" }) |bits, register| {
        if (bits == 0) continue;

        missing.* = .{ .bits = bits, .function = requirement.function, .register = register };

        return error.HostUnsupported;
    }
}

pub fn model(host: *const kvm.Cpuid2, out: *kvm.Cpuid2, missing: *Missing) Error!void {
    assert(host.nent <= kvm.cpuid_entries_max);

    try host_check(host, missing);

    out.nent = leaves.len;
    out.padding = 0;

    for (leaves, out.entries[0..leaves.len]) |leaf, *entry| entry.* = leaf.entry();

    assert(out.nent > 0);
}

pub fn processor_set(cpuid: *kvm.Cpuid2, apic_id: u8, cpus: u8) void {
    const core_bits: u32 = std.math.log2_int_ceil(u8, cpus);

    assert(cpus >= 1);
    assert(apic_id < cpus);

    if (cpus == 1) return;

    for (cpuid.entries[0..cpuid.nent]) |*entry| {
        switch (entry.function) {
            1 => {
                entry.ebx = (entry.ebx & 0xffff) | @as(u32, cpus) << 16 | @as(u32, apic_id) << 24;
                entry.edx |= bit(9) | bit(28);
            },
            4 => if (entry.eax != 0) {
                entry.eax = (entry.eax & 0x03ff_ffff) | @as(u32, cpus - 1) << 26;
            },
            0xb => {
                entry.edx = apic_id;

                if (entry.index == 1) {
                    entry.eax = core_bits;
                    entry.ebx = cpus;
                }
            },
            else => {},
        }
    }
}

test "the model is the same table whatever the host adds on top of the baseline" {
    var first: kvm.Cpuid2 = undefined;
    var second: kvm.Cpuid2 = undefined;
    var host: kvm.Cpuid2 = undefined;
    var missing: Missing = .{};

    test_host(&host);
    try model(&host, &first, &missing);

    host.entries[1].eax = 0x000b0671 + 0x10;
    host.entries[1].ecx |= bit(30) | bit(31);
    host.entries[2].ebx |= bit(18);
    host.entries[2].ecx |= bit(5);
    host.entries[3].eax = 0xffff;

    try model(&host, &second, &missing);

    try std.testing.expectEqual(first.nent, second.nent);

    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(first.entries[0..first.nent]),
        std.mem.sliceAsBytes(second.entries[0..second.nent]),
    );
}

test "the model hides time, entropy, and hypervisor features and reports one thread" {
    var host: kvm.Cpuid2 = undefined;
    var out: kvm.Cpuid2 = undefined;
    var missing: Missing = .{};

    test_host(&host);
    try model(&host, &out, &missing);

    const hidden = bit(3) | bit(21) | bit(24) | bit(30) | bit(31);
    const leaf1 = host_find(&out, 1, 0).?;
    const leaf7 = host_find(&out, 7, 0).?;

    try std.testing.expectEqual(@as(u32, 0), leaf1.edx & bit(4));
    try std.testing.expectEqual(@as(u32, 0), leaf1.ecx & hidden);
    try std.testing.expectEqual(@as(u32, 0), leaf7.ebx & bit(18));
    try std.testing.expectEqual(@as(u32, 0), leaf7.ecx & bit(5));
    try std.testing.expectEqual(@as(u32, 0), leaf7.edx);
    try std.testing.expectEqual(@as(?kvm.CpuidEntry2, null), host_find(&out, 0x40000000, 0));
    try std.testing.expectEqual(@as(u32, 1), (leaf1.ebx >> 16) & 0xff);
    try std.testing.expectEqual(@as(u32, 0), host_find(&out, 0x80000007, 0).?.edx);
}

test "a processor gets its apic id, the apic bit, and a core count only when there are several" {
    var host: kvm.Cpuid2 = undefined;
    var single: kvm.Cpuid2 = undefined;
    var plain: kvm.Cpuid2 = undefined;
    var shared: kvm.Cpuid2 = undefined;
    var missing: Missing = .{};

    test_host(&host);
    try model(&host, &plain, &missing);
    try model(&host, &single, &missing);
    try model(&host, &shared, &missing);
    processor_set(&single, 0, 1);
    processor_set(&shared, 2, 4);

    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(plain.entries[0..plain.nent]),
        std.mem.sliceAsBytes(single.entries[0..single.nent]),
    );

    for (shared.entries[0..shared.nent]) |entry| {
        if (entry.function == 1) {
            try std.testing.expectEqual(2, entry.ebx >> 24);
            try std.testing.expectEqual(4, entry.ebx >> 16 & 0xff);
            try std.testing.expect(entry.edx & bit(9) != 0);
        }

        if (entry.function == 0xb) {
            try std.testing.expectEqual(2, entry.edx);

            if (entry.index == 1) {
                try std.testing.expectEqual(2, entry.eax);
                try std.testing.expectEqual(4, entry.ebx);
            }
        }

        if (entry.function == 4) {
            if (entry.eax != 0) try std.testing.expectEqual(3, entry.eax >> 26);
        }
    }
}

test "a host without AVX2 or an AMD host is refused" {
    var host: kvm.Cpuid2 = undefined;
    var out: kvm.Cpuid2 = undefined;
    var missing: Missing = .{};

    test_host(&host);
    host.entries[2].ebx &= ~bit(5);

    try std.testing.expectError(error.HostUnsupported, model(&host, &out, &missing));
    try std.testing.expectEqual(@as(u32, 7), missing.function);
    try std.testing.expectEqualStrings("ebx", missing.register);
    try std.testing.expectEqual(bit(5), missing.bits);

    test_host(&host);
    host.entries[0].ebx = 0x68747541;

    try std.testing.expectError(error.HostUnsupported, model(&host, &out, &missing));
    try std.testing.expectEqualStrings("vendor", missing.register);
}

fn test_host(host: *kvm.Cpuid2) void {
    const entries = [_]Leaf{
        .{ .function = 0, .eax = 0x20, .ebx = vendor_ebx, .ecx = vendor_ecx, .edx = vendor_edx },
        .{
            .function = 1,
            .eax = 0x000b0671,
            .ebx = 0x21800800,
            .ecx = 0xf7fa3223,
            .edx = 0x0f8bfbff,
        },
        .{
            .function = 7,
            .indexed = true,
            .ebx = 0x219c27eb,
            .ecx = 0x184007ac,
            .edx = 0xbc104410,
        },
        .{ .function = 0xd, .indexed = true, .eax = 0x207, .ebx = 0xa88, .ecx = 0xa88 },
        .{ .function = 0x80000001, .ecx = 0x121, .edx = 0x2c100800 },
        .{ .function = 0x80000008, .eax = 0x302e, .ebx = 0x0100d000 },
    };

    host.nent = entries.len;
    host.padding = 0;

    for (entries, host.entries[0..entries.len]) |leaf, *entry| entry.* = leaf.entry();
}
