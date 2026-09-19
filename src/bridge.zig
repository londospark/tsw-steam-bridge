//! The actual bridge: reads real Steam Input actions (not keyboard
//! emulation) and drives Train Sim World's external API directly. Shared
//! core used by both `steam-bridge` (headless) and `tsw-gui` (same logic,
//! driven once per rendered frame instead of a sleep loop), so the GUI's
//! live view and the headless service can never drift apart.
//!
//! Flow: activates the single "Driving" Steam Input action set from
//! manifest/game_actions_480.vdf (see src/controls.zig for the full
//! vocabulary — British/German/ETCS safety systems, core cab controls,
//! and the three power/brake levers). Which of these a given loco
//! actually has is entirely down to its profile under profiles/;
//! unmapped logical controls are tracked (for display) but never sent.
//! Binding physical controller buttons/axes to these actions is done
//! entirely in Steam's own controller configurator, not in this code.

const std = @import("std");
const builtin = @import("builtin");
const tsw = @import("tsw/client.zig");
const profile_mod = @import("tsw/profile.zig");
const steam = @import("steam/input.zig");
const ctl = @import("controls.zig");

pub const DigitalSnapshot = struct {
    mapped: bool = false,
    active: bool = false,
    pressed: bool = false,
};

pub const LeverSnapshot = struct {
    mapped: bool = false,
    active: bool = false,
    value: f32 = 0,
    mode: profile_mod.Profile.LeverMode = .absolute,
};

