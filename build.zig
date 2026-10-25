const std = @import("std");

const format_paths = [_][]const u8{ "build.zig", "src" };

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
                .{ .name = "dst", .module = sdk_module(b, ports) },
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

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const sdk_tests = b.addTest(.{ .root_module = sdk_module(b, ports) });
    const run_sdk_tests = b.addRunArtifact(sdk_tests);
    const test_step = b.step("test", "Run every test suite and the format check");

    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_sdk_tests.step);

    const guest_step = guests_add(b);
    const compiles = [_]*std.Build.Step.Compile{ exe, exe_tests, sdk_tests };

    checks_add(b, &compiles, guest_step, test_step);
}

fn guests_add(b: *std.Build) *std.Build.Step {
    const guest_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const conformance = guest_executable(
        b,
        guest_target,
        "conformance-zig",
        "guest/projects/conformance/zig/main.zig",
    );

    const driver = guest_executable(
        b,
        guest_target,
        "tigerstyle-driver",
        "guest/projects/tigerstyle/harness/driver.zig",
    );

    const guest_step = b.step("guest", "Build the guest programs");

    for ([_]*std.Build.Step.Compile{ conformance, driver }) |guest| {
        guest_install(b, guest_step, guest);
    }

    docker_guest_add(b, guest_target, guest_step);

    return guest_step;
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

    const format = b.addFmt(.{
        .paths = b.pathList(&format_paths),
        .check = true,
    });

    const format_step = b.step("test:fmt", "Check that every source file is formatted");
    const ci_step = b.step("ci", "Compile every artifact and check the format");

    format_step.dependOn(&format.step);
    test_step.dependOn(format_step);
    ci_step.dependOn(check_step);
    ci_step.dependOn(format_step);
}

fn docker_guest_add(b: *std.Build, target: std.Build.ResolvedTarget, step: *std.Build.Step) void {
    const source = b.option(
        []const u8,
        "docker-zig",
        "An exported tree holding bounded-zig, docker-zig, and json-zig, for the docker-zig guest",
    ) orelse return;

    const docker_driver = guest_executable_with(
        b,
        target,
        "docker-zig-driver",
        "guest/projects/docker-zig/harness/driver.zig",
        &.{.{ .name = "docker", .module = docker_module(b, target, source) }},
    );

    guest_install(b, step, docker_driver);
}

fn docker_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    source: []const u8,
) *std.Build.Module {
    const bounded_root = b.pathJoin(&.{ source, "bounded-zig/src/bounded.zig" });
    const json_root = b.pathJoin(&.{ source, "json-zig/src/json.zig" });
    const docker_root = b.pathJoin(&.{ source, "docker-zig/src/docker.zig" });

    const bounded = b.createModule(.{
        .root_source_file = .{ .cwd_relative = bounded_root },
        .target = target,
        .optimize = .safe,
    });

    const json = b.createModule(.{
        .root_source_file = .{ .cwd_relative = json_root },
        .target = target,
        .optimize = .safe,
    });

    return b.createModule(.{
        .root_source_file = .{ .cwd_relative = docker_root },
        .target = target,
        .optimize = .safe,
        .imports = &.{
            .{ .name = "bounded", .module = bounded },
            .{ .name = "json", .module = json },
        },
    });
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
    return guest_executable_with(b, target, name, root, &.{});
}

fn guest_executable_with(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    root: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    const ports = ports_module(b, target, .safe);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = .safe,
            .link_libc = true,
            .imports = &.{.{ .name = "dst", .module = sdk_module(b, ports) }},
        }),
    });

    for (imports) |import| exe.root_module.addImport(import.name, import.module);

    exe.sanitize_coverage_trace_pc_guard = true;

    exe.root_module.addCSourceFile(.{
        .file = b.path("guest/sdk/c/coverage.c"),
        .flags = &.{"-std=c11"},
    });

    return exe;
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
        .root_source_file = b.path("guest/sdk/zig/dst.zig"),
        .target = ports.resolved_target.?,
        .optimize = ports.optimize.?,
        .imports = &.{.{ .name = "ports", .module = ports }},
    });
}
