const std = @import("std");

const assert = std.debug.assert;
const linux = std.os.linux;
const IOCTL = linux.IOCTL;

pub const Error = error{
    Interrupted,
    IoctlFailed,
    MmapFailed,
    OpenFailed,
    UnsupportedApiVersion,
};

pub const Kvm = struct {
    fd: linux.fd_t,

    pub fn close(kvm: Kvm) void {
        assert(kvm.fd >= 0);
        _ = linux.close(kvm.fd);
    }

    pub fn cpuid_supported(kvm: Kvm, cpuid: *Cpuid2) Error!void {
        cpuid.nent = cpuid_entries_max;
        cpuid.padding = 0;
        _ = try ioctl(kvm.fd, request.get_supported_cpuid, @intFromPtr(cpuid));

        assert(cpuid.nent > 0);
        assert(cpuid.nent <= cpuid_entries_max);
    }

    pub fn msr_index_list(kvm: Kvm, list: *MsrList) Error!void {
        list.nmsrs = msrs_max;
        _ = try ioctl(kvm.fd, request.get_msr_index_list, @intFromPtr(list));

        assert(list.nmsrs > 0);
        assert(list.nmsrs <= msrs_max);
    }

    pub fn open() Error!Kvm {
        const rc = linux.open("/dev/kvm", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);

        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |e| {
                std.log.err("open /dev/kvm failed: {t}", .{e});

                return error.OpenFailed;
            },
        }

        const kvm: Kvm = .{ .fd = @intCast(rc) };
        const version = try ioctl(kvm.fd, request.get_api_version, 0);

        if (version != api_version) {
            std.log.err("KVM API version {d}, expected {d}", .{ version, api_version });

            return error.UnsupportedApiVersion;
        }

        assert(kvm.fd >= 0);

        return kvm;
    }

    pub fn vm_create(kvm: Kvm) Error!Vm {
        const fd: linux.fd_t = @intCast(try ioctl(kvm.fd, request.create_vm, 0));
        const vcpu_mmap_size = try ioctl(kvm.fd, request.get_vcpu_mmap_size, 0);

        assert(vcpu_mmap_size >= @sizeOf(Run));
        assert(vcpu_mmap_size % page_size == 0);

        return .{ .fd = fd, .vcpu_mmap_size = vcpu_mmap_size };
    }
};

pub const Vm = struct {
    fd: linux.fd_t,
    vcpu_mmap_size: usize,

    pub fn close(vm: Vm) void {
        _ = linux.close(vm.fd);
    }

    pub fn identity_map_addr_set(vm: Vm, addr: u64) Error!void {
        assert(addr % page_size == 0);
        _ = try ioctl(vm.fd, request.set_identity_map_addr, @intFromPtr(&addr));
    }

    pub fn memory_region_set(
        vm: Vm,
        slot: u32,
        guest_phys_addr: u64,
        memory: []align(page_size) u8,
    ) Error!void {
        assert(memory.len > 0);
        assert(memory.len % page_size == 0);
        assert(guest_phys_addr % page_size == 0);

        const region: UserspaceMemoryRegion = .{
            .slot = slot,
            .flags = 0,
            .guest_phys_addr = guest_phys_addr,
            .memory_size = memory.len,
            .userspace_addr = @intFromPtr(memory.ptr),
        };

        _ = try ioctl(vm.fd, request.set_user_memory_region, @intFromPtr(&region));
    }

    pub fn tss_addr_set(vm: Vm, addr: u64) Error!void {
        assert(addr % page_size == 0);
        _ = try ioctl(vm.fd, request.set_tss_addr, addr);
    }

    pub fn vcpu_create(vm: Vm, id: u32) Error!Vcpu {
        const fd: linux.fd_t = @intCast(try ioctl(vm.fd, request.create_vcpu, id));

        const run_area = try mmap(
            vm.vcpu_mmap_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
        );

        assert(run_area.len == vm.vcpu_mmap_size);

        return .{ .fd = fd, .run_area = run_area };
    }
};

