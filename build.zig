const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Comptime feature profile: full by default, minimal strips
    // images / eye-candy / alt-screen at compile time (sfte-macro equivalent).
    const minimal = b.option(bool, "minimal", "Minimal build: no images, eye-candy, or alt-screen") orelse false;
    const ascii_only = b.option(bool, "ascii-only", "Store cells as u8 (ASCII only, halves grid memory)") orelse false;
    const version = b.option([]const u8, "version", "Package version string") orelse "0.1.0";

    const options = b.addOptions();
    options.addOption(bool, "minimal", minimal);
    options.addOption(bool, "ascii_only", ascii_only);
    options.addOption([]const u8, "version", version);

    // Wayland core C decls (translateC over wayland-client-core.h).
    // xdg-shell tables are hand-written in Zig (no scanner step).
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/cdef.h"),
        .target = target,
        .optimize = optimize,
    });

    addPkgConfigIncludes(b, translate_c, "wayland-client");
    addPkgConfigIncludes(b, translate_c, "freetype2");
    addPkgConfigIncludes(b, translate_c, "fontconfig");
    addPkgConfigIncludes(b, translate_c, "xkbcommon");

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

    // Desktop integration: `zig build install --prefix ~/.local` (or /usr
    // as root) lays out bin/ + share/applications + share/icons +
    // share/metainfo. Everything is prefix-relative — nothing here touches
    // the live system; the prefix decides the destination.
    const install_step = b.getInstallStep();
    install_step.dependOn(&b.addInstallFileWithDir(
        b.path("assets/io.github.mvkweb.zinc.desktop"),
        .prefix,
        "share/applications/io.github.mvkweb.zinc.desktop",
    ).step);
    install_step.dependOn(&b.addInstallFileWithDir(
        b.path("assets/io.github.mvkweb.zinc.metainfo.xml"),
        .prefix,
        "share/metainfo/io.github.mvkweb.zinc.metainfo.xml",
    ).step);
    // Whole hicolor tree in one step: adding a size later means dropping
    // in a file, no build.zig edit.
    install_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("assets/icons/hicolor"),
        .install_dir = .prefix,
        .install_subdir = "share/icons/hicolor",
    }).step);
    install_step.dependOn(&b.addInstallFileWithDir(
        b.path("assets/icons/pixmaps/zinc.png"),
        .prefix,
        "share/pixmaps/zinc.png",
    ).step);
    install_step.dependOn(&b.addInstallFileWithDir(
        b.path("assets/icons/pixmaps/io.github.mvkweb.zinc.png"),
        .prefix,
        "share/pixmaps/io.github.mvkweb.zinc.png",
    ).step);

    // Override the unimplemented std.Build uninstall step so `zig build uninstall`
    // cleanly removes all installed files from the destination prefix.
    b.getUninstallStep().makeFn = makeUninstall;
}

fn makeUninstall(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
    _ = options;
    const b = step.owner;
    const prefix = b.install_path;

    const files_to_remove = [_][]const u8{
        b.pathJoin(&.{ prefix, "bin/zinc" }),
        b.pathJoin(&.{ prefix, "share/applications/io.github.mvkweb.zinc.desktop" }),
        b.pathJoin(&.{ prefix, "share/metainfo/io.github.mvkweb.zinc.metainfo.xml" }),
        b.pathJoin(&.{ prefix, "share/pixmaps/zinc.png" }),
        b.pathJoin(&.{ prefix, "share/pixmaps/io.github.mvkweb.zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/16x16/apps/zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/16x16/apps/io.github.mvkweb.zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/32x32/apps/zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/32x32/apps/io.github.mvkweb.zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/48x48/apps/zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/48x48/apps/io.github.mvkweb.zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/64x64/apps/zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/64x64/apps/io.github.mvkweb.zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/128x128/apps/zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/128x128/apps/io.github.mvkweb.zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/256x256/apps/zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/256x256/apps/io.github.mvkweb.zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/512x512/apps/zinc.png" }),
        b.pathJoin(&.{ prefix, "share/icons/hicolor/512x512/apps/io.github.mvkweb.zinc.png" }),
    };

    for (files_to_remove) |file_path| {
        std.Io.Dir.cwd().deleteFile(b.graph.io, file_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn addPkgConfigIncludes(b: *std.Build, translate_c: *std.Build.Step.TranslateC, lib_name: []const u8) void {
    const stdout = b.run(&.{ "pkg-config", "--cflags-only-I", lib_name });

    var it = std.mem.tokenizeAny(u8, stdout, " \t\r\n");
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) {
            const path = flag[2..];
            if (path.len > 0) {
                translate_c.addSystemIncludePath(.{ .cwd_relative = path });
            }
        }
    }
}