const analog_epsilon: f32 = 0.01;
const reload_every_n_ticks: u32 = 60; // re-check active loco roughly every ~2s at 30Hz, or ~1s at 60fps

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: tsw.Client,
    input: steam.SteamInput,
    profile_dir: []const u8,
    step_size: f32,

    digital_handles: [ctl.controls.len]u64 = undefined,
    last_digital: [ctl.controls.len]bool = @splat(false),
    digital_snapshot: [ctl.controls.len]DigitalSnapshot = @splat(.{}),

    lever_absolute_handles: [ctl.levers.len]u64 = undefined,
    lever_up_handles: [ctl.levers.len]u64 = undefined,
    lever_down_handles: [ctl.levers.len]u64 = undefined,
    lever_position: [ctl.levers.len]f32 = @splat(0.0),
    lever_sent: [ctl.levers.len]bool = @splat(false),
    last_lever_up: [ctl.levers.len]bool = @splat(false),
    last_lever_down: [ctl.levers.len]bool = @splat(false),
    last_lever_absolute: [ctl.levers.len]?f32 = @splat(null),
    lever_snapshot: [ctl.levers.len]LeverSnapshot = @splat(.{}),

    current_profile: ?profile_mod.Profile = null,
    object_class: ?[]const u8 = null,
    tick_count: u32 = 0,

    /// Takes ownership of `client` (calls `.deinit()` on it). `manifest_abs`
    /// must be an absolute path (Steam resolves relative paths against
    /// nothing in particular).
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        client: tsw.Client,
        manifest_abs: [:0]const u8,
        profile_dir: []const u8,
        step_size: f32,
    ) !Bridge {
        var input = try steam.SteamInput.init(manifest_abs);
        errdefer input.deinit();
        const driving_set = input.getActionSetHandle("Driving");
        input.activateActionSet(driving_set);

        var self: Bridge = .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .input = input,
            .profile_dir = profile_dir,
            .step_size = step_size,
        };

        inline for (ctl.controls, 0..) |c, idx| {
            self.digital_handles[idx] = self.input.getDigitalActionHandle(c.name);
        }
        inline for (ctl.levers, 0..) |lever, idx| {
            self.lever_absolute_handles[idx] = self.input.getAnalogActionHandle(lever.absolute_action);
            self.lever_up_handles[idx] = self.input.getDigitalActionHandle(lever.up_action);
            self.lever_down_handles[idx] = self.input.getDigitalActionHandle(lever.down_action);
        }
        return self;
    }

    pub fn deinit(self: *Bridge) void {
        if (self.current_profile) |*p| p.deinit();
        if (self.object_class) |oc| self.allocator.free(oc);
        self.input.deinit();
        self.client.deinit();
    }

    pub fn hasController(self: Bridge) bool {
        return self.input.hasController();
    }

    pub fn profileLoaded(self: Bridge) bool {
        return self.current_profile != null;
    }

    /// One poll+maybe-send pass. Call every tick (headless) or every
    /// rendered frame (GUI). Always updates `digital_snapshot`/
    /// `lever_snapshot` from live Steam Input state regardless of whether
    /// a profile is loaded, so a caller can render current controller
    /// state even with no locomotive profile mapped yet; only actually
    /// sends anything to TSW when the active profile maps that control.
    pub fn tick(self: *Bridge) void {
        if (!self.input.hasController()) self.input.refreshController();
        self.input.runFrame();
        defer self.tick_count += 1;

        if (self.tick_count % reload_every_n_ticks == 0) self.reloadProfileIfChanged();

        inline for (ctl.controls, 0..) |c, idx| {
            const d = self.input.pollDigital(self.digital_handles[idx]);
            const mapped_path = if (self.current_profile) |prof| prof.controlPath(c.name) else null;
            self.digital_snapshot[idx] = .{ .mapped = mapped_path != null, .active = d.active, .pressed = d.pressed };
            if (mapped_path) |path| {
                if (d.active and d.pressed != self.last_digital[idx]) {
                    self.last_digital[idx] = d.pressed;
                    self.send(path, .{ .boolean = d.pressed });
                }
            }
        }

        inline for (ctl.levers, 0..) |lever, idx| {
            const mapped_path = if (self.current_profile) |prof| prof.controlPath(lever.name) else null;
            const mode: profile_mod.Profile.LeverMode = if (self.current_profile) |prof| prof.controlMode(lever.name) else .absolute;
            // TSW's InputValue range isn't consistent across locos (confirmed
            // live: 0..1 on one loco's combined handle, -1..1 on another's),
            // so a profile can override the compiled-in default per-control.
            const range: ctl.AnalogRange = if (self.current_profile) |prof| prof.controlRange(lever.name) orelse lever.range else lever.range;

            switch (mode) {
                .absolute => {
                    const a = self.input.pollAnalog(self.lever_absolute_handles[idx]);
                    // Bipolar physical axes (a centered joystick, -1..1)
                    // get remapped onto `range` rather than clamped into
                    // it, since range is generally 0..1 here and naively
                    // clamping would just floor every negative half of
                    // the stick's travel to 0.
                    const raw = if (lever.physical_bipolar)
                        range.min + (a.x + 1.0) / 2.0 * (range.max - range.min)
                    else
                        a.x;
                    const value = std.math.clamp(raw, range.min, range.max);
                    self.lever_snapshot[idx] = .{ .mapped = mapped_path != null, .active = a.active, .value = value, .mode = mode };
                    if (mapped_path) |path| {
                        const changed = if (self.last_lever_absolute[idx]) |prev| @abs(value - prev) > analog_epsilon else true;
                        if (a.active and changed) {
                            self.last_lever_absolute[idx] = value;
                            self.send(path, .{ .float = value });
                        }
                    }
                },
                .notched, .notchless => {
                    const up = self.input.pollDigital(self.lever_up_handles[idx]);
                    const down = self.input.pollDigital(self.lever_down_handles[idx]);
                    const up_edge = up.active and up.pressed and !self.last_lever_up[idx];
                    const down_edge = down.active and down.pressed and !self.last_lever_down[idx];
                    self.last_lever_up[idx] = up.pressed;
                    self.last_lever_down[idx] = down.pressed;

                    const step: f32 = if (self.current_profile) |prof| switch (mode) {
                        .notched => (range.max - range.min) / @as(f32, @floatFromInt(prof.controlNotches(lever.name) orelse ctl.default_notches)),
                        .notchless => prof.controlStepSize(lever.name) orelse self.step_size,
                        .absolute => unreachable,
                    } else 0;

                    var delta: f32 = 0;
                    if (up_edge) delta += step;
                    if (down_edge) delta -= step;

                    if (delta != 0 or !self.lever_sent[idx]) {
                        var new_pos = std.math.clamp(self.lever_position[idx] + delta, range.min, range.max);
                        if (mode == .notched and step > 0) {
                            // Re-snap to the notch grid each time so float
                            // error can't drift positions off their real
                            // detents over a long session.
                            const steps_from_min = @round((new_pos - range.min) / step);
                            new_pos = std.math.clamp(range.min + steps_from_min * step, range.min, range.max);
                        }
                        self.lever_position[idx] = new_pos;
                        self.lever_sent[idx] = true;
                        self.lever_snapshot[idx] = .{ .mapped = mapped_path != null, .active = up.active or down.active, .value = new_pos, .mode = mode };
                        if (mapped_path) |path| self.send(path, .{ .float = new_pos });
                    } else {
                        self.lever_snapshot[idx] = .{ .mapped = mapped_path != null, .active = up.active or down.active, .value = self.lever_position[idx], .mode = mode };
                    }
                },
            }
        }
    }

    const Value = union(enum) { boolean: bool, float: f32 };

    fn send(self: *Bridge, path: []const u8, value: Value) void {
        const resp = switch (value) {
            .boolean => |b| self.client.setBool(path, b),
            .float => |f| self.client.setFloat(path, f),
        } catch |err| {
            std.debug.print("set {s} failed: {t}\n", .{ path, err });
            return;
        };
        resp.deinit(self.client.allocator);
    }

    fn reloadProfileIfChanged(self: *Bridge) void {
        var check_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer check_arena.deinit();
        const obj_class = currentObjectClass(check_arena.allocator(), &self.client) orelse return;
        const changed = if (self.object_class) |prev| !std.mem.eql(u8, prev, obj_class) else true;
        if (!changed) return;

        if (self.current_profile) |*p| p.deinit();
        self.current_profile = null;
        if (self.object_class) |oc| self.allocator.free(oc);
        self.object_class = self.allocator.dupe(u8, obj_class) catch return;

        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ self.profile_dir, obj_class }) catch return;
        self.current_profile = profile_mod.Profile.load(self.allocator, self.io, path) catch |err| blk: {
            std.debug.print("no usable profile for '{s}' ({t}) — run `tsw-cli discover` while this loco is active\n", .{ obj_class, err });
            break :blk null;
        };
        if (self.current_profile != null) std.debug.print("loaded profile for {s}\n", .{obj_class});
    }
};

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
    // Confirmed live against TSW7: the response is
    // {"Result":"Success","Values":{"ObjectClass":"..."}}. Also accept a
    // bare {"ObjectClass":"..."} in case an older/other version replies
    // unwrapped, matching the (unverified) TSW5 doc this project started
    // from.
    const values_obj = if (jsonObject(obj.get("Values") orelse .null)) |v| v else obj;
    const s = jsonString(values_obj.get("ObjectClass") orelse return null) orelse return null;
    return arena.dupe(u8, s) catch null;
}

