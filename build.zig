const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Comptime feature profile: full by default, minimal strips
    // images / eye-candy / alt-screen at compile time (sfte-macro equivalent).
    const minimal = b.option(bool, "minimal", "Minimal build: no images, eye-candy, or alt-screen") orelse false;
    const ascii_only = b.option(bool, "ascii-only", "Store cells as u8 (ASCII only, halves grid memory)") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "minimal", minimal);
    options.addOption(bool, "ascii_only", ascii_only);

    // Wayland core C decls (translateC over wayland-client-core.h).
    // xdg-shell tables are hand-written in Zig (no scanner step).
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/cdef.h"),
        .target = target,
        .optimize = optimize,
    });
    // freetype2 headers live outside the default include path.
    translate_c.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "c", .module = translate_c.createModule() },
        },
    });

    root_module.linkSystemLibrary("wayland-client", .{});
    root_module.linkSystemLibrary("xkbcommon", .{});
    root_module.linkSystemLibrary("freetype2", .{ .preferred_link_mode = .dynamic });
    root_module.linkSystemLibrary("fontconfig", .{ .preferred_link_mode = .dynamic });
    root_module.linkSystemLibrary("rt", .{});
    root_module.linkSystemLibrary("m", .{});
    root_module.linkSystemLibrary("util", .{});

    const exe = b.addExecutable(.{
        .name = "zinc",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zinc");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "c", .module = translate_c.createModule() },
        },
    });
    test_module.linkSystemLibrary("wayland-client", .{});
    test_module.linkSystemLibrary("xkbcommon", .{});
    test_module.linkSystemLibrary("freetype2", .{ .preferred_link_mode = .dynamic });
    test_module.linkSystemLibrary("fontconfig", .{ .preferred_link_mode = .dynamic });
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Compile-only check: builds exe + test binaries without installing
    // or executing anything.
    const check_exe = b.addExecutable(.{
        .name = "zinc-check",
        .root_module = root_module,
    });
    const check_tests = b.addTest(.{
        .name = "check-tests",
        .root_module = test_module,
    });
    const check_step = b.step("check", "Compile check only (no install, no run)");
    check_step.dependOn(&check_exe.step);
    check_step.dependOn(&check_tests.step);
}