pub const Vcpu = struct {
    fd: linux.fd_t,
    run_area: []align(page_size) u8,

    pub fn close(vcpu: Vcpu) void {
        _ = linux.munmap(vcpu.run_area.ptr, vcpu.run_area.len);
        _ = linux.close(vcpu.fd);
    }

    pub fn cpuid_set(vcpu: Vcpu, cpuid: *const Cpuid2) Error!void {
        assert(cpuid.nent > 0);
        assert(cpuid.nent <= cpuid_entries_max);
        _ = try ioctl(vcpu.fd, request.set_cpuid2, @intFromPtr(cpuid));
    }

    pub fn debugregs_get(vcpu: Vcpu, debugregs: *Debugregs) Error!void {
        _ = try ioctl(vcpu.fd, request.get_debugregs, @intFromPtr(debugregs));
    }

    pub fn debugregs_set(vcpu: Vcpu, debugregs: *const Debugregs) Error!void {
        assert(debugregs.flags == 0);
        _ = try ioctl(vcpu.fd, request.set_debugregs, @intFromPtr(debugregs));
    }

    pub fn events_get(vcpu: Vcpu, events: *VcpuEvents) Error!void {
        _ = try ioctl(vcpu.fd, request.get_vcpu_events, @intFromPtr(events));
    }

    pub fn events_set(vcpu: Vcpu, events: *const VcpuEvents) Error!void {
        assert(events.flags & ~vcpu_events_valid_all == 0);
        _ = try ioctl(vcpu.fd, request.set_vcpu_events, @intFromPtr(events));
    }

    pub fn guest_debug_set(
        vcpu: Vcpu,
        single_step: bool,
        breakpoints: *const Breakpoints,
    ) Error!void {
        var debug: GuestDebug = .{
            .control = guest_debug_enable | guest_debug_use_hw_bp,
            .pad = 0,
            .debugreg = @splat(0),
        };

        if (single_step) debug.control |= guest_debug_single_step;

        debug.debugreg[dr7_index] = dr7_fixed;

        for (breakpoints, 0..) |breakpoint, slot| {
            const address = breakpoint orelse continue;

            assert(address != 0);

            debug.debugreg[slot] = address;
            debug.debugreg[dr7_index] |= @as(u64, dr7_local_enable) << @intCast(slot * 2);
        }

        assert(debug.debugreg[dr7_index] & dr7_fixed != 0);
        _ = try ioctl(vcpu.fd, request.set_guest_debug, @intFromPtr(&debug));
    }

    pub fn interrupt_inject(vcpu: Vcpu, vector: u8) Error!void {
        assert(vector >= 0x20);

        const arg: Interrupt = .{ .irq = vector };
        _ = try ioctl(vcpu.fd, request.interrupt, @intFromPtr(&arg));
    }

    pub fn io_complete(vcpu: Vcpu) Error!void {
        const area = vcpu.run_area_view();

        assert(area.immediate_exit == 0);

        area.immediate_exit = 1;
        defer area.immediate_exit = 0;

        _ = vcpu.run() catch |err| switch (err) {
            error.Interrupted => return,
            else => return err,
        };

        std.log.err("KVM_RUN entered the guest with immediate_exit set", .{});

        return error.IoctlFailed;
    }

    pub fn msrs_get(vcpu: Vcpu, entries: []MsrEntry) Error!usize {
        assert(entries.len > 0);
        assert(entries.len <= msrs_max);

        var msrs: Msrs = .{ .nmsrs = @intCast(entries.len), .pad = 0, .entries = undefined };

        @memcpy(msrs.entries[0..entries.len], entries);

        const read = try ioctl(vcpu.fd, request.get_msrs, @intFromPtr(&msrs));

        assert(read <= entries.len);

        @memcpy(entries[0..read], msrs.entries[0..read]);

        return read;
    }

    pub fn msrs_set(vcpu: Vcpu, entries: []const MsrEntry) Error!usize {
        assert(entries.len > 0);
        assert(entries.len <= msrs_max);

        var msrs: Msrs = .{ .nmsrs = @intCast(entries.len), .pad = 0, .entries = undefined };

        @memcpy(msrs.entries[0..entries.len], entries);

        const written = try ioctl(vcpu.fd, request.set_msrs, @intFromPtr(&msrs));

        assert(written <= entries.len);

        return written;
    }

    pub fn nmi_inject(vcpu: Vcpu) Error!void {
        assert(vcpu.fd >= 0);

        _ = try ioctl(vcpu.fd, request.nmi, 0);
    }

    pub fn regs_get(vcpu: Vcpu, regs: *Regs) Error!void {
        _ = try ioctl(vcpu.fd, request.get_regs, @intFromPtr(regs));
    }

    pub fn regs_set(vcpu: Vcpu, regs: *const Regs) Error!void {
        assert(regs.rflags & 0x2 != 0);
        _ = try ioctl(vcpu.fd, request.set_regs, @intFromPtr(regs));
    }

    pub fn run(vcpu: Vcpu) Error!*Run {
        _ = try ioctl(vcpu.fd, request.run, 0);

        return vcpu.run_area_view();
    }

    pub fn run_area_view(vcpu: Vcpu) *Run {
        assert(vcpu.run_area.len >= @sizeOf(Run));

        return @ptrCast(vcpu.run_area.ptr);
    }

    pub fn sregs_get(vcpu: Vcpu, sregs: *Sregs) Error!void {
        _ = try ioctl(vcpu.fd, request.get_sregs, @intFromPtr(sregs));
    }

    pub fn sregs_set(vcpu: Vcpu, sregs: *const Sregs) Error!void {
        assert(sregs.cs.present == 1);
        _ = try ioctl(vcpu.fd, request.set_sregs, @intFromPtr(sregs));
    }

    pub fn xcrs_get(vcpu: Vcpu, xcrs: *Xcrs) Error!void {
        _ = try ioctl(vcpu.fd, request.get_xcrs, @intFromPtr(xcrs));

        assert(xcrs.nr_xcrs <= xcrs_max);
    }

    pub fn xcrs_set(vcpu: Vcpu, xcrs: *const Xcrs) Error!void {
        assert(xcrs.nr_xcrs <= xcrs_max);
        _ = try ioctl(vcpu.fd, request.set_xcrs, @intFromPtr(xcrs));
    }

    pub fn xsave_get(vcpu: Vcpu, xsave: *Xsave) Error!void {
        _ = try ioctl(vcpu.fd, request.get_xsave, @intFromPtr(xsave));
    }

    pub fn xsave_set(vcpu: Vcpu, xsave: *const Xsave) Error!void {
        _ = try ioctl(vcpu.fd, request.set_xsave, @intFromPtr(xsave));
    }
};

