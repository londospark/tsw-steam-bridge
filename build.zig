const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os_tag = target.result.os.tag;

    // --- tsw-cli: pure Zig, no external deps, always built. ---
    const cli_exe = b.addExecutable(.{
        .name = "tsw-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(cli_exe);

    const run_cli = b.step("run-cli", "Run tsw-cli");
    const run_cli_cmd = b.addRunArtifact(cli_exe);
    run_cli_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli_cmd.addArgs(args);
    run_cli.dependOn(&run_cli_cmd.step);

    // --- Steamworks SDK: needs vendoring locally (see README) regardless
    // of target platform. `vendor/sdk/` is a straight extract of Valve's
    // steamworks_sdk.zip, so it already contains every platform's
    // redistributable side by side; only the subdirectory we look in
    // changes per target.
    const steam = steamPlatform(os_tag);
    const io = b.graph.io;
    const have_sdk = if (steam) |s| blk: {
        var dir = std.Io.Dir.cwd().openDir(io, s.lib_dir, .{}) catch break :blk false;
        dir.close(io);
        break :blk true;
    } else false;

    if (steam == null) {
        const warn = b.addSystemCommand(&.{
            "echo",
            b.fmt("steam-bridge skipped: no known Steamworks redistributable layout for target OS '{t}'", .{os_tag}),
        });
        b.getInstallStep().dependOn(&warn.step);
    } else if (!have_sdk) {
        const warn = b.addSystemCommand(&.{
            "echo",
            b.fmt("steam-bridge skipped: {s} not found (vendor the Steamworks SDK — see README)", .{steam.?.lib_dir}),
        });
        b.getInstallStep().dependOn(&warn.step);
    }

    if (steam) |s| if (have_sdk) {
        if (!needsExternalLinker(os_tag)) installRedistributable(b, s);
        buildSteamBridge(b, target, optimize, os_tag, s);
    };

    // --- tsw-gui: doesn't touch Steamworks at all (see src/gui_main.zig),
    // so it's built unconditionally like tsw-cli, independent of the SDK
    // check above. ---
    buildGui(b, target, optimize, os_tag);

    // --- tests ---
    const test_step = b.step("test", "Run tests");
    const cli_tests = b.addTest(.{ .root_module = cli_exe.root_module });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
}

const SteamPlatform = struct {
    /// Subdirectory under vendor/sdk/redistributable_bin/.
    lib_dir: []const u8,
    /// Name passed to the linker without lib prefix/extension (i.e. what
    /// `-l<name>` / `linkSystemLibrary` expects).
    lib_name: []const u8,
    /// Redistributable filename actually shipped in that subdirectory.
    lib_file: []const u8,
};

fn steamPlatform(os_tag: std.Target.Os.Tag) ?SteamPlatform {
    return switch (os_tag) {
        .linux => .{ .lib_dir = "vendor/sdk/redistributable_bin/linux64", .lib_name = "steam_api", .lib_file = "libsteam_api.so" },
        .windows => .{ .lib_dir = "vendor/sdk/redistributable_bin/win64", .lib_name = "steam_api64", .lib_file = "steam_api64.dll" },
        .macos => .{ .lib_dir = "vendor/sdk/redistributable_bin/osx", .lib_name = "steam_api", .lib_file = "libsteam_api.dylib" },
        else => null,
    };
}

/// On Linux, Zig 0.16.0's self-hosted ELF linker can't yet handle the
/// `.sframe` unwind sections that current glibc/gcc emit into crt1.o —
/// any libc-linked Zig binary fails with "fatal linker error: unhandled
/// relocation type R_X86_64_PC64 ... .sframe", independent of anything in
/// this project (reproduced with a one-line hello-world on the machine
/// this was developed on). The system linker handles it fine, so on
/// Linux we build a `.o`/`.a` with zig and link the final binary with
/// `cc`/`c++`. Windows and macOS don't have this problem (it's specific
/// to this glibc/gcc combination), so they use Zig's own linker normally
/// via `addExecutable`. NOTE: the Windows and macOS paths are written to
/// the best of our knowledge of Zig's cross-compilation and each
/// platform's DLL/dylib conventions, but have only been verified by
/// cross-compiling (`zig build -Dtarget=...`), not by actually running
/// the result on real Windows/macOS hardware.
fn needsExternalLinker(os_tag: std.Target.Os.Tag) bool {
    return os_tag == .linux;
}

fn buildSteamBridge(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    os_tag: std.Target.Os.Tag,
    steam: SteamPlatform,
) void {
    const lib_dir_abs = b.pathFromRoot(steam.lib_dir);

    if (needsExternalLinker(os_tag)) {
        const bridge_obj = b.addObject(.{
            .name = "steam-bridge",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bridge_main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

        const rpath_arg = b.fmt("-Wl,-rpath,{s}", .{lib_dir_abs});
        const link_cmd = b.addSystemCommand(&.{"cc"});
        link_cmd.addFileArg(bridge_obj.getEmittedBin());
        link_cmd.addArg("-o");
        const out_bin = link_cmd.addOutputFileArg("steam-bridge");
        link_cmd.addArgs(&.{ "-L", lib_dir_abs, b.fmt("-l{s}", .{steam.lib_name}), "-lm", rpath_arg });

        const install_bridge = b.addInstallBinFile(out_bin, "steam-bridge");
        b.getInstallStep().dependOn(&install_bridge.step);

        const run_bridge = b.step("run-bridge", "Run steam-bridge");
        const run_bridge_exec = std.Build.Step.Run.create(b, "run steam-bridge");
        run_bridge_exec.addFileArg(out_bin);
        run_bridge_exec.step.dependOn(&install_bridge.step);
        if (b.args) |args| run_bridge_exec.addArgs(args);
        run_bridge.dependOn(&run_bridge_exec.step);
    } else {
        const bridge_exe = b.addExecutable(.{
            .name = "steam-bridge",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bridge_main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        bridge_exe.root_module.addLibraryPath(.{ .cwd_relative = lib_dir_abs });
        bridge_exe.root_module.linkSystemLibrary(steam.lib_name, .{});
        if (os_tag == .macos) bridge_exe.root_module.addRPath(.{ .cwd_relative = lib_dir_abs });
        b.installArtifact(bridge_exe);

        const run_bridge = b.step("run-bridge", "Run steam-bridge");
        const run_bridge_cmd = b.addRunArtifact(bridge_exe);
        run_bridge_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_bridge_cmd.addArgs(args);
        run_bridge.dependOn(&run_bridge_cmd.step);
    }
}

/// Windows/macOS don't have Linux's rpath-to-an-absolute-path convention
/// in the way we use it there, so copy the shared library next to the
/// built binary instead: Windows searches the executable's own directory
/// for DLLs by default, and it keeps the macOS case simple alongside the
/// rpath we also set there.
fn installRedistributable(b: *std.Build, steam: SteamPlatform) void {
    const lib_dir_abs = b.pathFromRoot(steam.lib_dir);
    const src_path = b.fmt("{s}/{s}", .{ lib_dir_abs, steam.lib_file });
    const install = b.addInstallBinFile(.{ .cwd_relative = src_path }, steam.lib_file);
    b.getInstallStep().dependOn(&install.step);
}

/// tsw-gui: live dashboard (Dear ImGui via zgui/zglfw + OpenGL3). Same
/// libc-link situation as steam-bridge on Linux (see needsExternalLinker),
/// plus this one has C++ object code (imgui itself), so the Linux path
/// links with `c++` rather than `cc` to get libstdc++ pulled in
/// correctly. zglfw/zgui already handle their own X11/Wayland
/// (Linux), Win32/GDI (Windows) and Cocoa/AppKit (macOS) system
/// dependencies internally — nothing platform-specific needed here beyond
/// the Steamworks-style linking split.
fn buildGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    os_tag: std.Target.Os.Tag,
) void {
    // ReleaseFast (independent of our own module's optimize level) so Zig
    // doesn't instrument these vendored C/C++ sources with UBSan checks —
    // their runtime handlers (__ubsan_handle_*) only get auto-linked by
    // Zig's own linker, which the Linux path below bypasses for the same
    // .sframe reason as steam-bridge.
    const zgui_dep = b.dependency("zgui", .{
        .target = target,
        .optimize = .ReleaseFast,
        .backend = .glfw_opengl3,
    });
    const zglfw_dep = b.dependency("zglfw", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const zopengl_dep = b.dependency("zopengl", .{
        .target = target,
    });

    const gui_imports = &[_]std.Build.Module.Import{
        .{ .name = "zgui", .module = zgui_dep.module("root") },
        .{ .name = "zglfw", .module = zglfw_dep.module("root") },
        .{ .name = "zopengl", .module = zopengl_dep.module("root") },
    };

    const zgui_lib = zgui_dep.artifact("imgui");
    const zglfw_lib = zglfw_dep.artifact("glfw");

    if (needsExternalLinker(os_tag)) {
        const gui_obj = b.addObject(.{
            .name = "tsw-gui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gui_main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = gui_imports,
            }),
        });

        const gui_link_cmd = b.addSystemCommand(&.{"c++"});
        gui_link_cmd.addFileArg(gui_obj.getEmittedBin());
        gui_link_cmd.addFileArg(zgui_lib.getEmittedBin());
        gui_link_cmd.addFileArg(zglfw_lib.getEmittedBin());
        gui_link_cmd.addArg("-o");
        const gui_out_bin = gui_link_cmd.addOutputFileArg("tsw-gui");
        gui_link_cmd.addArgs(&.{ "-lGL", "-lX11", "-lm" });

        const install_gui = b.addInstallBinFile(gui_out_bin, "tsw-gui");
        b.getInstallStep().dependOn(&install_gui.step);

        const run_gui = b.step("run-gui", "Run tsw-gui");
        const run_gui_exec = std.Build.Step.Run.create(b, "run tsw-gui");
        run_gui_exec.addFileArg(gui_out_bin);
        run_gui_exec.step.dependOn(&install_gui.step);
        if (b.args) |args| run_gui_exec.addArgs(args);
        run_gui.dependOn(&run_gui_exec.step);
    } else {
        const gui_exe = b.addExecutable(.{
            .name = "tsw-gui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gui_main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = gui_imports,
            }),
        });
        gui_exe.root_module.linkLibrary(zgui_lib);
        gui_exe.root_module.linkLibrary(zglfw_lib);
        switch (os_tag) {
            .windows => {
                gui_exe.root_module.linkSystemLibrary("opengl32", .{});
                gui_exe.root_module.linkSystemLibrary("gdi32", .{});
                // Otherwise a console window flashes up behind the GUI.
                gui_exe.subsystem = .windows;
            },
            .macos => {
                gui_exe.root_module.linkFramework("OpenGL", .{});
            },
            else => {},
        }
        b.installArtifact(gui_exe);

        const run_gui = b.step("run-gui", "Run tsw-gui");
        const run_gui_cmd = b.addRunArtifact(gui_exe);
        run_gui_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_gui_cmd.addArgs(args);
        run_gui.dependOn(&run_gui_cmd.step);
    }
}
