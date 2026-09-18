const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // --- steam-bridge: needs the Steamworks SDK vendored locally. ---
    // Download steamworks_sdk.zip from https://partner.steamgames.com/downloads/list
    // (requires a free Steam account) and extract it so that
    // vendor/sdk/public/steam/... and vendor/sdk/redistributable_bin/... exist.
    const sdk_root = "vendor/sdk";
    const sdk_lib_dir = sdk_root ++ "/redistributable_bin/linux64";
    const io = b.graph.io;
    const have_sdk = blk: {
        var dir = std.Io.Dir.cwd().openDir(io, sdk_lib_dir, .{}) catch break :blk false;
        dir.close(io);
        break :blk true;
    };

    if (have_sdk) {
        // NOTE: this target is *not* linked with `b.addExecutable` +
        // `b.installArtifact`. Zig 0.16.0's self-hosted ELF linker can't
        // yet handle the `.sframe` unwind sections that current glibc/gcc
        // (verified: gcc 16 on this machine) emit into crt1.o — any
        // libc-linked Zig binary fails with
        // "fatal linker error: unhandled relocation type R_X86_64_PC64
        // ... .sframe", independent of anything in this project (reproduced
        // with a one-line hello-world). The system linker handles it fine,
        // so we build a `.o` with zig and link the final binary with `cc`.
        // Revisit once Zig's linker supports SFrame relocations.
        const bridge_obj = b.addObject(.{
            .name = "steam-bridge",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bridge_main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

        const sdk_lib_dir_abs = b.pathFromRoot(sdk_lib_dir);
        const rpath_arg = std.fmt.allocPrint(b.allocator, "-Wl,-rpath,{s}", .{sdk_lib_dir_abs}) catch @panic("oom");

        const link_cmd = b.addSystemCommand(&.{"cc"});
        link_cmd.addFileArg(bridge_obj.getEmittedBin());
        link_cmd.addArg("-o");
        const out_bin = link_cmd.addOutputFileArg("steam-bridge");
        link_cmd.addArgs(&.{ "-L", sdk_lib_dir_abs, "-lsteam_api", "-lm", rpath_arg });

        const install_bridge = b.addInstallBinFile(out_bin, "steam-bridge");
        b.getInstallStep().dependOn(&install_bridge.step);

        const run_bridge = b.step("run-bridge", "Run steam-bridge");
        const run_bridge_exec = std.Build.Step.Run.create(b, "run steam-bridge");
        run_bridge_exec.addFileArg(out_bin);
        run_bridge_exec.step.dependOn(&install_bridge.step);
        if (b.args) |args| run_bridge_exec.addArgs(args);
        run_bridge.dependOn(&run_bridge_exec.step);
    } else {
        const warn = b.addSystemCommand(&.{
            "echo",
            "steam-bridge skipped: " ++ sdk_lib_dir ++ " not found (vendor the Steamworks SDK to build it)",
        });
        b.getInstallStep().dependOn(&warn.step);
    }

    // --- tsw-gui: live dashboard (Dear ImGui via zgui/zglfw + OpenGL3). ---
    // Same libc-link situation as steam-bridge (see note above), plus this
    // one has C++ object code (imgui itself), so the final link is done
    // with `c++` rather than `cc` to get libstdc++ pulled in correctly.
    {
        // ReleaseFast (independent of our own module's optimize level) so
        // Zig doesn't instrument these vendored C/C++ sources with UBSan
        // checks — their runtime handlers (__ubsan_handle_*) only get
        // auto-linked by Zig's own linker, which we bypass below for the
        // same .sframe reason as steam-bridge.
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

        const gui_obj = b.addObject(.{
            .name = "tsw-gui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gui_main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "zgui", .module = zgui_dep.module("root") },
                    .{ .name = "zglfw", .module = zglfw_dep.module("root") },
                    .{ .name = "zopengl", .module = zopengl_dep.module("root") },
                },
            }),
        });

        const zgui_lib = zgui_dep.artifact("imgui");
        const zglfw_lib = zglfw_dep.artifact("glfw");

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
    }

    // --- tests ---
    const test_step = b.step("test", "Run tests");
    const cli_tests = b.addTest(.{ .root_module = cli_exe.root_module });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
}