pub const Breakpoints = [breakpoints_max]?u64;

pub const Cpuid2 = extern struct {
    nent: u32,
    padding: u32,
    entries: [cpuid_entries_max]CpuidEntry2,
};

pub const CpuidEntry2 = extern struct {
    function: u32,
    index: u32,
    flags: u32,
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    padding: [3]u32,
};

pub const DebugExit = extern struct {
    exception: u32,
    pad: u32,
    pc: u64,
    dr6: u64,
    dr7: u64,
};

pub const Debugregs = extern struct {
    db: [4]u64,
    dr6: u64,
    dr7: u64,
    flags: u64,
    reserved: [9]u64,
};

pub const Dtable = extern struct {
    base: u64,
    limit: u16,
    padding: [3]u16,
};

pub const Exit = enum(u32) {
    unknown = 0,
    exception = 1,
    io = 2,
    hypercall = 3,
    debug = 4,
    hlt = 5,
    mmio = 6,
    irq_window_open = 7,
    shutdown = 8,
    fail_entry = 9,
    intr = 10,
    set_tpr = 11,
    tpr_access = 12,
    internal_error = 17,
    _,
};

pub const IoDirection = enum(u8) {
    in = 0,
    out = 1,
};

pub const GuestDebug = extern struct {
    control: u32,
    pad: u32,
    debugreg: [8]u64,
};

pub const Interrupt = extern struct {
    irq: u32,
};

pub const MsrEntry = extern struct {
    index: u32,
    reserved: u32,
    data: u64,
};

pub const MsrList = extern struct {
    nmsrs: u32,
    indices: [msrs_max]u32,
};

pub const Msrs = extern struct {
    nmsrs: u32,
    pad: u32,
    entries: [msrs_max]MsrEntry,
};

pub const Regs = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rsp: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,
};

