const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the executable");

    // The profiling engine as a reusable module: `@import("parakh")`.
    const lib_mod = b.addModule("parakh", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "parakh",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "parakh", .module = lib_mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Profile a CSV: zig build run -- data.csv");
    run_step.dependOn(&run_cmd.step);

    // Browser demo: the same engine compiled to WebAssembly, installed next
    // to the static site in zig-out/web/.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .simd128, .bulk_memory }),
    });
    const wasm_lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseFast,
    });
    const wasm = b.addExecutable(.{
        .name = "parakh",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseFast,
            .strip = true,
            .imports = &.{.{ .name = "parakh", .module = wasm_lib }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_step = b.step("wasm", "Build the browser demo into zig-out/web");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    wasm_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .{ .custom = "web" },
        .install_subdir = "",
    }).step);

    const test_step = b.step("test", "Run unit and end-to-end tests");
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const cli_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "parakh", .module = lib_mod }},
    });
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    test_step.dependOn(&b.addRunArtifact(e2e_tests).step);
}
