const std = @import("std");

const kvm = @import("kvm.zig");

const assert = std.debug.assert;
const elf = std.elf;

pub const Error = error{
    CmdlineTooLong,
    InitrdAbove4G,
    InitrdExceedsMemory,
    KernelExceedsMemory,
    KernelTooSmall,
    NotElf,
    NotX86_64,
    SymbolMissing,
    TruncatedKernel,
};

pub const Image = struct {
    cmdline: []const u8,
    cpus: u8 = 1,
    initrd: []const u8,
    kernel: []const u8,
    rng_seed: [rng_seed_size]u8,
};

pub const boot_params_addr = 0x7000;
pub const boot_stack_pointer = 0x8ff0;
pub const cmdline_addr = 0x20000;
pub const cmdline_size_max = 2048;
pub const ebda_start = 0x9fc00;
pub const gdt_addr = 0x500;
pub const gdt_entries = 5;
pub const himem_start = 0x100000;
pub const memory_size_max = 3 << 30;
pub const mptable_addr = ebda_start;
pub const mptable_cpus_max = 32;
pub const pml4_addr = 0x9000;
pub const pdpt_addr = 0xa000;
pub const pd_addr = 0xb000;
pub const rng_seed_size = 32;
pub const setup_data_addr = 0x20800;
pub const setup_data_header_size = 16;
pub const setup_data_rng_seed = 9;
const boot_flag_magic = 0xaa55;
const e820_entry_size = 20;
const e820_ram = 1;
const header_magic = 0x53726448;
const loadflags_can_use_heap = 0x80;
const loadflags_keep_segments = 0x40;
const loadflags_loaded_high = 0x01;
const loadflags = loadflags_loaded_high | loadflags_keep_segments | loadflags_can_use_heap;
const mp_bus_size = 8;
const mp_cpu_features = 0x201;
const mp_cpu_signature = 0x600;
const mp_cpu_size = 20;
const mp_entry_bus = 1;
const mp_entry_cpu = 0;
const mp_entry_lint = 4;
const mp_header_size = 44;
const mp_lapic_base = 0xfee0_0000;
const mp_lapic_version = 0x14;
const mp_lint_extint = 3;
const mp_lint_nmi = 1;
const mp_lint_size = 8;
const mp_pointer_size = 16;
const mp_spec = 4;
const type_of_loader_undefined = 0xff;

const boot_params_field = struct {
    const boot_flag = 510;
    const cmd_line_ptr = 552;
    const cmdline_size = 568;
    const e820_entries = 488;
    const e820_table = 720;
    const header = 514;
    const loadflags = 529;
    const ramdisk_image = 536;
    const ramdisk_size = 540;
    const setup_data = 592;
    const type_of_loader = 528;
};

const selector = struct {
    const code = 0x10;
    const data = 0x18;
    const tss = 0x20;
};

comptime {
    assert(gdt_addr + gdt_entries * 8 <= boot_params_addr);
    assert(boot_params_addr + kvm.page_size <= pml4_addr);
    assert(pml4_addr + kvm.page_size == pdpt_addr);
    assert(pdpt_addr + kvm.page_size == pd_addr);
    assert(pd_addr + (memory_size_max >> 30) * kvm.page_size <= cmdline_addr);
    assert(cmdline_addr + cmdline_size_max <= setup_data_addr);
    assert(setup_data_addr + setup_data_header_size + rng_seed_size <= ebda_start);
    assert(boot_stack_pointer > boot_params_addr + kvm.page_size);
    assert(boot_stack_pointer < pml4_addr);
}

fn boot_params_write(memory: []u8, image: *const Image, initrd_addr: u64) void {
    assert(image.cmdline.len < cmdline_size_max);
    assert(initrd_addr + image.initrd.len <= memory.len);

    const params = memory[boot_params_addr..][0..kvm.page_size];

    @memset(params, 0);

    params[boot_params_field.type_of_loader] = type_of_loader_undefined;
    params[boot_params_field.loadflags] = loadflags;

    int_write(u16, params, boot_params_field.boot_flag, boot_flag_magic);
    int_write(u32, params, boot_params_field.header, header_magic);
    int_write(u32, params, boot_params_field.cmd_line_ptr, cmdline_addr);
    int_write(u32, params, boot_params_field.cmdline_size, @intCast(image.cmdline.len));
    int_write(u32, params, boot_params_field.ramdisk_image, @intCast(initrd_addr));
    int_write(u32, params, boot_params_field.ramdisk_size, @intCast(image.initrd.len));
    int_write(u64, params, boot_params_field.setup_data, setup_data_addr);

    e820_write(params, 0, 0, ebda_start);
    e820_write(params, 1, himem_start, memory.len - himem_start);
    params[boot_params_field.e820_entries] = 2;
}

