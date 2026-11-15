const std = @import("std");

const format_paths = [_][]const u8{ "build.zig", "src" };

const Guests = struct {
    conformance: *std.Build.Step.Compile,
    step: *std.Build.Step,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ports = ports_module(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "celeste",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "celeste", .module = sdk_module(b, ports) },
                .{ .name = "ports", .module = ports },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run celeste");

    run_step.dependOn(&run_cmd.step);

    const filter_help = "Run only the tests whose names hold this text";
    const filters = b.option([]const []const u8, "test-filter", filter_help) orelse &.{};
    const exe_tests = b.addTest(.{ .filters = filters, .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const sdk_tests = b.addTest(.{ .filters = filters, .root_module = sdk_module(b, ports) });
    const run_sdk_tests = b.addRunArtifact(sdk_tests);
    const test_step = b.step("test", "Run every test suite and the format check");

    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_sdk_tests.step);

    const guests = guests_add(b);
    const compiles = [_]*std.Build.Step.Compile{ exe, exe_tests, sdk_tests };

    checks_add(b, &compiles, guests.step, test_step);
    images_add(b, &guests);
}

fn guests_add(b: *std.Build) Guests {
    const guest_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const conformance = guest_executable(
        b,
        guest_target,
        "conformance-zig",
        "tests/conformance/zig/main.zig",
    );

    const guest_step = b.step("guest", "Build the guest programs");

    guest_install(b, guest_step, conformance);

    return .{ .conformance = conformance, .step = guest_step };
}

fn checks_add(
    b: *std.Build,
    compiles: []const *std.Build.Step.Compile,
    guest_step: *std.Build.Step,
    test_step: *std.Build.Step,
) void {
    const check_step = b.step("check", "Compile every artifact without running it");

    for (compiles) |compile| {
        check_step.dependOn(&compile.step);
    }

    check_step.dependOn(guest_step);

    const format = b.addFmt(.{ .paths = b.pathList(&format_paths), .check = true });
    const format_step = b.step("test:fmt", "Check that every source file is formatted");
    const ci_step = b.step("ci", "Compile every artifact and check the format");

    format_step.dependOn(&format.step);
    test_step.dependOn(format_step);
    ci_step.dependOn(check_step);
    ci_step.dependOn(format_step);
}

fn docker_build(b: *std.Build, arguments: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "docker", "build" });

    run.addArgs(arguments);
    run.setCwd(b.path("."));
    run.has_side_effects = true;

    return run;
}

fn guest_install(b: *std.Build, step: *std.Build.Step, guest: *std.Build.Step.Compile) void {
    step.dependOn(&b.addInstallArtifact(guest, .{
        .dest_dir = .{ .override = .{ .custom = "guest" } },
    }).step);
}

fn guest_executable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    root: []const u8,
) *std.Build.Step.Compile {
    const ports = ports_module(b, target, .safe);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = .safe,
            .link_libc = true,
            .imports = &.{.{ .name = "celeste", .module = sdk_module(b, ports) }},
        }),
    });

    exe.sanitize_coverage_trace_pc_guard = true;

    exe.root_module.addCSourceFile(.{
        .file = b.path("guest/sdk/c/coverage.c"),
        .flags = &.{"-std=c11"},
    });

    return exe;
}

fn images_add(b: *std.Build, guests: *const Guests) void {
    const base = docker_build(b, &.{ "--target", "base", "-t", "celeste-base", "guest" });
    const ext4 = docker_build(b, &.{ "--target", "ext4-tools", "-t", "celeste-ext4", "guest" });
    const base_disk = docker_build(b, &.{ "--target", "base-image", "-o", "images", "guest" });
    const ledger = docker_build(b, &.{ "-o", "images", "tests/fixtures/ledger" });
    const kernel = docker_build(b, &.{ "-o", "images", "guest" });
    const binaries = b.addWriteFiles();

    _ = binaries.addCopyFile(guests.conformance.getEmittedBin(), "conformance-zig");

    const conformance = docker_build(b, &.{
        "--build-context",
        "conformance=tests/conformance",
        "--build-context",
    });

    conformance.addPrefixedDirectoryArg("guests=", binaries.getDirectory());
    conformance.addArgs(&.{ "-f", "tests/conformance/Dockerfile", "-o", "images", "guest" });

    for ([_]*std.Build.Step.Run{ ledger, conformance }) |image| {
        image.step.dependOn(&base.step);
        image.step.dependOn(&ext4.step);
    }

    const images_step = b.step("images", "Build the base image and test guest disks with Docker");
    const kernel_step = b.step("images:kernel", "Build the kernel and the bare rootfs with Docker");

    images_step.dependOn(&base_disk.step);
    images_step.dependOn(&ledger.step);
    images_step.dependOn(&conformance.step);
    kernel_step.dependOn(&kernel.step);
}

fn ports_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/ports.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn sdk_module(b: *std.Build, ports: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("guest/sdk/zig/celeste.zig"),
        .target = ports.resolved_target.?,
        .optimize = ports.optimize.?,
        .imports = &.{.{ .name = "ports", .module = ports }},
    });
}