pub fn ensureSteamAppId(io: std.Io) !void {
    const check = std.Io.Dir.cwd().readFileAlloc(io, "steam_appid.txt", std.heap.page_allocator, .limited(64));
    if (check) |data| {
        std.heap.page_allocator.free(data);
        return;
    } else |_| {}
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "steam_appid.txt", .data = "480" });
    std.debug.print("wrote steam_appid.txt (480 = Spacewar, Valve's public test app; see README)\n", .{});
}

pub fn absolutePath(arena: std.mem.Allocator, io: std.Io, rel: []const u8) ![:0]const u8 {
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    const resolved = try std.fs.path.resolve(arena, &.{ cwd_path, rel });
    return try arena.dupeZ(u8, resolved);
}

pub fn readKeyFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096));
    return std.mem.trim(u8, raw, " \t\r\n");
}

/// Extracts every `"path"` value from a Steam `libraryfolders.vdf` file
/// (the format Steam uses to record every library you've added, possibly
/// on a different drive/mount entirely — a game is often not in the
/// default library at all) and appends them to `out`. Silently does
/// nothing if the file doesn't exist or doesn't parse; this is a
/// best-effort convenience; not a real VDF/KeyValues parser, just a line
/// scan for a quoted "path" key followed by a quoted value, which is all
/// this file ever needs.
fn collectLibraryPaths(arena: std.mem.Allocator, io: std.Io, vdf_path: []const u8, out: *std.ArrayList([]const u8)) void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, vdf_path, arena, .limited(1 << 20)) catch return;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "\"path\"")) continue;

        var fields = std.mem.splitScalar(u8, line, '"');
        _ = fields.next(); // before the opening quote (empty)
        const key = fields.next() orelse continue;
        if (!std.mem.eql(u8, key, "path")) continue;
        _ = fields.next(); // whitespace between the two quoted fields
        const value = fields.next() orelse continue;

        out.append(arena, arena.dupe(u8, value) catch continue) catch {};
    }
}