fn e820_write(params: []u8, index: usize, addr: u64, size: u64) void {
    assert(index < 128);
    assert(size > 0);

    const offset = boot_params_field.e820_table + index * e820_entry_size;

    int_write(u64, params, offset, addr);
    int_write(u64, params, offset + 8, size);
    int_write(u32, params, offset + 16, e820_ram);
}

fn elf_load(memory: []u8, kernel: []const u8) Error!u64 {
    if (kernel.len < @sizeOf(elf.Elf64.Ehdr)) return error.KernelTooSmall;
    if (!std.mem.eql(u8, kernel[0..4], "\x7fELF")) return error.NotElf;

    const header: *align(1) const elf.Elf64.Ehdr = @ptrCast(kernel.ptr);
    if (header.machine != .X86_64) return error.NotX86_64;
    if (header.phnum > phdrs_max) return error.TruncatedKernel;

    var index: u16 = 0;

    while (index < header.phnum) : (index += 1) {
        const offset = header.phoff + @as(u64, index) * @sizeOf(elf.Elf64.Phdr);
        if (offset + @sizeOf(elf.Elf64.Phdr) > kernel.len) return error.TruncatedKernel;

        const phdr: *align(1) const elf.Elf64.Phdr = @ptrCast(kernel.ptr + offset);
        if (phdr.type != .LOAD) continue;
        if (phdr.filesz > phdr.memsz) return error.TruncatedKernel;
        if (phdr.offset + phdr.filesz > kernel.len) return error.TruncatedKernel;
        if (phdr.paddr + phdr.memsz > memory.len) return error.KernelExceedsMemory;

        const target = memory[phdr.paddr..][0..phdr.memsz];

        @memcpy(target[0..phdr.filesz], kernel[phdr.offset..][0..phdr.filesz]);
        @memset(target[phdr.filesz..], 0);
    }

    if (header.entry >= memory.len) return error.KernelExceedsMemory;
    return header.entry;
}

fn gdt_write(memory: []u8) void {
    int_write(u64, memory, gdt_addr + 0 * 8, 0);
    int_write(u64, memory, gdt_addr + 1 * 8, 0);
    int_write(u64, memory, gdt_addr + 2 * 8, 0x00af9b000000ffff);
    int_write(u64, memory, gdt_addr + 3 * 8, 0x00cf93000000ffff);
    int_write(u64, memory, gdt_addr + 4 * 8, 0x00808b000000ffff);
}

fn initrd_load(memory: []u8, initrd: []const u8) Error!u64 {
    if (initrd.len == 0) return 0;
    if (initrd.len > memory.len) return error.InitrdExceedsMemory;

    const top = std.mem.alignBackward(usize, memory.len - initrd.len, kvm.page_size);
    if (top < himem_start) return error.InitrdExceedsMemory;
    if (top + initrd.len > std.math.maxInt(u32)) return error.InitrdAbove4G;

    @memcpy(memory[top..][0..initrd.len], initrd);

    assert(top % kvm.page_size == 0);

    return top;
}

fn int_write(comptime T: type, buffer: []u8, offset: usize, value: T) void {
    assert(offset + @sizeOf(T) <= buffer.len);
    std.mem.writeInt(T, buffer[offset..][0..@sizeOf(T)], value, .little);
}

fn mptable_checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;

    for (bytes) |byte| sum +%= byte;

    assert(bytes.len > 0);

    return 0 -% sum;
}

fn mptable_entry_lint(table: []u8, offset: usize, kind: u8, lint: u8) void {
    assert(offset + mp_lint_size <= table.len);
    assert(lint <= 1);

    table[offset] = mp_entry_lint;

    table[offset + 1] = kind;
    table[offset + 6] = 0xff;
    table[offset + 7] = lint;
}

