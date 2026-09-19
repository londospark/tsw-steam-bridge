//! steam-bridge — headless entry point. See src/bridge.zig for the actual
//! polling/translation logic (shared with tsw-gui) and src/controls.zig
//! for the full control vocabulary.

const std = @import("std");
const tsw = @import("tsw/client.zig");
const bridge_mod = @import("bridge.zig");

const default_base_url = "http://localhost:31270";
const default_manifest = "manifest/game_actions_480.vdf";
const default_profile_dir = "profiles";
const default_tick_ms: i64 = 33; // ~30Hz
const default_step_size: f32 = @import("controls.zig").default_step_size;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var key_file: ?[]const u8 = init.environ_map.get("TSW_KEY_FILE");
    var base_url: []const u8 = init.environ_map.get("TSW_BASE_URL") orelse default_base_url;
    var manifest_rel: []const u8 = default_manifest;
    var profile_dir: []const u8 = default_profile_dir;
    var tick_ms: i64 = default_tick_ms;
    var step_size: f32 = default_step_size;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--key-file")) {
            i += 1;
            key_file = args[i];
        } else if (std.mem.eql(u8, a, "--base-url")) {
            i += 1;
            base_url = args[i];
        } else if (std.mem.eql(u8, a, "--manifest")) {
            i += 1;
            manifest_rel = args[i];
        } else if (std.mem.eql(u8, a, "--profile-dir")) {
            i += 1;
            profile_dir = args[i];
        } else if (std.mem.eql(u8, a, "--tick-ms")) {
            i += 1;
            tick_ms = try std.fmt.parseInt(i64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--step-size")) {
            i += 1;
            step_size = try std.fmt.parseFloat(f32, args[i]);
        }
    }

    if (key_file == null) {
        key_file = bridge_mod.findKeyFile(arena, io, init.environ_map.get("HOME"), init.environ_map.get("USERPROFILE"));
        if (key_file) |found| std.debug.print("found TSW key file: {s}\n", .{found});
    }
    const key_path = key_file orelse {
        std.debug.print("error: no API key file given or found automatically (pass --key-file or set TSW_KEY_FILE)\n", .{});
        return error.MissingKeyFile;
    };
    const api_key = try bridge_mod.readKeyFile(arena, io, key_path);
    const client = tsw.Client.init(gpa, io, base_url, api_key);

    try bridge_mod.ensureSteamAppId(io);
    const manifest_abs = try bridge_mod.absolutePath(arena, io, manifest_rel);

    var bridge = bridge_mod.Bridge.init(gpa, io, client, manifest_abs, profile_dir, step_size) catch |err| {
        std.debug.print("error: Steam Input init failed: {t}\n", .{err});
        std.debug.print("  (needs a running Steam client; NoSteamClient/VersionMismatch means Steam isn't up or is out of date)\n", .{});
        return err;
    };
    defer bridge.deinit();

    if (!bridge.hasController()) {
        std.debug.print("warning: no controller connected at startup; will keep polling\n", .{});
    }

    std.debug.print("steam-bridge running (tick={d}ms). Ctrl+C to stop.\n", .{tick_ms});

    while (true) {
        bridge.tick();
        try std.Io.sleep(io, .fromMilliseconds(tick_ms), .awake);
    }
}