pub const Run = extern struct {
    request_interrupt_window: u8,
    immediate_exit: u8,
    padding1: [6]u8,
    exit_reason: Exit,
    ready_for_interrupt_injection: u8,
    if_flag: u8,
    flags: u16,
    cr8: u64,
    apic_base: u64,
    exit: extern union {
        fail_entry: extern struct {
            hardware_entry_failure_reason: u64,
            cpu: u32,
        },

        internal: extern struct {
            suberror: u32,
            ndata: u32,
            data: [16]u64,
        },

        io: extern struct {
            direction: IoDirection,
            size: u8,
            port: u16,
            count: u32,
            data_offset: u64,
        },

        mmio: extern struct {
            phys_addr: u64,
            data: [8]u8,
            len: u32,
            is_write: u8,
        },
        debug: DebugExit,
    },

    pub fn io_data(run: *Run) []u8 {
        assert(run.exit_reason == .io);

        const io = run.exit.io;
        const size: usize = @as(usize, io.size) * io.count;

        assert(io.size == 1 or io.size == 2 or io.size == 4);
        assert(io.data_offset >= @sizeOf(Run));

        const base: [*]u8 = @ptrCast(run);
        return base[io.data_offset..][0..size];
    }
};

pub const Segment = extern struct {
    base: u64,
    limit: u32,
    selector: u16,
    type: u8,
    present: u8,
    dpl: u8,
    db: u8,
    s: u8,
    l: u8,
    g: u8,
    avl: u8,
    unusable: u8,
    padding: u8,
};

pub const Sregs = extern struct {
    cs: Segment,
    ds: Segment,
    es: Segment,
    fs: Segment,
    gs: Segment,
    ss: Segment,
    tr: Segment,
    ldt: Segment,
    gdt: Dtable,
    idt: Dtable,
    cr0: u64,
    cr2: u64,
    cr3: u64,
    cr4: u64,
    cr8: u64,
    efer: u64,
    apic_base: u64,
    interrupt_bitmap: [4]u64,
};

pub const UserspaceMemoryRegion = extern struct {
    slot: u32,
    flags: u32,
    guest_phys_addr: u64,
    memory_size: u64,
    userspace_addr: u64,
};

pub const VcpuEvents = extern struct {
    exception: extern struct {
        injected: u8,
        nr: u8,
        has_error_code: u8,
        pending: u8,
        error_code: u32,
    },

    interrupt: extern struct {
        injected: u8,
        nr: u8,
        soft: u8,
        shadow: u8,
    },

    nmi: extern struct {
        injected: u8,
        pending: u8,
        masked: u8,
        pad: u8,
    },
    sipi_vector: u32,
    flags: u32,
    smi: extern struct {
        smm: u8,
        pending: u8,
        smm_inside_nmi: u8,
        latched_init: u8,
    },
    triple_fault_pending: u8,
    reserved: [26]u8,
    exception_has_payload: u8,
    exception_payload: u64,
};

pub const Xcr = extern struct {
    xcr: u32,
    reserved: u32,
    value: u64,
};

pub const Xcrs = extern struct {
    nr_xcrs: u32,
    flags: u32,
    xcrs: [xcrs_max]Xcr,
    padding: [16]u64,
};

pub const Xsave = extern struct {
    region: [1024]u32,
};

const CpuidHeader = extern struct {
    nent: u32,
    padding: u32,
};

const MsrListHeader = extern struct {
    nmsrs: u32,
};

const MsrsHeader = extern struct {
    nmsrs: u32,
    pad: u32,
};

pub const api_version = 12;
pub const breakpoints_max = 4;
pub const breakpoints_none: Breakpoints = @splat(null);
pub const cpuid_entries_max = 256;
pub const exception_debug = 1;
pub const guest_debug_enable = 0x1;
pub const guest_debug_single_step = 0x2;
pub const guest_debug_use_hw_bp = 0x20000;
pub const msr_ia32_misc_enable = 0x1a0;
pub const msr_ia32_misc_enable_fast_string = 0x1;
pub const msr_lstar = 0xc0000082;
pub const msrs_max = 256;
pub const page_size = 4096;
pub const vcpu_events_valid_all: u32 = 0x3f;
pub const vcpu_events_valid_nmi_pending: u32 = 0x1;
pub const xcrs_max = 16;
const dr7_fixed = 0x400;
const dr7_index = 7;
const dr7_local_enable = 0x1;
const kvmio = 0xAE;