fn mptable_write(memory: []u8, cpus: u8) void {
    const table_addr = mptable_addr + mp_pointer_size;
    const length = mp_header_size + @as(usize, cpus) * mp_cpu_size + mp_bus_size + 2 * mp_lint_size;
    const pointer = memory[mptable_addr..][0..mp_pointer_size];
    const table = memory[table_addr..][0..length];
    var offset: usize = mp_header_size;

    assert(cpus >= 2);
    assert(cpus <= mptable_cpus_max);
    assert(table_addr + length <= 0xa0000);

    @memset(pointer, 0);
    @memset(table, 0);
    @memcpy(pointer[0..4], "_MP_");
    int_write(u32, pointer, 4, table_addr);
    pointer[8] = 1;
    pointer[9] = mp_spec;
    pointer[10] = mptable_checksum(pointer);

    @memcpy(table[0..4], "PCMP");
    int_write(u16, table, 4, @intCast(length));
    table[6] = mp_spec;

    @memcpy(table[8..16], "DSTVMM  ");
    @memcpy(table[16..28], "CELESTE     ");
    int_write(u16, table, 34, cpus + 3);
    int_write(u32, table, 36, mp_lapic_base);

    for (0..cpus) |cpu| {
        table[offset] = mp_entry_cpu;

        table[offset + 1] = @intCast(cpu);
        table[offset + 2] = mp_lapic_version;
        table[offset + 3] = if (cpu == 0) 0b11 else 0b01;
        int_write(u32, table, offset + 4, mp_cpu_signature);
        int_write(u32, table, offset + 8, mp_cpu_features);
        offset += mp_cpu_size;
    }

    table[offset] = mp_entry_bus;

    @memcpy(table[offset + 2 ..][0..6], "ISA   ");
    offset += mp_bus_size;

    mptable_entry_lint(table, offset, mp_lint_extint, 0);
    mptable_entry_lint(table, offset + mp_lint_size, mp_lint_nmi, 1);
    table[7] = mptable_checksum(table);

    assert(offset + 2 * mp_lint_size == length);
}

fn page_tables_write(memory: []u8) void {
    const gib = 1 << 30;
    const two_mib = 1 << 21;
    const directories = std.math.divCeil(usize, memory.len, gib) catch unreachable;

    assert(directories >= 1);
    assert(directories <= memory_size_max >> 30);

    int_write(u64, memory, pml4_addr, pdpt_addr | 0x3);

    for (0..directories) |i| {
        const pd = pd_addr + i * kvm.page_size;

        int_write(u64, memory, pdpt_addr + i * 8, pd | 0x3);

        for (0..512) |j| {
            const frame = (i * 512 + j) * two_mib;

            int_write(u64, memory, pd + j * 8, frame | 0x83);
        }
    }
}

fn section_header(kernel: []const u8, index: u32) Error!*align(1) const elf.Elf64.Shdr {
    const header: *align(1) const elf.Elf64.Ehdr = @ptrCast(kernel.ptr);

    assert(kernel.len >= @sizeOf(elf.Elf64.Ehdr));
    assert(header.shentsize == @sizeOf(elf.Elf64.Shdr));

    if (index >= header.shnum) return error.TruncatedKernel;
    if (header.shoff > kernel.len) return error.TruncatedKernel;

    const offset = header.shoff + @as(u64, index) * @sizeOf(elf.Elf64.Shdr);
    if (offset + @sizeOf(elf.Elf64.Shdr) > kernel.len) return error.TruncatedKernel;
    return @ptrCast(kernel.ptr + offset);
}

fn segment(sel: u16, typ: u8, s: u8, db: u8, l: u8) kvm.Segment {
    assert(sel % 8 == 0);
    assert(db == 0 or l == 0);

    return .{
        .base = 0,
        .limit = 0xffffffff,
        .selector = sel,
        .type = typ,
        .present = 1,
        .dpl = 0,
        .db = db,
        .s = s,
        .l = l,
        .g = 1,
        .avl = 0,
        .unusable = 0,
        .padding = 0,
    };
}

fn setup_data_write(memory: []u8, image: *const Image) void {
    int_write(u64, memory, setup_data_addr, 0);
    int_write(u32, memory, setup_data_addr + 8, setup_data_rng_seed);
    int_write(u32, memory, setup_data_addr + 12, rng_seed_size);
    @memcpy(memory[setup_data_addr + setup_data_header_size ..][0..rng_seed_size], &image.rng_seed);
}

