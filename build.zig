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
        link_cmd.addArgs(&.{ "-L", sdk_lib_dir_abs, "-lsteam_api", rpath_arg });

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

    // --- tests ---
    const test_step = b.step("test", "Run tests");
    const cli_tests = b.addTest(.{ .root_module = cli_exe.root_module });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
}