const request = struct {
    const create_vcpu = IOCTL.IO(kvmio, 0x41);
    const create_vm = IOCTL.IO(kvmio, 0x01);
    const get_api_version = IOCTL.IO(kvmio, 0x00);
    const get_debugregs = IOCTL.IOR(kvmio, 0xa1, Debugregs);
    const get_msr_index_list = IOCTL.IOWR(kvmio, 0x02, MsrListHeader);
    const get_msrs = IOCTL.IOWR(kvmio, 0x88, MsrsHeader);
    const get_regs = IOCTL.IOR(kvmio, 0x81, Regs);
    const get_sregs = IOCTL.IOR(kvmio, 0x83, Sregs);
    const get_supported_cpuid = IOCTL.IOWR(kvmio, 0x05, CpuidHeader);
    const get_vcpu_events = IOCTL.IOR(kvmio, 0x9f, VcpuEvents);
    const get_vcpu_mmap_size = IOCTL.IO(kvmio, 0x04);
    const get_xcrs = IOCTL.IOR(kvmio, 0xa6, Xcrs);
    const get_xsave = IOCTL.IOR(kvmio, 0xa4, Xsave);
    const interrupt = IOCTL.IOW(kvmio, 0x86, Interrupt);
    const nmi = IOCTL.IO(kvmio, 0x9a);
    const run = IOCTL.IO(kvmio, 0x80);
    const set_cpuid2 = IOCTL.IOW(kvmio, 0x90, CpuidHeader);
    const set_debugregs = IOCTL.IOW(kvmio, 0xa2, Debugregs);
    const set_guest_debug = IOCTL.IOW(kvmio, 0x9b, GuestDebug);
    const set_identity_map_addr = IOCTL.IOW(kvmio, 0x48, u64);
    const set_msrs = IOCTL.IOW(kvmio, 0x89, MsrsHeader);
    const set_regs = IOCTL.IOW(kvmio, 0x82, Regs);
    const set_sregs = IOCTL.IOW(kvmio, 0x84, Sregs);
    const set_tss_addr = IOCTL.IO(kvmio, 0x47);
    const set_user_memory_region = IOCTL.IOW(kvmio, 0x46, UserspaceMemoryRegion);
    const set_vcpu_events = IOCTL.IOW(kvmio, 0xa0, VcpuEvents);
    const set_xcrs = IOCTL.IOW(kvmio, 0xa7, Xcrs);
    const set_xsave = IOCTL.IOW(kvmio, 0xa5, Xsave);
};

comptime {
    assert(@sizeOf(CpuidEntry2) == 40);
    assert(@sizeOf(DebugExit) == 32);
    assert(@offsetOf(DebugExit, "pc") == 8);
    assert(@sizeOf(Debugregs) == 128);
    assert(@sizeOf(GuestDebug) == 72);
    assert(breakpoints_max < dr7_index);
    assert(@sizeOf(Interrupt) == 4);
    assert(@sizeOf(MsrEntry) == 16);
    assert(@sizeOf(Regs) == 144);
    assert(@sizeOf(Sregs) == 312);
    assert(@sizeOf(UserspaceMemoryRegion) == 32);
    assert(@sizeOf(VcpuEvents) == 64);
    assert(@sizeOf(Xcrs) == 392);
    assert(@sizeOf(Xsave) == 4096);
    assert(@offsetOf(Run, "exit") == 32);
    assert(@offsetOf(VcpuEvents, "exception_payload") == 56);
    assert(request.interrupt == 0x4004ae86);
    assert(request.set_guest_debug == 0x4048ae9b);
    assert(request.set_msrs == 0x4008ae89);
    assert(request.set_user_memory_region == 0x4020ae46);
    assert(request.get_sregs == 0x8138ae83);
    assert(request.get_msr_index_list == 0xc004ae02);
    assert(request.get_vcpu_events == 0x8040ae9f);
    assert(request.get_xsave == 0x9000aea4);
    assert(request.set_xcrs == 0x4188aea7);
}