fn symbol_scan(
    kernel: []const u8,
    symbols: *align(1) const elf.Elf64.Shdr,
    strings: *align(1) const elf.Elf64.Shdr,
    name: []const u8,
) Error!u64 {
    assert(symbols.type == .SYMTAB);
    assert(name.len > 0);

    if (symbols.entsize != @sizeOf(elf.Elf64.Sym)) return error.TruncatedKernel;
    if (symbols.offset > kernel.len) return error.TruncatedKernel;
    if (symbols.size > kernel.len - symbols.offset) return error.TruncatedKernel;
    if (strings.offset > kernel.len) return error.TruncatedKernel;
    if (strings.size > kernel.len - strings.offset) return error.TruncatedKernel;

    const names = kernel[strings.offset..][0..strings.size];
    const count = symbols.size / @sizeOf(elf.Elf64.Sym);

    for (0..count) |index| {
        const offset = symbols.offset + index * @sizeOf(elf.Elf64.Sym);
        const symbol: *align(1) const elf.Elf64.Sym = @ptrCast(kernel.ptr + offset);
        if (symbol.name >= names.len) return error.TruncatedKernel;

        const candidate = std.mem.sliceTo(names[symbol.name..], 0);
        if (std.mem.eql(u8, candidate, name)) return symbol.value;
    }

    return error.SymbolMissing;
}

pub fn load(memory: []u8, image: *const Image) Error!u64 {
    assert(memory.len % kvm.page_size == 0);
    assert(memory.len > himem_start);
    assert(memory.len <= memory_size_max);

    if (image.cmdline.len >= cmdline_size_max) return error.CmdlineTooLong;

    const entry = try elf_load(memory, image.kernel);
    const initrd_addr = try initrd_load(memory, image.initrd);

    @memcpy(memory[cmdline_addr..][0..image.cmdline.len], image.cmdline);
    memory[cmdline_addr + image.cmdline.len] = 0;

    boot_params_write(memory, image, initrd_addr);
    setup_data_write(memory, image);
    gdt_write(memory);
    page_tables_write(memory);

    if (image.cpus > 1) mptable_write(memory, image.cpus);

    assert(entry >= himem_start);
    assert(entry < memory.len);

    return entry;
}

pub fn symbol_find(kernel: []const u8, name: []const u8) Error!u64 {
    assert(name.len > 0);

    if (kernel.len < @sizeOf(elf.Elf64.Ehdr)) return error.KernelTooSmall;
    if (!std.mem.eql(u8, kernel[0..4], "\x7fELF")) return error.NotElf;

    const header: *align(1) const elf.Elf64.Ehdr = @ptrCast(kernel.ptr);
    if (header.shentsize != @sizeOf(elf.Elf64.Shdr)) return error.TruncatedKernel;
    if (header.shnum > sections_max) return error.TruncatedKernel;

    var index: u32 = 0;

    while (index < header.shnum) : (index += 1) {
        const section = try section_header(kernel, index);
        if (section.type != .SYMTAB) continue;

        const strings = try section_header(kernel, section.link);
        if (strings.type != .STRTAB) return error.TruncatedKernel;
        return symbol_scan(kernel, section, strings, name);
    }

    assert(index == header.shnum);

    return error.SymbolMissing;
}

pub fn translate(memory: []const u8, cr3: u64, vaddr: u64) ?usize {
    const present = 0x1;
    const page_size_bit = 0x80;
    const frame_mask: u64 = 0x000f_ffff_ffff_f000;
    var table = cr3 & frame_mask;

    for ([_]u6{ 39, 30, 21, 12 }, 0..) |shift, level| {
        const index = (vaddr >> shift) & 0x1ff;
        const slot = table + index * 8;
        if (slot + 8 > memory.len) return null;

        const entry = std.mem.readInt(u64, memory[slot..][0..8], .little);
        if (entry & present == 0) return null;

        const large = level >= 1 and level <= 2 and entry & page_size_bit != 0;
        const leaf = large or level == 3;

        if (leaf) {
            const offset_bits: u6 = if (large) shift else 12;
            const offset = vaddr & ((@as(u64, 1) << offset_bits) - 1);
            const frame = entry & frame_mask & ~((@as(u64, 1) << offset_bits) - 1);
            const paddr = frame + offset;

            return if (paddr + 8 <= memory.len) @intCast(paddr) else null;
        }

        table = entry & frame_mask;
    }

    unreachable;
}

