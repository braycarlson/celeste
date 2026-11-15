const std = @import("std");

const cpuid = @import("cpuid.zig");
const kvm = @import("kvm.zig");

const assert = std.debug.assert;
const bit = cpuid.bit;
const Leaf = cpuid.Leaf;
const Requirement = cpuid.Requirement;

pub const vendor_ebx = 0x68747541;
pub const vendor_ecx = 0x444d4163;
pub const vendor_edx = 0x69746e65;
const cache_l1_descriptor: u32 = 32 << 24 | 8 << 16 | 1 << 8 | 64;
const leaf1_ecx: u32 = cpuid.leaf1_ecx & ~bit(17);
const leaf7_ebx: u32 = cpuid.leaf7_ebx & ~(bit(9) | bit(10));
const leaf80000001_ecx: u32 = bit(0) | bit(5) | bit(6) | bit(7) | bit(8) | bit(22);
const leaf80000005_tlb: u32 = 0xff40ff40;
const leaf80000006_edx: u32 = 64 << 18 | 0x8 << 12 | 1 << 8 | 64;
const leaf_max_extended = 0x8000001e;
const version_family = 0x17;
const version_family_zen_2_min_model = 0x30;
const version_model = 0x71;

pub const msrs_initial = [_]kvm.MsrEntry{};

pub const requirements = [_]Requirement{
    .{ .function = 1, .ecx = leaf1_ecx, .edx = cpuid.leaf1_edx },
    .{ .function = 7, .ebx = leaf7_ebx },
    .{ .function = 0xd, .eax = cpuid.xcr0_supported },
    .{ .function = 0x80000001, .ecx = leaf80000001_ecx, .edx = cpuid.leaf80000001_edx },
};

pub const leaves = [_]Leaf{
    .{
        .function = 0,
        .eax = cpuid.leaf_max_basic,
        .ebx = vendor_ebx,
        .ecx = vendor_ecx,
        .edx = vendor_edx,
    },
    .{
        .function = 1,
        .eax = cpuid.version(version_family, version_model),
        .ebx = cpuid.leaf1_ebx,
        .ecx = leaf1_ecx,
        .edx = cpuid.leaf1_edx,
    },
    .{ .function = 2 },
    .{ .function = 3 },
    .{ .function = 4 },
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
        .eax = cpuid.xcr0_supported,
        .ebx = cpuid.xsave_size,
        .ecx = cpuid.xsave_size,
    },
    .{ .function = 0xd, .index = 1, .indexed = true, .eax = bit(0) },
    .{ .function = 0xd, .index = 2, .indexed = true, .eax = 256, .ebx = 576 },
    .{ .function = 0x80000000, .eax = leaf_max_extended },
    .{ .function = 0x80000001, .ecx = leaf80000001_ecx, .edx = cpuid.leaf80000001_edx },
    cpuid.brand_leaf(0),
    cpuid.brand_leaf(1),
    cpuid.brand_leaf(2),
    .{
        .function = 0x80000005,
        .eax = leaf80000005_tlb,
        .ebx = leaf80000005_tlb,
        .ecx = cache_l1_descriptor,
        .edx = cache_l1_descriptor,
    },
    .{ .function = 0x80000006, .ecx = cpuid.leaf80000006_ecx, .edx = leaf80000006_edx },
    .{ .function = 0x80000007 },
    .{ .function = 0x80000008, .eax = cpuid.leaf80000008_eax },
    .{ .function = 0x80000009 },
    .{ .function = 0x8000000a },
    .{ .function = 0x8000000b },
    .{ .function = 0x8000000c },
    .{ .function = 0x8000000d },
    .{ .function = 0x8000000e },
    .{ .function = 0x8000000f },
    .{ .function = 0x80000010 },
    .{ .function = 0x80000011 },
    .{ .function = 0x80000012 },
    .{ .function = 0x80000013 },
    .{ .function = 0x80000014 },
    .{ .function = 0x80000015 },
    .{ .function = 0x80000016 },
    .{ .function = 0x80000017 },
    .{ .function = 0x80000018 },
    .{ .function = 0x80000019 },
    .{ .function = 0x8000001a },
    .{ .function = 0x8000001b },
    .{ .function = 0x8000001c },
    cpuid.cache_leaf(0x8000001d, 0, .{ .kind = 1, .level = 1, .ways = 8, .sets = 64 }),
    cpuid.cache_leaf(0x8000001d, 1, .{ .kind = 2, .level = 1, .ways = 8, .sets = 64 }),
    cpuid.cache_leaf(0x8000001d, 2, .{ .kind = 3, .level = 2, .ways = 8, .sets = 2048 }),
    cpuid.cache_leaf(0x8000001d, 3, .{ .kind = 3, .level = 3, .ways = 16, .sets = 32768 }),
    .{ .function = 0x8000001d, .index = 4, .indexed = true },
    .{ .function = 0x8000001e },
};

comptime {
    assert(leaves[0].function == 0);
    assert(leaves[leaves.len - 1].function == leaf_max_extended);
    assert(leaf1_ecx & bit(17) == 0);
    assert(leaf7_ebx & (bit(9) | bit(10)) == 0);
    assert(leaf80000001_ecx & bit(2) == 0);
    assert(leaf80000001_ecx & bit(9) == 0);
    assert(version_supported(cpuid.version(version_family, version_model)));
}

pub fn processor_set(entry: *kvm.CpuidEntry2, apic_id: u8, cpus: u8, core_bits: u32) void {
    assert(cpus > 1);
    assert(apic_id < cpus);
    assert(core_bits > 0);

    switch (entry.function) {
        0x80000008 => entry.ecx = @as(u32, cpus - 1) | core_bits << 12,
        0x8000001e => {
            entry.eax = apic_id;
            entry.ebx = apic_id;
        },
        else => {},
    }
}
pub fn version_supported(eax: u32) bool {
    const family = cpuid.version_family(eax);
    const model_number = cpuid.version_model(eax);

    assert(eax != 0);

    if (family > version_family) return true;
    if (family < version_family) return false;
    return model_number >= version_family_zen_2_min_model;
}
