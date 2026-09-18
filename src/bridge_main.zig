//! steam-bridge — reads real Steam Input actions (not keyboard emulation)
//! and drives Train Sim World's external API directly.
//!
//! Flow: SteamInput.init() activates the single "Driving" action set from
//! manifest/game_actions_480.vdf, which covers core cab controls plus
//! British (AWS/DSD/TPWS/DRA), German (SIFA/PZB/LZB) and ETCS DMI actions
//! — see the `controls` table below for the full list. Which of these a
//! given loco actually has is entirely down to its profile under
//! profiles/; unmapped logical controls are just never polled against
//! that profile. Each tick we poll every logical action (analog triggers
//! for throttle/brake/combined_power_brake, digital buttons for
//! everything else), translate through the active profile to a real TSW
//! node path, and PATCH the value through tsw.Client. Binding physical
//! controller buttons/axes to these actions is done entirely in Steam's
//! own controller configurator, not in this code.
//!
//! NOTE: the Steam Input half (src/steam/*) has been verified to link and
//! run its init/shutdown path against the real SDK, but has not yet been
//! exercised against a live Steam client + physical controller + TSW
//! session. Expect to iterate on it with a controller in hand.

const std = @import("std");
const tsw = @import("tsw/client.zig");
const profile_mod = @import("tsw/profile.zig");
const steam = @import("steam/input.zig");

const default_base_url = "http://localhost:31270";
const default_manifest = "manifest/game_actions_480.vdf";
const default_profile_dir = "profiles";
const default_tick_ms: i64 = 33; // ~30Hz
const reload_every_n_ticks: u32 = 60; // re-check active loco roughly every ~2s at 30Hz

const AnalogRange = struct { min: f32, max: f32 };
const ControlKind = union(enum) {
    digital,
    /// `min`/`max` bound what we clamp the raw Steam Input axis value to
    /// before sending it on. Unit (0..1) for a physical trigger/lever;
    /// bipolar (-1..1) for a single combined power/brake handle where
    /// negative means brake and positive means power.
    analog: AnalogRange,
};
const unit_range: AnalogRange = .{ .min = 0.0, .max = 1.0 };
const bipolar_range: AnalogRange = .{ .min = -1.0, .max = 1.0 };

const LogicalControl = struct {
    name: [:0]const u8,
    kind: ControlKind,
};

/// A lever-style control (throttle, brake, combined_power_brake) can be
/// driven two ways: a plain analog axis (`absolute_action`), or a pair of
/// digital up/down detent actions that the bridge accumulates into an
/// absolute position itself — see `Profile.LeverMode`. Real locos have
/// both notched and notchless levers and TSW's API doesn't reliably say
/// which, so the active loco's profile picks the mode per lever.
const Lever = struct {
    /// Also the profile lookup key.
    name: [:0]const u8,
    range: AnalogRange,
    absolute_action: [:0]const u8,
    up_action: [:0]const u8,
    down_action: [:0]const u8,
};

// Must match the action names in manifest/game_actions_480.vdf.
const levers = [_]Lever{
    .{ .name = "combined_power_brake", .range = bipolar_range, .absolute_action = "combined_power_brake", .up_action = "combined_power_brake_up", .down_action = "combined_power_brake_down" },
    .{ .name = "throttle", .range = unit_range, .absolute_action = "throttle", .up_action = "throttle_up", .down_action = "throttle_down" },
    .{ .name = "brake", .range = unit_range, .absolute_action = "brake", .up_action = "brake_up", .down_action = "brake_down" },
};

const default_step_size: f32 = 0.02;
const default_notches: u32 = 8;

// Must match the action names in manifest/game_actions_480.vdf. Not every
// locomotive maps every one of these — see profiles/README.md.
const controls = [_]LogicalControl{
    // Core cab controls.
    .{ .name = "horn", .kind = .digital },
    .{ .name = "sander", .kind = .digital },
    .{ .name = "pantograph_up", .kind = .digital },
    .{ .name = "pantograph_down", .kind = .digital },
    .{ .name = "wipers_toggle", .kind = .digital },
    .{ .name = "headlights_toggle", .kind = .digital },
    .{ .name = "cab_light_toggle", .kind = .digital },
    .{ .name = "doors_left_toggle", .kind = .digital },
    .{ .name = "doors_right_toggle", .kind = .digital },
    .{ .name = "coupler_toggle", .kind = .digital },

    // British safety systems.
    .{ .name = "aws_reset", .kind = .digital },
    .{ .name = "dsd_reset", .kind = .digital },
    .{ .name = "tpws_override", .kind = .digital },
    .{ .name = "tpws_isolate", .kind = .digital },
    .{ .name = "dra_toggle", .kind = .digital },

    // German safety systems (PZB/SIFA/LZB).
    .{ .name = "sifa_reset", .kind = .digital },
    .{ .name = "pzb_acknowledge", .kind = .digital },
    .{ .name = "pzb_release", .kind = .digital },
    .{ .name = "pzb_restriction_override", .kind = .digital },
    .{ .name = "lzb_override", .kind = .digital },
    .{ .name = "lzb_isolation", .kind = .digital },

    // ETCS DMI soft-buttons.
    .{ .name = "etcs_start", .kind = .digital },
    .{ .name = "etcs_acknowledge", .kind = .digital },
    .{ .name = "etcs_override", .kind = .digital },
    .{ .name = "etcs_non_leading", .kind = .digital },
};