pub fn vcpu_setup(vcpu: kvm.Vcpu, entry: u64) kvm.Error!void {
    assert(entry >= himem_start);

    var sregs: kvm.Sregs = undefined;

    try vcpu.sregs_get(&sregs);

    sregs.cs = segment(selector.code, 0xb, 1, 0, 1);
    sregs.ds = segment(selector.data, 0x3, 1, 1, 0);
    sregs.es = sregs.ds;
    sregs.fs = sregs.ds;
    sregs.gs = sregs.ds;
    sregs.ss = sregs.ds;
    sregs.tr = segment(selector.tss, 0xb, 0, 0, 0);
    sregs.tr.limit = 0xffff;
    sregs.tr.g = 0;
    sregs.ldt.unusable = 1;
    sregs.gdt = .{ .base = gdt_addr, .limit = gdt_entries * 8 - 1, .padding = .{ 0, 0, 0 } };
    sregs.idt = .{ .base = 0, .limit = 0, .padding = .{ 0, 0, 0 } };
    sregs.cr0 |= 0x80000001;
    sregs.cr3 = pml4_addr;
    sregs.cr4 |= 0x20;
    sregs.efer |= 0x500;

    try vcpu.sregs_set(&sregs);

    var regs = std.mem.zeroes(kvm.Regs);
    regs.rip = entry;
    regs.rsi = boot_params_addr;
    regs.rsp = boot_stack_pointer;
    regs.rbp = boot_stack_pointer;
    regs.rflags = 0x2;

    try vcpu.regs_set(&regs);
}

const phdrs_max = 64;
const sections_max = 256;

test "page tables identity map every page translate is asked about" {
    const memory = try test_memory_alloc();
    defer std.testing.allocator.free(memory);

    @memset(memory, 0);
    page_tables_write(memory);

    for ([_]u64{ 0x0, 0x7000, 0x1000, 0x3ffff0, 0x200000, 0x1fffff8 }) |vaddr| {
        const expected: ?usize = @intCast(vaddr);

        try std.testing.expectEqual(expected, translate(memory, pml4_addr, vaddr));
    }

    try std.testing.expectEqual(@as(?usize, null), translate(memory, pml4_addr, test_memory_size));
    try std.testing.expectEqual(@as(?usize, null), translate(memory, pml4_addr, 1 << 30));
}

test "load places the entry point and rejects a truncated kernel" {
    const memory = try test_memory_alloc();
    defer std.testing.allocator.free(memory);

    const seed: [rng_seed_size]u8 = @splat(0xab);

    const image: Image = .{
        .cmdline = "console=ttyS0",
        .initrd = "",
        .kernel = &minimal_elf,
        .rng_seed = seed,
    };

    try std.testing.expectEqual(@as(u64, 0x1000000), try load(memory, &image));
    try std.testing.expectEqualStrings("console=ttyS0", memory[cmdline_addr..][0..13]);

    const seed_stored = memory[setup_data_addr + setup_data_header_size ..][0..rng_seed_size];

    try std.testing.expectEqualSlices(u8, &seed, seed_stored);
    const seed_type = std.mem.readInt(u32, memory[setup_data_addr + 8 ..][0..4], .little);

    try std.testing.expectEqual(@as(u32, setup_data_rng_seed), seed_type);

    const e820_entries = memory[boot_params_addr + boot_params_field.e820_entries];

    try std.testing.expectEqual(@as(u8, 2), e820_entries);

    const truncated: Image = .{
        .cmdline = "",
        .initrd = "",
        .kernel = minimal_elf[0..32],
        .rng_seed = seed,
    };

    try std.testing.expectError(error.KernelTooSmall, load(memory, &truncated));
}

