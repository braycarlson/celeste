const std = @import("std");

const amd = @import("model_amd.zig");
const intel = @import("model_intel.zig");
const kvm = @import("kvm.zig");

const assert = std.debug.assert;

pub const Error = error{HostUnsupported};

pub const Missing = struct {
    bits: u32 = 0,
    function: u32 = 0,
    register: []const u8 = "",
};

pub const Vendor = enum {
    amd,
    intel,
};

pub const Vendors = struct {
    guest: Vendor,
    host: Vendor,
};

pub const Cache = struct {
    kind: u32,
    level: u32,
    sets: u32,
    ways: u32,
};

pub const Leaf = struct {
    eax: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    function: u32,
    index: u32 = 0,
    indexed: bool = false,

    pub fn entry(leaf: Leaf) kvm.CpuidEntry2 {
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

pub const Requirement = struct {
    eax: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    function: u32,
    index: u32 = 0,
};

pub const address_bits_physical = 39;
pub const address_bits_virtual = 48;
pub const brand = "Celeste Virtual CPU";
pub const flag_significant_index = 0x1;
pub const leaf1_ebx: u32 = 8 << 8 | 1 << 16;
pub const leaf80000001_edx: u32 = bit(11) | bit(20) | bit(26) | bit(27) | bit(29);
pub const leaf80000006_ecx: u32 = 1024 << 16 | 0x6 << 12 | 64;
pub const leaf80000008_eax: u32 = address_bits_virtual << 8 | address_bits_physical;
pub const leaf_max_basic = 0xd;
pub const xcr0_supported: u32 = 0x7;
pub const xsave_size = 576 + 256;

pub const leaf1_ecx: u32 = bit(0) | bit(1) | bit(9) | bit(12) | bit(13) | bit(17) | bit(19) |
    bit(20) | bit(22) | bit(23) | bit(25) | bit(26) | bit(28) | bit(29);

pub const leaf1_edx: u32 = bit(0) | bit(1) | bit(2) | bit(3) | bit(5) | bit(6) | bit(8) |
    bit(11) | bit(12) | bit(13) | bit(15) | bit(16) | bit(17) | bit(19) | bit(23) | bit(24) |
    bit(25) | bit(26);

pub const leaf7_ebx: u32 = bit(0) | bit(3) | bit(5) | bit(7) | bit(8) | bit(9) | bit(10) |
    bit(19) | bit(20) | bit(23);

comptime {
    assert(amd.leaves.len <= kvm.cpuid_entries_max);
    assert(intel.leaves.len <= kvm.cpuid_entries_max);
    assert(brand.len < 48);
}

fn addresses_missing(missing: *Missing, eax: u32) error{HostUnsupported} {
    missing.* = .{ .function = 0x80000008, .register = "eax", .bits = eax };

    assert(missing.function == 0x80000008);
    assert(missing.bits == eax);

    return error.HostUnsupported;
}

fn host_check(vendor: Vendor, host: *const kvm.Cpuid2, missing: *Missing) Error!void {
    assert(host.nent <= kvm.cpuid_entries_max);

    for (requirements_of(vendor)) |requirement| {
        const entry = host_find(host, requirement.function, requirement.index) orelse {
            missing.* = .{ .function = requirement.function, .register = "leaf" };

            return error.HostUnsupported;
        };

        try requirement_check(requirement, entry, missing);
    }

    const version_leaf = host_find(host, 1, 0) orelse return error.HostUnsupported;

    if (!version_supported(vendor, version_leaf.eax)) {
        missing.* = .{ .function = 1, .register = "eax", .bits = version_leaf.eax };

        return error.HostUnsupported;
    }

    const addresses = host_find(host, 0x80000008, 0) orelse return error.HostUnsupported;
    const physical = addresses.eax & 0xff;
    const virtual = addresses.eax >> 8 & 0xff;

    if (physical < address_bits_physical) return addresses_missing(missing, addresses.eax);
    if (virtual < address_bits_virtual) return addresses_missing(missing, addresses.eax);
}

fn host_find(host: *const kvm.Cpuid2, function: u32, index: u32) ?kvm.CpuidEntry2 {
    assert(host.nent <= kvm.cpuid_entries_max);

    for (host.entries[0..host.nent]) |entry| {
        if (entry.function != function) continue;
        if (entry.index == index) return entry;
    }

    return null;
}

fn leaves_of(vendor: Vendor) []const Leaf {
    return switch (vendor) {
        .amd => &amd.leaves,
        .intel => &intel.leaves,
    };
}

fn requirement_check(
    requirement: Requirement,
    entry: kvm.CpuidEntry2,
    missing: *Missing,
) Error!void {
    assert(entry.function == requirement.function);
    assert(entry.index == requirement.index);

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

fn requirements_of(vendor: Vendor) []const Requirement {
    return switch (vendor) {
        .amd => &amd.requirements,
        .intel => &intel.requirements,
    };
}

fn vendor_matches(leaf: kvm.CpuidEntry2, ebx: u32, ecx: u32, edx: u32) bool {
    assert(leaf.function == 0);

    if (leaf.ebx != ebx) return false;
    if (leaf.ecx != ecx) return false;
    return leaf.edx == edx;
}

fn version_supported(vendor: Vendor, eax: u32) bool {
    assert(eax != 0);

    return switch (vendor) {
        .amd => amd.version_supported(eax),
        .intel => intel.version_supported(eax),
    };
}

pub fn bit(comptime position: u5) u32 {
    return @as(u32, 1) << position;
}

pub fn brand_leaf(comptime part: u32) Leaf {
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

pub fn cache_leaf(comptime function: u32, comptime index: u32, comptime cache: Cache) Leaf {
    assert(function == 4 or function == 0x8000001d);
    assert(index < 4);
    assert(cache.kind >= 1);
    assert(cache.kind <= 3);
    assert(cache.level >= 1);
    assert(cache.level <= 3);

    return .{
        .function = function,
        .index = index,
        .indexed = true,
        .eax = cache.kind | cache.level << 5 | bit(8),
        .ebx = (cache.ways - 1) << 22 | (64 - 1),
        .ecx = cache.sets - 1,
    };
}

pub fn model(
    host: *const kvm.Cpuid2,
    out: *kvm.Cpuid2,
    missing: *Missing,
    guest: ?Vendor,
) Error!Vendors {
    assert(host.nent <= kvm.cpuid_entries_max);

    const host_vendor = try vendor_detect(host, missing);
    const vendors: Vendors = .{ .guest = guest orelse host_vendor, .host = host_vendor };

    try host_check(host_vendor, host, missing);
    model_write(vendors.guest, out);

    assert(out.nent > 0);

    return vendors;
}

pub fn model_write(vendor: Vendor, out: *kvm.Cpuid2) void {
    const leaves = leaves_of(vendor);

    assert(leaves.len > 0);
    assert(leaves.len <= kvm.cpuid_entries_max);

    out.nent = @intCast(leaves.len);
    out.padding = 0;

    for (leaves, out.entries[0..leaves.len]) |leaf, *entry| entry.* = leaf.entry();

    assert(out.entries[0].function == 0);
}

pub fn msrs_initial(vendor: Vendor) []const kvm.MsrEntry {
    return switch (vendor) {
        .amd => &amd.msrs_initial,
        .intel => &intel.msrs_initial,
    };
}

pub fn processor_set(vendor: Vendor, cpuid: *kvm.Cpuid2, apic_id: u8, cpus: u8) void {
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
            0xb => {
                entry.edx = apic_id;

                if (entry.index == 1) {
                    entry.eax = core_bits;
                    entry.ebx = cpus;
                }
            },
            else => switch (vendor) {
                .amd => amd.processor_set(entry, apic_id, cpus, core_bits),
                .intel => intel.processor_set(entry, apic_id, cpus, core_bits),
            },
        }
    }
}

pub fn vendor_detect(host: *const kvm.Cpuid2, missing: *Missing) Error!Vendor {
    assert(host.nent <= kvm.cpuid_entries_max);

    const leaf = host_find(host, 0, 0) orelse {
        missing.* = .{ .register = "leaf" };

        return error.HostUnsupported;
    };

    if (vendor_matches(leaf, amd.vendor_ebx, amd.vendor_ecx, amd.vendor_edx)) return .amd;
    if (vendor_matches(leaf, intel.vendor_ebx, intel.vendor_ecx, intel.vendor_edx)) return .intel;

    missing.* = .{ .register = "vendor" };

    return error.HostUnsupported;
}

pub fn version(comptime family: u32, comptime model_number: u32) u32 {
    assert(family > 0);
    assert(model_number <= 0xff);

    const family_base: u32 = @min(family, 0xf);
    const family_extended = family - family_base;

    assert(family_extended <= 0xff);

    return family_extended << 20 | (model_number >> 4) << 16 | family_base << 8 |
        (model_number & 0xf) << 4;
}

pub fn version_family(eax: u32) u32 {
    const family_base = eax >> 8 & 0xf;
    const family_extended = eax >> 20 & 0xff;

    assert(family_base <= 0xf);

    if (family_base < 0xf) return family_base;
    return family_base + family_extended;
}

pub fn version_model(eax: u32) u32 {
    const family_base = eax >> 8 & 0xf;
    const model_base = eax >> 4 & 0xf;
    const model_extended = eax >> 16 & 0xf;

    assert(model_base <= 0xf);

    if (family_base < 0x6) return model_base;
    return model_extended << 4 | model_base;
}

test "the model is the same table whatever the host adds on top of the baseline" {
    var first: kvm.Cpuid2 = undefined;
    var second: kvm.Cpuid2 = undefined;
    var host: kvm.Cpuid2 = undefined;
    var missing: Missing = .{};

    test_host_intel(&host);

    const vendors = try model(&host, &first, &missing, null);

    try std.testing.expectEqual(Vendor.intel, vendors.guest);
    try std.testing.expectEqual(Vendor.intel, vendors.host);

    host.entries[1].eax = 0x000b0671 + 0x10;
    host.entries[1].ecx |= bit(30) | bit(31);
    host.entries[2].ebx |= bit(18);
    host.entries[2].ecx |= bit(5);
    host.entries[3].eax = 0xffff;

    try std.testing.expectEqual(vendors, try model(&host, &second, &missing, null));
    try std.testing.expectEqual(first.nent, second.nent);

    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(first.entries[0..first.nent]),
        std.mem.sliceAsBytes(second.entries[0..second.nent]),
    );
}

test "both models hide time, entropy, hypervisor, and virtualization and report one thread" {
    for (std.enums.values(Vendor)) |vendor| {
        var out: kvm.Cpuid2 = undefined;

        model_write(vendor, &out);

        const hidden = bit(3) | bit(21) | bit(24) | bit(30) | bit(31);
        const leaf1 = host_find(&out, 1, 0).?;
        const leaf7 = host_find(&out, 7, 0).?;
        const extended = host_find(&out, 0x80000001, 0).?;

        try std.testing.expectEqual(@as(u32, 0), leaf1.edx & bit(4));
        try std.testing.expectEqual(@as(u32, 0), leaf1.ecx & hidden);
        try std.testing.expectEqual(@as(u32, 0), leaf7.ebx & bit(18));
        try std.testing.expectEqual(@as(u32, 0), leaf7.ecx & bit(5));
        try std.testing.expectEqual(@as(u32, 0), leaf7.edx);
        try std.testing.expectEqual(@as(u32, 0), extended.ecx & (bit(2) | bit(9) | bit(10)));
        try std.testing.expectEqual(@as(?kvm.CpuidEntry2, null), host_find(&out, 0x40000000, 0));
        try std.testing.expectEqual(@as(u32, 1), (leaf1.ebx >> 16) & 0xff);
        try std.testing.expectEqual(@as(u32, 0), host_find(&out, 0x80000007, 0).?.edx);
    }
}

test "the two models share one feature floor and differ only in vendor leaves" {
    var amd_model: kvm.Cpuid2 = undefined;
    var intel_model: kvm.Cpuid2 = undefined;

    model_write(.amd, &amd_model);
    model_write(.intel, &intel_model);

    try std.testing.expectEqual(host_find(&intel_model, 0xd, 0).?, host_find(&amd_model, 0xd, 0).?);

    const amd_leaf1 = host_find(&amd_model, 1, 0).?;
    const intel_leaf1 = host_find(&intel_model, 1, 0).?;
    const amd_leaf7 = host_find(&amd_model, 7, 0).?;
    const intel_leaf7 = host_find(&intel_model, 7, 0).?;
    const amd_extended = host_find(&amd_model, 0x80000001, 0).?;
    const intel_extended = host_find(&intel_model, 0x80000001, 0).?;
    const amd_only = bit(6) | bit(7) | bit(22);
    const intel_only_leaf1 = bit(17);
    const intel_only_leaf7 = bit(9) | bit(10);

    try std.testing.expectEqual(intel_leaf1.ebx, amd_leaf1.ebx);
    try std.testing.expectEqual(intel_leaf1.ecx & ~intel_only_leaf1, amd_leaf1.ecx);
    try std.testing.expectEqual(intel_leaf1.edx, amd_leaf1.edx);
    try std.testing.expectEqual(intel_leaf7.ebx & ~intel_only_leaf7, amd_leaf7.ebx);
    try std.testing.expectEqual(intel_leaf7.ecx, amd_leaf7.ecx);
    try std.testing.expectEqual(intel_leaf7.edx, amd_leaf7.edx);
    try std.testing.expectEqual(@as(u32, 0x000606f0), intel_leaf1.eax);
    try std.testing.expectEqual(@as(u32, 0x00870f10), amd_leaf1.eax);
    try std.testing.expectEqual(intel_extended.ecx, amd_extended.ecx & ~amd_only);
    try std.testing.expectEqual(intel_extended.edx, amd_extended.edx);
    try std.testing.expectEqual(@as(u32, 0), host_find(&amd_model, 4, 0).?.eax);
    try std.testing.expectEqual(
        @as(?kvm.CpuidEntry2, null),
        host_find(&intel_model, 0x8000001d, 0),
    );

    const amd_cache = host_find(&amd_model, 0x8000001d, 0).?;
    const intel_cache = host_find(&intel_model, 4, 0).?;

    try std.testing.expectEqual(intel_cache.eax, amd_cache.eax);
    try std.testing.expectEqual(intel_cache.ebx, amd_cache.ebx);
    try std.testing.expectEqual(intel_cache.ecx, amd_cache.ecx);
}

test "a processor gets its apic id, the apic bit, and a core count only when there are several" {
    var host: kvm.Cpuid2 = undefined;
    var single: kvm.Cpuid2 = undefined;
    var plain: kvm.Cpuid2 = undefined;
    var shared: kvm.Cpuid2 = undefined;
    var missing: Missing = .{};

    test_host_intel(&host);

    _ = try model(&host, &plain, &missing, null);
    _ = try model(&host, &single, &missing, null);
    _ = try model(&host, &shared, &missing, null);

    processor_set(.intel, &single, 0, 1);
    processor_set(.intel, &shared, 2, 4);

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

test "an AMD processor carries its apic id in the extended topology leaves" {
    var host: kvm.Cpuid2 = undefined;
    var shared: kvm.Cpuid2 = undefined;
    var missing: Missing = .{};

    test_host_amd(&host);

    const vendors = try model(&host, &shared, &missing, null);

    try std.testing.expectEqual(Vendor.amd, vendors.guest);
    try std.testing.expectEqual(Vendor.amd, vendors.host);

    processor_set(.amd, &shared, 3, 4);

    const leaf1 = host_find(&shared, 1, 0).?;
    const topology = host_find(&shared, 0xb, 1).?;
    const cores = host_find(&shared, 0x80000008, 0).?;
    const node = host_find(&shared, 0x8000001e, 0).?;

    try std.testing.expectEqual(3, leaf1.ebx >> 24);
    try std.testing.expectEqual(4, leaf1.ebx >> 16 & 0xff);
    try std.testing.expectEqual(3, topology.edx);
    try std.testing.expectEqual(3, cores.ecx & 0xff);
    try std.testing.expectEqual(2, cores.ecx >> 12 & 0xf);
    try std.testing.expectEqual(3, node.eax);
    try std.testing.expectEqual(3, node.ebx & 0xff);
    try std.testing.expectEqual(0, node.ebx >> 8 & 0xff);
    try std.testing.expectEqual(0, node.ecx);
}

test "a host without AVX2 or from an unknown vendor is refused" {
    var host: kvm.Cpuid2 = undefined;
    var out: kvm.Cpuid2 = undefined;
    var missing: Missing = .{};

    test_host_intel(&host);
    host.entries[2].ebx &= ~bit(5);

    try std.testing.expectError(error.HostUnsupported, model(&host, &out, &missing, null));
    try std.testing.expectEqual(@as(u32, 7), missing.function);
    try std.testing.expectEqualStrings("ebx", missing.register);
    try std.testing.expectEqual(bit(5), missing.bits);

    test_host_intel(&host);
    host.entries[0].ebx = 0x746e6543;

    try std.testing.expectError(error.HostUnsupported, model(&host, &out, &missing, null));
    try std.testing.expectEqualStrings("vendor", missing.register);
}

test "a forced guest vendor checks the host against its own floor and writes the other table" {
    var host: kvm.Cpuid2 = undefined;
    var forced: kvm.Cpuid2 = undefined;
    var written: kvm.Cpuid2 = undefined;
    var missing: Missing = .{};

    test_host_intel(&host);

    const vendors = try model(&host, &forced, &missing, .amd);

    try std.testing.expectEqual(Vendor.amd, vendors.guest);
    try std.testing.expectEqual(Vendor.intel, vendors.host);
    try std.testing.expectEqual(amd.vendor_ebx, forced.entries[0].ebx);

    model_write(.amd, &written);

    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(written.entries[0..written.nent]),
        std.mem.sliceAsBytes(forced.entries[0..forced.nent]),
    );

    host.entries[2].ebx &= ~bit(5);

    try std.testing.expectError(error.HostUnsupported, model(&host, &forced, &missing, .amd));
    try std.testing.expectEqual(@as(u32, 7), missing.function);
}

test "Zen 4 and Zen 2 hosts get the AMD model and a Zen 1 host is refused by its version" {
    var host: kvm.Cpuid2 = undefined;
    var out: kvm.Cpuid2 = undefined;
    var missing: Missing = .{};

    test_host_amd(&host);

    const vendors = try model(&host, &out, &missing, null);

    try std.testing.expectEqual(Vendor.amd, vendors.guest);
    try std.testing.expectEqual(amd.leaves.len, out.nent);
    try std.testing.expectEqual(amd.vendor_ebx, out.entries[0].ebx);

    host.entries[1].eax = version(0x17, 0x71);
    host.entries[2].ebx &= ~(bit(9) | bit(10));

    _ = try model(&host, &out, &missing, null);

    host.entries[1].eax = version(0x17, 0x01);

    try std.testing.expectError(error.HostUnsupported, model(&host, &out, &missing, null));
    try std.testing.expectEqual(@as(u32, 1), missing.function);
    try std.testing.expectEqualStrings("eax", missing.register);
    try std.testing.expectEqual(version(0x17, 0x01), missing.bits);

    host.entries[1].eax = version(0x19, 0x61);
    host.entries[2].ebx &= ~bit(5);

    try std.testing.expectError(error.HostUnsupported, model(&host, &out, &missing, null));
    try std.testing.expectEqual(@as(u32, 7), missing.function);
}

test "a version word packs the family and model the way both vendors decode them" {
    try std.testing.expectEqual(@as(u32, 0x000606f0), version(6, 0x6f));
    try std.testing.expectEqual(@as(u32, 0x00a20f10), version(0x19, 0x21));
    try std.testing.expectEqual(@as(u32, 0x00870f10), version(0x17, 0x71));

    inline for (.{ 6, 0x17, 0x19, 0x1a }) |family| {
        inline for (.{ 0x01, 0x30, 0x6f, 0x71, 0xa5 }) |model_number| {
            try std.testing.expectEqual(family, version_family(version(family, model_number)));
            try std.testing.expectEqual(model_number, version_model(version(family, model_number)));
        }
    }

    try std.testing.expectEqual(@as(u32, 0x19), version_family(0x00a60f12));
    try std.testing.expectEqual(@as(u32, 0x61), version_model(0x00a60f12));
    try std.testing.expect(amd.version_supported(0x00a60f12));
    try std.testing.expect(amd.version_supported(0x00870f10));
    try std.testing.expect(!amd.version_supported(0x00800f12));
}

fn test_host_amd(host: *kvm.Cpuid2) void {
    const entries = [_]Leaf{
        .{
            .function = 0,
            .eax = 0x10,
            .ebx = amd.vendor_ebx,
            .ecx = amd.vendor_ecx,
            .edx = amd.vendor_edx,
        },
        .{
            .function = 1,
            .eax = 0x00a60f12,
            .ebx = 0x0d100800,
            .ecx = 0xf7f83203,
            .edx = 0x078bfbff,
        },
        .{
            .function = 7,
            .indexed = true,
            .ebx = 0xf1bf07ab,
            .ecx = 0x00405fce,
            .edx = 0xbc000010,
        },
        .{ .function = 0xd, .indexed = true, .eax = 0x2e7, .ebx = 0x988, .ecx = 0x988 },
        .{ .function = 0x80000001, .ecx = 0x00c003f7, .edx = 0x2fd3fbff },
        .{ .function = 0x80000008, .eax = 0x303030, .ebx = 0x531ad205, .ecx = 0x400f },
    };

    host.nent = entries.len;
    host.padding = 0;

    for (entries, host.entries[0..entries.len]) |leaf, *entry| entry.* = leaf.entry();
}

fn test_host_intel(host: *kvm.Cpuid2) void {
    const entries = [_]Leaf{
        .{
            .function = 0,
            .eax = 0x20,
            .ebx = intel.vendor_ebx,
            .ecx = intel.vendor_ecx,
            .edx = intel.vendor_edx,
        },
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
