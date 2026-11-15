const std = @import("std");

const cpuid = @import("cpuid.zig");
const kvm = @import("kvm.zig");

const assert = std.debug.assert;
const bit = cpuid.bit;
const Leaf = cpuid.Leaf;
const Requirement = cpuid.Requirement;

pub const vendor_ebx = 0x756e6547;
pub const vendor_ecx = 0x6c65746e;
pub const vendor_edx = 0x49656e69;
const leaf80000001_ecx: u32 = bit(0) | bit(5) | bit(8);
const leaf_max_extended = 0x80000008;
const version_family = 6;
const version_model = 0x6f;

pub const msrs_initial = [_]kvm.MsrEntry{
    .{
        .index = kvm.msr_ia32_misc_enable,
        .reserved = 0,
        .data = kvm.msr_ia32_misc_enable_fast_string,
    },
};

pub const requirements = [_]Requirement{
    .{ .function = 1, .ecx = cpuid.leaf1_ecx, .edx = cpuid.leaf1_edx },
    .{ .function = 7, .ebx = cpuid.leaf7_ebx },
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
        .ecx = cpuid.leaf1_ecx,
        .edx = cpuid.leaf1_edx,
    },
    .{ .function = 2, .eax = 0x0000ff01 },
    .{ .function = 3 },
    cpuid.cache_leaf(4, 0, .{ .kind = 1, .level = 1, .ways = 8, .sets = 64 }),
    cpuid.cache_leaf(4, 1, .{ .kind = 2, .level = 1, .ways = 8, .sets = 64 }),
    cpuid.cache_leaf(4, 2, .{ .kind = 3, .level = 2, .ways = 8, .sets = 2048 }),
    cpuid.cache_leaf(4, 3, .{ .kind = 3, .level = 3, .ways = 16, .sets = 32768 }),
    .{ .function = 4, .index = 4, .indexed = true },
    .{ .function = 5 },
    .{ .function = 6 },
    .{ .function = 7, .indexed = true, .ebx = cpuid.leaf7_ebx },
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
    .{ .function = 0x80000005 },
    .{ .function = 0x80000006, .ecx = cpuid.leaf80000006_ecx },
    .{ .function = 0x80000007 },
    .{ .function = 0x80000008, .eax = cpuid.leaf80000008_eax },
};

comptime {
    assert(leaves[0].function == 0);
    assert(leaves[leaves.len - 1].function == leaf_max_extended);
}

pub fn processor_set(entry: *kvm.CpuidEntry2, apic_id: u8, cpus: u8, core_bits: u32) void {
    assert(cpus > 1);
    assert(apic_id < cpus);
    assert(core_bits > 0);

    if (entry.function != 4) return;
    if (entry.eax == 0) return;

    entry.eax = (entry.eax & 0x03ff_ffff) | @as(u32, cpus - 1) << 26;

    assert(entry.eax >> 26 == cpus - 1);
}
pub fn version_supported(eax: u32) bool {
    assert(eax != 0);
    assert(cpuid.version_family(eax) > 0);

    return true;
}