test "an mp table walks like linux reads it and names one boot processor" {
    const memory = try test_memory_alloc();
    defer std.testing.allocator.free(memory);

    @memset(memory, 0);
    mptable_write(memory, 4);

    const pointer = memory[mptable_addr..][0..mp_pointer_size];
    const table_addr = std.mem.readInt(u32, pointer[4..8], .little);
    const length = std.mem.readInt(u16, memory[table_addr + 4 ..][0..2], .little);
    const table = memory[table_addr..][0..length];
    const entries = std.mem.readInt(u16, table[34..36], .little);
    var offset: usize = 44;
    var walked: u16 = 0;
    var processors: u8 = 0;
    var boot_processors: u8 = 0;

    try std.testing.expectEqualStrings("_MP_", pointer[0..4]);
    try std.testing.expectEqual(0, mptable_checksum(pointer));
    try std.testing.expectEqualStrings("PCMP", table[0..4]);
    try std.testing.expectEqual(4, table[6]);
    try std.testing.expectEqual(0xfee0_0000, std.mem.readInt(u32, table[36..40], .little));

    for (0..entries) |_| {
        const size: usize = if (table[offset] == 0) 20 else 8;

        if (table[offset] == 0) {
            try std.testing.expectEqual(processors, table[offset + 1]);
            try std.testing.expect(table[offset + 3] & 1 != 0);

            processors += 1;
            boot_processors += table[offset + 3] >> 1 & 1;
        }

        walked += 1;
        offset += size;
    }

    var sum: u8 = 0;

    for (pointer) |byte| sum +%= byte;
    for (table) |byte| sum +%= byte;

    try std.testing.expectEqual(0, sum);
    try std.testing.expectEqual(length, offset);
    try std.testing.expectEqual(entries, walked);
    try std.testing.expectEqual(4, processors);
    try std.testing.expectEqual(1, boot_processors);
}

test "symbol lookup finds whole names in the symbol table and rejects a truncated one" {
    const image = test_elf_symbols();

    try std.testing.expectEqual(@as(u64, 0x1000), try symbol_find(&image, "alpha"));
    try std.testing.expectEqual(@as(u64, 0x2000), try symbol_find(&image, "beta"));
    try std.testing.expectError(error.SymbolMissing, symbol_find(&image, "alph"));
    try std.testing.expectError(error.SymbolMissing, symbol_find(&image, "gamma"));
    try std.testing.expectError(error.TruncatedKernel, symbol_find(image[0..300], "beta"));
    try std.testing.expectError(error.NotElf, symbol_find(image[4..], "beta"));
    try std.testing.expectError(error.TruncatedKernel, symbol_find(image[0..64], "beta"));
}

const test_alignment: std.mem.Alignment = .fromByteUnits(kvm.page_size);
const test_memory_size = 0x2000000;
const test_strings = "\x00alpha\x00beta\x00";
const test_strings_offset = 328;
const test_symbols_offset = 256;

fn test_elf_symbols() [test_strings_offset + test_strings.len]u8 {
    var image: [test_strings_offset + test_strings.len]u8 = @splat(0);

    @memcpy(image[0..64], &minimal_elf);
    int_write(u16, &image, 0x3a, 64);
    int_write(u16, &image, 0x3c, 3);
    int_write(u64, &image, 0x28, 64);

    test_section_write(&image, 1, @backingInt(elf.SHT.SYMTAB), test_symbols_offset, 72, 2);
    test_section_write(&image, 2, @backingInt(elf.SHT.STRTAB), test_strings_offset, 12, 0);
    int_write(u64, &image, 128 + 56, 24);

    int_write(u32, &image, test_symbols_offset + 24, 1);
    int_write(u64, &image, test_symbols_offset + 24 + 8, 0x1000);
    int_write(u32, &image, test_symbols_offset + 48, 7);
    int_write(u64, &image, test_symbols_offset + 48 + 8, 0x2000);

    @memcpy(image[test_strings_offset..], test_strings);

    return image;
}

fn test_memory_alloc() ![]align(kvm.page_size) u8 {
    const memory = try std.testing.allocator.alignedAlloc(u8, test_alignment, test_memory_size);

    @memset(memory, 0);

    return memory;
}

fn test_section_write(
    image: []u8,
    index: usize,
    section_type: u32,
    offset: u64,
    size: u64,
    link: u32,
) void {
    const base = 64 + index * 64;

    int_write(u32, image, base + 4, section_type);
    int_write(u64, image, base + 24, offset);
    int_write(u64, image, base + 32, size);
    int_write(u32, image, base + 40, link);
}

const minimal_elf = blk: {
    var bytes: [64]u8 = @splat(0);
    bytes[0] = 0x7f;
    bytes[1] = 'E';
    bytes[2] = 'L';
    bytes[3] = 'F';
    bytes[4] = 2;
    bytes[5] = 1;
    bytes[16] = 2;
    bytes[18] = 0x3e;

    std.mem.writeInt(u64, bytes[24..32], 0x1000000, .little);
    std.mem.writeInt(u64, bytes[32..40], 64, .little);
    std.mem.writeInt(u16, bytes[54..56], 56, .little);
    break :blk bytes;
};