const analog_epsilon: f32 = 0.01;

fn ensureSteamAppId(io: std.Io) !void {
    const check = std.Io.Dir.cwd().readFileAlloc(io, "steam_appid.txt", std.heap.page_allocator, .limited(64));
    if (check) |data| {
        std.heap.page_allocator.free(data);
        return;
    } else |_| {}
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "steam_appid.txt", .data = "480" });
    std.debug.print("wrote steam_appid.txt (480 = Spacewar, Valve's public test app; see README)\n", .{});
}

fn absolutePath(arena: std.mem.Allocator, io: std.Io, rel: []const u8) ![:0]const u8 {
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    const resolved = try std.fs.path.resolve(arena, &.{ cwd_path, rel });
    return try arena.dupeZ(u8, resolved);
}

fn readKeyFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096));
    return std.mem.trim(u8, raw, " \t\r\n");
}

fn jsonObject(v: std.json.Value) ?std.json.ObjectMap {
    if (v != .object) return null;
    return v.object;
}
fn jsonString(v: std.json.Value) ?[]const u8 {
    if (v != .string) return null;
    return v.string;
}

fn currentObjectClass(arena: std.mem.Allocator, client: *tsw.Client) ?[]const u8 {
    const resp = client.get("CurrentDrivableActor.ObjectClass") catch return null;
    defer resp.deinit(client.allocator);
    if (resp.status != .ok) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, arena, resp.body, .{}) catch return null;
    defer parsed.deinit();
    const obj = jsonObject(parsed.value) orelse return null;
    const s = jsonString(obj.get("ObjectClass") orelse return null) orelse return null;
    return arena.dupe(u8, s) catch null;
}

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

    const key_path = key_file orelse {
        std.debug.print("error: no API key file given (pass --key-file or set TSW_KEY_FILE)\n", .{});
        return error.MissingKeyFile;
    };
    const api_key = try readKeyFile(arena, io, key_path);

    var client = tsw.Client.init(gpa, io, base_url, api_key);
    defer client.deinit();

    try ensureSteamAppId(io);
    const manifest_abs = try absolutePath(arena, io, manifest_rel);

    var input = steam.SteamInput.init(manifest_abs) catch |err| {
        std.debug.print("error: Steam Input init failed: {t}\n", .{err});
        std.debug.print("  (needs a running Steam client; NoSteamClient/VersionMismatch means Steam isn't up or is out of date)\n", .{});
        return err;
    };
    defer input.deinit();

    if (!input.hasController()) {
        std.debug.print("warning: no controller connected at startup; will keep polling\n", .{});
    }

    const driving_set = input.getActionSetHandle("Driving");
    input.activateActionSet(driving_set);

    var digital_handles: [controls.len]u64 = undefined;
    var analog_handles: [controls.len]u64 = undefined;
    inline for (controls, 0..) |ctrl, idx| {
        switch (ctrl.kind) {
            .digital => digital_handles[idx] = input.getDigitalActionHandle(ctrl.name),
            .analog => analog_handles[idx] = input.getAnalogActionHandle(ctrl.name),
        }
    }

    var last_digital: [controls.len]bool = @splat(false);
    var last_analog: [controls.len]?f32 = @splat(null);

    var lever_absolute_handles: [levers.len]u64 = undefined;
    var lever_up_handles: [levers.len]u64 = undefined;
    var lever_down_handles: [levers.len]u64 = undefined;
    inline for (levers, 0..) |lever, idx| {
        lever_absolute_handles[idx] = input.getAnalogActionHandle(lever.absolute_action);
        lever_up_handles[idx] = input.getDigitalActionHandle(lever.up_action);
        lever_down_handles[idx] = input.getDigitalActionHandle(lever.down_action);
    }
    // Accumulated position per lever (used by notched/notchless mode) and
    // whether we've sent anything yet for it, separately from whether the
    // absolute-mode epsilon check below has a baseline.
    var lever_position: [levers.len]f32 = @splat(0.0);
    var lever_sent: [levers.len]bool = @splat(false);
    var last_lever_up: [levers.len]bool = @splat(false);
    var last_lever_down: [levers.len]bool = @splat(false);
    var last_lever_absolute: [levers.len]?f32 = @splat(null);

    var current_profile: ?profile_mod.Profile = null;
    defer if (current_profile) |*p| p.deinit();
    var last_object_class: ?[]const u8 = null;
    var tick: u32 = 0;

    std.debug.print("steam-bridge running (tick={d}ms). Ctrl+C to stop.\n", .{tick_ms});

    while (true) : (tick += 1) {
        if (!input.hasController()) input.refreshController();
        input.runFrame();

        if (tick % reload_every_n_ticks == 0) {
            var check_arena = std.heap.ArenaAllocator.init(gpa);
            defer check_arena.deinit();
            if (currentObjectClass(check_arena.allocator(), &client)) |obj_class| {
                const changed = if (last_object_class) |prev| !std.mem.eql(u8, prev, obj_class) else true;
                if (changed) {
                    if (current_profile) |*p| p.deinit();
                    current_profile = null;
                    last_object_class = null;

                    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ profile_dir, obj_class });
                    current_profile = profile_mod.Profile.load(gpa, io, path) catch |err| blk: {
                        std.debug.print("no usable profile for '{s}' ({t}) — run `tsw-cli discover` while this loco is active\n", .{ obj_class, err });
                        break :blk null;
                    };
                    last_object_class = try gpa.dupe(u8, obj_class);
                    if (current_profile != null) std.debug.print("loaded profile for {s}\n", .{obj_class});
                }
            }
        }

        if (current_profile) |prof| {
            inline for (controls, 0..) |ctrl, idx| {
                if (prof.controlPath(ctrl.name)) |control_path| {
                    switch (ctrl.kind) {
                        .digital => {
                            const d = input.pollDigital(digital_handles[idx]);
                            if (d.active and d.pressed != last_digital[idx]) {
                                last_digital[idx] = d.pressed;
                                if (client.setBool(control_path, d.pressed)) |resp| {
                                    resp.deinit(client.allocator);
                                } else |err| {
                                    std.debug.print("set {s} failed: {t}\n", .{ control_path, err });
                                }
                            }
                        },
                        .analog => |range| {
                            const a = input.pollAnalog(analog_handles[idx]);
                            const value = std.math.clamp(a.x, range.min, range.max);
                            const changed = if (last_analog[idx]) |prev| @abs(value - prev) > analog_epsilon else true;
                            if (a.active and changed) {
                                last_analog[idx] = value;
                                if (client.setFloat(control_path, value)) |resp| {
                                    resp.deinit(client.allocator);
                                } else |err| {
                                    std.debug.print("set {s} failed: {t}\n", .{ control_path, err });
                                }
                            }
                        },
                    }
                }
            }

            inline for (levers, 0..) |lever, idx| {
                if (prof.controlPath(lever.name)) |control_path| {
                    const mode = prof.controlMode(lever.name);
                    switch (mode) {
                        .absolute => {
                            const a = input.pollAnalog(lever_absolute_handles[idx]);
                            const value = std.math.clamp(a.x, lever.range.min, lever.range.max);
                            const changed = if (last_lever_absolute[idx]) |prev| @abs(value - prev) > analog_epsilon else true;
                            if (a.active and changed) {
                                last_lever_absolute[idx] = value;
                                if (client.setFloat(control_path, value)) |resp| {
                                    resp.deinit(client.allocator);
                                } else |err| {
                                    std.debug.print("set {s} failed: {t}\n", .{ control_path, err });
                                }
                            }
                        },
                        .notched, .notchless => {
                            const step: f32 = switch (mode) {
                                .notched => (lever.range.max - lever.range.min) / @as(f32, @floatFromInt(prof.controlNotches(lever.name) orelse default_notches)),
                                .notchless => prof.controlStepSize(lever.name) orelse step_size,
                                .absolute => unreachable,
                            };

                            const up = input.pollDigital(lever_up_handles[idx]);
                            const down = input.pollDigital(lever_down_handles[idx]);
                            const up_edge = up.active and up.pressed and !last_lever_up[idx];
                            const down_edge = down.active and down.pressed and !last_lever_down[idx];
                            last_lever_up[idx] = up.pressed;
                            last_lever_down[idx] = down.pressed;

                            var delta: f32 = 0;
                            if (up_edge) delta += step;
                            if (down_edge) delta -= step;

                            if (delta != 0 or !lever_sent[idx]) {
                                var new_pos = std.math.clamp(lever_position[idx] + delta, lever.range.min, lever.range.max);
                                if (mode == .notched) {
                                    // Re-snap to the notch grid each time so
                                    // float error can't drift positions off
                                    // their real detents over a long session.
                                    const steps_from_min = @round((new_pos - lever.range.min) / step);
                                    new_pos = std.math.clamp(lever.range.min + steps_from_min * step, lever.range.min, lever.range.max);
                                }
                                lever_position[idx] = new_pos;
                                lever_sent[idx] = true;
                                if (client.setFloat(control_path, new_pos)) |resp| {
                                    resp.deinit(client.allocator);
                                } else |err| {
                                    std.debug.print("set {s} failed: {t}\n", .{ control_path, err });
                                }
                            }
                        },
                    }
                }
            }
        }

        try std.Io.sleep(io, .fromMilliseconds(tick_ms), .awake);
    }
}