/// Best-effort search for TSW's CommAPIKey.txt, so you don't have to find
/// and pass it by hand. Checks every "TrainSimWorld<N>" folder under every
/// Steam library this looks in (native on Windows, or Proton's compatdata
/// on Linux/Steam Deck), and returns the most recently modified match in
/// case more than one TSW version is installed. Returns null if nothing
/// turned up; the caller should still accept an explicit --key-file as an
/// override/fallback. `home`/`userprofile` are `$HOME`/`%USERPROFILE%`.
pub fn findKeyFile(allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8, userprofile: ?[]const u8) ?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var my_games_dirs: std.ArrayList([]const u8) = .empty;

    if (builtin.os.tag == .windows) {
        if (userprofile) |up| {
            const dir = std.fmt.allocPrint(arena, "{s}/Documents/My Games", .{up}) catch return null;
            my_games_dirs.append(arena, dir) catch return null;
        }
    } else if (home) |h| {
        // Native Steam, the .steam symlink farm, and Flatpak Steam. These
        // are just the *default* library location for each install kind —
        // any of them may declare additional libraries on other
        // drives/mounts in their own libraryfolders.vdf, which is where
        // a game is actually likely to be if you've got more than one
        // Steam library (collected below).
        const default_root_fmts = [_][]const u8{
            "{s}/.local/share/Steam",
            "{s}/.steam/steam",
            "{s}/.steam/root",
            "{s}/.var/app/com.valvesoftware.Steam/.local/share/Steam",
        };
        var steam_roots: std.ArrayList([]const u8) = .empty;
        inline for (default_root_fmts) |fmt_str| {
            const root = std.fmt.allocPrint(arena, fmt_str, .{h}) catch h;
            steam_roots.append(arena, root) catch {};
        }

        // Collect into a separate list rather than appending to
        // `steam_roots` directly while iterating a slice of it — growing
        // `steam_roots` mid-iteration would reallocate its backing array
        // out from under the slice this loop is walking.
        var extra_roots: std.ArrayList([]const u8) = .empty;
        for (steam_roots.items) |root| {
            const vdf_path = std.fmt.allocPrint(arena, "{s}/steamapps/libraryfolders.vdf", .{root}) catch continue;
            collectLibraryPaths(arena, io, vdf_path, &extra_roots);
        }
        steam_roots.appendSlice(arena, extra_roots.items) catch {};

        for (steam_roots.items) |root| {
            const compat_path = std.fmt.allocPrint(arena, "{s}/steamapps/compatdata", .{root}) catch continue;
            var compat_dir = std.Io.Dir.cwd().openDir(io, compat_path, .{ .iterate = true }) catch continue;
            defer compat_dir.close(io);

            var it = compat_dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                // Different Proton/Wine versions have used both spellings
                // for this folder over time, so just try both.
                const docs_names = [_][]const u8{ "Documents", "My Documents" };
                for (docs_names) |docs_name| {
                    const my_games = std.fmt.allocPrint(
                        arena,
                        "{s}/{s}/pfx/drive_c/users/steamuser/{s}/My Games",
                        .{ compat_path, entry.name, docs_name },
                    ) catch continue;
                    my_games_dirs.append(arena, my_games) catch {};
                }
            }
        }
    }

    var best_path: ?[]const u8 = null;
    var best_mtime: i96 = -1;

    for (my_games_dirs.items) |my_games| {
        var dir = std.Io.Dir.cwd().openDir(io, my_games, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, entry.name, "TrainSimWorld")) continue;

            const key_path = std.fmt.allocPrint(arena, "{s}/{s}/Saved/Config/CommAPIKey.txt", .{ my_games, entry.name }) catch continue;

            var file = std.Io.Dir.cwd().openFile(io, key_path, .{}) catch continue;
            const st = file.stat(io) catch {
                file.close(io);
                continue;
            };
            file.close(io);

            if (st.mtime.nanoseconds > best_mtime) {
                best_mtime = st.mtime.nanoseconds;
                best_path = allocator.dupe(u8, key_path) catch continue;
            }
        }
    }

    return best_path;
}