fn ioctl(fd: linux.fd_t, nr: u32, arg: usize) Error!usize {
    assert(fd >= 0);

    const rc = linux.ioctl(fd, nr, arg);

    switch (linux.errno(rc)) {
        .SUCCESS => return rc,
        .INTR => return error.Interrupted,
        else => |e| {
            std.log.err("ioctl {x} on fd {d} failed: {t}", .{ nr, fd, e });

            return error.IoctlFailed;
        },
    }
}

fn mmap(
    size: usize,
    prot: linux.PROT,
    flags: linux.MAP,
    fd: linux.fd_t,
) Error![]align(page_size) u8 {
    assert(size > 0);
    assert(size % page_size == 0);

    const rc = linux.mmap(null, size, prot, flags, fd, 0);

    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| {
            std.log.err("mmap of {d} bytes failed: {t}", .{ size, e });

            return error.MmapFailed;
        },
    }

    assert(rc % page_size == 0);

    const ptr: [*]align(page_size) u8 = @ptrFromInt(rc);
    return ptr[0..size];
}

pub fn file_map_private(fd: linux.fd_t, size: usize) Error![]align(page_size) u8 {
    assert(fd >= 0);
    assert(size > 0);
    assert(size % page_size == 0);

    const prot: linux.PROT = .{ .READ = true, .WRITE = true };
    const flags: linux.MAP = .{ .TYPE = .PRIVATE };

    return mmap(size, prot, flags, fd);
}

pub fn guest_memory_alloc(size: usize) Error![]align(page_size) u8 {
    assert(size > 0);
    assert(size % page_size == 0);

    const prot: linux.PROT = .{ .READ = true, .WRITE = true };
    const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };

    return mmap(size, prot, flags, -1);
}

pub fn guest_memory_clear(memory: []align(page_size) u8) Error!void {
    assert(memory.len > 0);
    assert(memory.len % page_size == 0);

    const rc = linux.madvise(memory.ptr, memory.len, linux.MADV.DONTNEED);

    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| {
            std.log.err("madvise of {d} bytes failed: {t}", .{ memory.len, e });

            return error.MmapFailed;
        },
    }
}

pub fn guest_memory_free(memory: []align(page_size) u8) void {
    assert(memory.len % page_size == 0);
    _ = linux.munmap(memory.ptr, memory.len);
}

pub fn shared_memory_alloc(size: usize) Error![]align(page_size) u8 {
    assert(size > 0);
    assert(size % page_size == 0);

    const prot: linux.PROT = .{ .READ = true, .WRITE = true };
    const flags: linux.MAP = .{ .TYPE = .SHARED, .ANONYMOUS = true };

    return mmap(size, prot, flags, -1);
}

test "smoke guest prints the sum of rax and rbx" {
    const code = [_]u8{ 0xba, 0xf8, 0x03, 0x00, 0xd8, 0x04, '0', 0xee, 0xb0, '\n', 0xee, 0xf4 };
    const code_addr = 0x1000;
    const handle = try Kvm.open();
    defer handle.close();

    const vm = try handle.vm_create();
    defer vm.close();

    const memory = try guest_memory_alloc(0x10000);
    defer guest_memory_free(memory);

    @memcpy(memory[code_addr..][0..code.len], &code);
    try vm.memory_region_set(0, 0, memory);

    const vcpu = try vm.vcpu_create(0);
    defer vcpu.close();

    var sregs: Sregs = undefined;

    try vcpu.sregs_get(&sregs);
    sregs.cs.base = 0;
    sregs.cs.selector = 0;

    try vcpu.sregs_set(&sregs);

    var regs = std.mem.zeroes(Regs);
    regs.rip = code_addr;
    regs.rax = 2;
    regs.rbx = 2;
    regs.rflags = 0x2;

    try vcpu.regs_set(&regs);

    var output: [16]u8 = undefined;
    var serial: std.Io.Writer = .fixed(&output);
    var exits: u32 = 0;

    while (exits < 16) : (exits += 1) {
        const area = try vcpu.run();

        switch (area.exit_reason) {
            .hlt => break,
            .io => try serial.writeAll(area.io_data()),
            else => return error.UnexpectedExit,
        }
    }

    try std.testing.expect(exits < 16);
    try std.testing.expectEqualStrings("4\n", serial.buffered());
}
