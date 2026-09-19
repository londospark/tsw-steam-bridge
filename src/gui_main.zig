//! tsw-gui — live dashboard shell for the bridge, built on Dear ImGui
//! (via zgui/zglfw + OpenGL3) with docking enabled.
//!
//! This is a windowing/theming/layout scaffold: the panels below show a
//! representative layout (controller state, active loco/profile, mapped
//! controls) but are not yet wired to a running steam-bridge's live poll
//! loop — see README "Known gaps". Drag panel tabs to rearrange/dock them;
//! layout is not currently persisted between runs.
//!
//! Theming: on Linux, colors are read at startup from Omarchy's *current*
//! theme (`~/.local/state/omarchy/current/theme/colors.toml`) rather than
//! hardcoded, so the panel follows whatever theme is active system-wide.
//! Elsewhere (Windows, macOS, or Linux without Omarchy) there's nothing to
//! read, so it falls back to the colors compiled into `Palette`'s
//! defaults — pass `--theme-file` to point at any colors.toml-shaped file
//! instead.
//!
//! Fonts: bundled (JetBrains Mono, SIL OFL 1.1 — see
//! src/assets/fonts/LICENSE-JetBrainsMono.txt) and embedded into the binary,
//! so it looks right with zero setup on every platform. On Linux, run via
//! `scripts/run-gui.sh` instead if you'd rather it match your current
//! Omarchy font (`omarchy font current` -> `fc-match`); pass `--font-file
//! <path-to-a-ttf-or-otf>` yourself for anything else.

const std = @import("std");
const builtin = @import("builtin");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const tsw = @import("tsw/client.zig");
const bridge_mod = @import("bridge.zig");
const ctl = @import("controls.zig");

const default_font_ttf = @embedFile("assets/fonts/JetBrainsMono-Regular.ttf");

// NOTE: do not declare our own `extern fn glViewport`/`glClear`/etc. here.
// zgui's OpenGL3 backend is built with IMGUI_IMPL_OPENGL_LOADER_CUSTOM,
// which means zopengl.loadCoreProfile() below `@export`s its own global
// `glViewport`/`glClearColor`/`glGetString`/... symbols (function-pointer
// variables it fills in via zglfw.getProcAddress) so the C++ imgui backend
// links against them. A second `extern fn` of the same name in this file
// would collide with zopengl's data symbol at link time — the linker binds
// the call to the address of the pointer *variable* instead of the
// function it points to, which "works" (no link error) and then segfaults
// on the first call, jumping into essentially-arbitrary bytes. Go through
// `zopengl.bindings` instead, which is the loaded pointer itself.
const gl = zopengl.bindings;

const Palette = struct {
    accent: [4]f32 = hex("#3FB4FF"),
    selection: [4]f32 = hex("#1C2E56"),
    muted: [4]f32 = hex("#35507F"),
    background: [4]f32 = hex("#060C1F"),
    dark_background: [4]f32 = hex("#030712"),
    darker_background: [4]f32 = hex("#01030A"),
    lighter_background: [4]f32 = hex("#1C2E56"),
    foreground: [4]f32 = hex("#DCE6FF"),
    dark_foreground: [4]f32 = hex("#7C8CB8"),
    light_foreground: [4]f32 = hex("#EEF3FF"),
    bright_foreground: [4]f32 = hex("#FFFFFF"),
    red: [4]f32 = hex("#FF4C56"),
    yellow: [4]f32 = hex("#FFC94D"),
    green: [4]f32 = hex("#4CE0A0"),
    cyan: [4]f32 = hex("#33E4FF"),

    fn hex(comptime s: []const u8) [4]f32 {
        return parseHexColor(s) orelse @compileError("bad fallback color literal");
    }
};

/// "#RRGGBB" -> normalized RGBA. Returns null on anything malformed rather
/// than erroring — a theme file we can't fully parse should still produce
/// a usable (if partially default) palette.
fn parseHexColor(s: []const u8) ?[4]f32 {
    @setEvalBranchQuota(4000);
    if (s.len != 7 or s[0] != '#') return null;
    const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        1.0,
    };
}

fn setPaletteField(palette: *Palette, key: []const u8, value: [4]f32) void {
    inline for (std.meta.fields(Palette)) |f| {
        if (std.mem.eql(u8, f.name, key)) {
            @field(palette, f.name) = value;
            return;
        }
    }
}

/// Loads `key = "value"` pairs out of Omarchy's colors.toml. It's a flat
/// table with no sections/arrays, so a line-oriented scan is all this
/// needs — not a general TOML parser.
fn loadPalette(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Palette {
    var palette: Palette = .{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16)) catch |err| {
        std.debug.print("note: couldn't read '{s}' ({t}), using fallback colors\n", .{ path, err });
        return palette;
    };
    defer gpa.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        const color = parseHexColor(value) orelse continue;
        setPaletteField(&palette, key, color);
    }
    return palette;
}

fn mix(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    };
}

fn applyTheme(palette: Palette) void {
    const style = zgui.getStyle();
    style.setColorsBuiltin(.dark);

    style.window_rounding = 6;
    style.frame_rounding = 4;
    style.popup_rounding = 4;
    style.grab_rounding = 4;
    style.tab_rounding = 4;
    style.scrollbar_rounding = 6;
    style.window_border_size = 1;
    style.frame_border_size = 1;

    style.setColor(.text, palette.foreground);
    style.setColor(.text_disabled, palette.dark_foreground);
    style.setColor(.window_bg, palette.background);
    style.setColor(.child_bg, palette.dark_background);
    style.setColor(.popup_bg, palette.darker_background);
    style.setColor(.border, palette.muted);
    style.setColor(.border_shadow, palette.darker_background);

    style.setColor(.frame_bg, palette.lighter_background);
    style.setColor(.frame_bg_hovered, mix(palette.lighter_background, palette.accent, 0.35));
    style.setColor(.frame_bg_active, mix(palette.lighter_background, palette.accent, 0.55));

    style.setColor(.title_bg, palette.dark_background);
    style.setColor(.title_bg_active, palette.selection);
    style.setColor(.title_bg_collapsed, palette.dark_background);
    style.setColor(.menu_bar_bg, palette.dark_background);

    style.setColor(.scrollbar_bg, palette.dark_background);
    style.setColor(.scrollbar_grab, palette.muted);
    style.setColor(.scrollbar_grab_hovered, palette.accent);
    style.setColor(.scrollbar_grab_active, palette.accent);

    style.setColor(.check_mark, palette.accent);
    style.setColor(.slider_grab, palette.accent);
    style.setColor(.slider_grab_active, mix(palette.accent, palette.bright_foreground, 0.3));

    style.setColor(.button, palette.lighter_background);
    style.setColor(.button_hovered, mix(palette.lighter_background, palette.accent, 0.4));
    style.setColor(.button_active, palette.accent);

    style.setColor(.header, palette.selection);
    style.setColor(.header_hovered, mix(palette.selection, palette.accent, 0.4));
    style.setColor(.header_active, palette.accent);

    style.setColor(.separator, palette.muted);
    style.setColor(.separator_hovered, palette.accent);
    style.setColor(.separator_active, palette.accent);

    style.setColor(.resize_grip, palette.muted);
    style.setColor(.resize_grip_hovered, palette.accent);
    style.setColor(.resize_grip_active, palette.accent);

    style.setColor(.tab, palette.dark_background);
    style.setColor(.tab_hovered, mix(palette.selection, palette.accent, 0.5));
    style.setColor(.tab_selected, palette.selection);
    style.setColor(.tab_selected_overline, palette.accent);
    style.setColor(.tab_dimmed, palette.dark_background);
    style.setColor(.tab_dimmed_selected, palette.lighter_background);

    style.setColor(.docking_preview, mix(palette.accent, palette.background, 0.4));
    style.setColor(.docking_empty_bg, palette.dark_background);

    style.setColor(.plot_lines, palette.cyan);
    style.setColor(.plot_lines_hovered, palette.accent);
    style.setColor(.plot_histogram, palette.green);
    style.setColor(.plot_histogram_hovered, palette.accent);

    style.setColor(.table_header_bg, palette.selection);
    style.setColor(.table_border_strong, palette.muted);
    style.setColor(.table_border_light, palette.dark_background);
    style.setColor(.table_row_bg, palette.background);
    style.setColor(.table_row_bg_alt, palette.dark_background);

    style.setColor(.text_link, palette.accent);
    style.setColor(.text_selected_bg, mix(palette.selection, palette.accent, 0.5));
    style.setColor(.nav_cursor, palette.accent);
    style.setColor(.drag_drop_target, palette.accent);
    style.setColor(.modal_window_dim_bg, mix(palette.background, .{ 0, 0, 0, 1 }, 0.5));
}

const lever_window_title: [:0]const u8 = "Power & Brake";
const status_window_title: [:0]const u8 = "Status";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var font_file: ?[:0]const u8 = null;
    // Omarchy only exists on Linux; on other platforms there's nothing to
    // look for, so skip straight to the compiled-in fallback palette
    // instead of trying (and failing) to read a Linux-shaped path.
    var theme_path: ?[]const u8 = if (builtin.os.tag == .linux) blk: {
        const home = init.environ_map.get("HOME") orelse break :blk null;
        break :blk try std.fmt.allocPrint(arena, "{s}/.local/state/omarchy/current/theme/colors.toml", .{home});
    } else null;

    var key_file: ?[]const u8 = init.environ_map.get("TSW_KEY_FILE");
    var base_url: []const u8 = init.environ_map.get("TSW_BASE_URL") orelse "http://localhost:31270";
    var manifest_rel: []const u8 = "manifest/game_actions_480.vdf";
    var profile_dir: []const u8 = "profiles";
    var step_size: f32 = ctl.default_step_size;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--font-file")) {
            i += 1;
            if (i < args.len) font_file = args[i];
        } else if (std.mem.eql(u8, a, "--theme-file")) {
            i += 1;
            if (i < args.len) theme_path = args[i];
        } else if (std.mem.eql(u8, a, "--key-file")) {
            i += 1;
            if (i < args.len) key_file = args[i];
        } else if (std.mem.eql(u8, a, "--base-url")) {
            i += 1;
            if (i < args.len) base_url = args[i];
        } else if (std.mem.eql(u8, a, "--manifest")) {
            i += 1;
            if (i < args.len) manifest_rel = args[i];
        } else if (std.mem.eql(u8, a, "--profile-dir")) {
            i += 1;
            if (i < args.len) profile_dir = args[i];
        } else if (std.mem.eql(u8, a, "--step-size")) {
            i += 1;
            if (i < args.len) step_size = std.fmt.parseFloat(f32, args[i]) catch step_size;
        }
    }

    const palette = if (theme_path) |p| loadPalette(arena, io, p) else Palette{};

    // A fresh install has no imgui.ini yet, so there's nothing for ImGui to
    // restore — build a sensible default dock layout in that case. If it
    // exists, trust whatever the user last arranged and leave it alone.
    const has_saved_layout = blk: {
        var f = std.Io.Dir.cwd().openFile(io, "imgui.ini", .{}) catch break :blk false;
        f.close(io);
        break :blk true;
    };

    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .opengl_api);
    zglfw.windowHint(.context_version_major, 3);
    zglfw.windowHint(.context_version_minor, 3);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);
    zglfw.windowHint(.doublebuffer, true);

    const window = try zglfw.Window.create(1280, 800, "TSW Steam Bridge", null, null);
    defer window.destroy();
    zglfw.makeContextCurrent(window);
    zglfw.swapInterval(1);
    // zgui's OpenGL3 backend is compiled with IMGUI_IMPL_OPENGL_LOADER_CUSTOM
    // (see zgui's build.zig), i.e. it expects the app to resolve GL function
    // pointers itself before calling zgui.backend.init(). Without this, its
    // first internal GL call (glGetString) jumps through a null pointer.
    try zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3);

    zgui.init(gpa);
    defer zgui.deinit();
    zgui.io.setConfigFlags(.{ .dock_enable = true, .nav_enable_keyboard = true });

    if (font_file) |path| {
        _ = zgui.io.addFontFromFile(path, 18.0);
    } else {
        // Bundled so the GUI looks right out of the box on every platform
        // with zero setup — no font-matching shell pipeline required.
        // See src/assets/fonts/LICENSE-JetBrainsMono.txt (SIL OFL 1.1).
        _ = zgui.io.addFontFromMemory(default_font_ttf, 18.0);
    }

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    applyTheme(palette);

    // --- Live bridge: only attempted if we have a key file, found either
    // via --key-file/TSW_KEY_FILE or by searching the well-known places
    // Steam/Proton put it. Any failure here (bad key file, Steam not
    // running, ...) is shown in the Status panel rather than aborting —
    // the dashboard should stay usable even when nothing's connected. ---
    if (key_file == null) {
        key_file = bridge_mod.findKeyFile(arena, io, init.environ_map.get("HOME"), init.environ_map.get("USERPROFILE"));
    }

    var bridge: ?bridge_mod.Bridge = null;
    var bridge_error: ?[]const u8 = null;
    defer if (bridge) |*br| br.deinit();

    if (key_file) |key_path| attempt: {
        const api_key = bridge_mod.readKeyFile(arena, io, key_path) catch |err| {
            bridge_error = std.fmt.allocPrint(arena, "couldn't read key file '{s}': {t}", .{ key_path, err }) catch "couldn't read key file";
            break :attempt;
        };
        const client = tsw.Client.init(gpa, io, base_url, api_key);
        bridge_mod.ensureSteamAppId(io) catch {};
        const manifest_abs = bridge_mod.absolutePath(arena, io, manifest_rel) catch |err| {
            bridge_error = std.fmt.allocPrint(arena, "couldn't resolve manifest path: {t}", .{err}) catch "couldn't resolve manifest path";
            break :attempt;
        };
        bridge = bridge_mod.Bridge.init(gpa, io, client, manifest_abs, profile_dir, step_size) catch |err| {
            bridge_error = std.fmt.allocPrint(
                arena,
                "Steam Input init failed: {t} (needs a running Steam client; NoSteamClient/VersionMismatch means Steam isn't up or is out of date)",
                .{err},
            ) catch "Steam Input init failed";
            break :attempt;
        };
    }

    var layout_built = false;

    while (!window.shouldClose()) {
        zglfw.pollEvents();

        if (bridge) |*br| br.tick();
        const bridge_ptr: ?*const bridge_mod.Bridge = if (bridge) |*br| br else null;

        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

        const viewport = zgui.getMainViewport();
        const dockspace_id = zgui.dockSpaceOverViewport(0, viewport, .{});
        if (!layout_built) {
            layout_built = true;
            if (!has_saved_layout) buildDefaultLayout(dockspace_id);
        }

        drawStatusWindow(bridge_ptr, bridge_error, base_url, key_file != null, palette);
        drawLeverWindow(bridge_ptr, palette);
        for (ctl.categories) |cat| {
            if (cat == .power_brake) continue; // levers get their own window above
            drawCategoryWindow(cat, bridge_ptr, palette);
        }

        gl.viewport(0, 0, fb_size[0], fb_size[1]);
        gl.clearColor(palette.background[0], palette.background[1], palette.background[2], 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        zgui.backend.draw();

        window.swapBuffers();
    }
}

fn buildDefaultLayout(dockspace_id: zgui.Ident) void {
    var left_id: zgui.Ident = undefined;
    var right_id: zgui.Ident = undefined;
    _ = zgui.dockBuilderSplitNode(dockspace_id, .left, 0.22, &left_id, &right_id);

    var left_top_id: zgui.Ident = undefined;
    var left_bottom_id: zgui.Ident = undefined;
    _ = zgui.dockBuilderSplitNode(left_id, .up, 0.4, &left_top_id, &left_bottom_id);

    zgui.dockBuilderDockWindow(status_window_title, left_top_id);
    zgui.dockBuilderDockWindow(lever_window_title, left_bottom_id);
    for (ctl.categories) |cat| {
        if (cat == .power_brake) continue;
        zgui.dockBuilderDockWindow(cat.label(), right_id);
    }
    zgui.dockBuilderFinish(dockspace_id);
}

fn drawStatusWindow(
    bridge_ptr: ?*const bridge_mod.Bridge,
    bridge_error: ?[]const u8,
    base_url: []const u8,
    wanted_live: bool,
    palette: Palette,
) void {
    if (zgui.begin(status_window_title, .{})) {
        if (!wanted_live) {
            zgui.textColored(palette.yellow, "Preview mode", .{});
            zgui.textWrapped(
                "No --key-file given, so this isn't connected to Steam Input or Train Sim World yet. Pass --key-file <path-to-CommAPIKey.txt> to go live.",
                .{},
            );
        } else if (bridge_error) |msg| {
            zgui.textColored(palette.red, "Not connected", .{});
            zgui.textWrapped("{s}", .{msg});
        } else if (bridge_ptr) |br| {
            const has_controller = br.hasController();
            zgui.textColored(
                if (has_controller) palette.green else palette.yellow,
                "Steam Input: {s}",
                .{if (has_controller) "controller connected" else "no controller yet"},
            );
            zgui.text("Base URL: {s}", .{base_url});
            zgui.separator();
            if (br.object_class) |oc| {
                zgui.textColored(palette.green, "Active loco:", .{});
                zgui.sameLine(.{});
                zgui.text("{s}", .{oc});
                const loaded = br.profileLoaded();
                zgui.textColored(if (loaded) palette.green else palette.yellow, "Profile:", .{});
                zgui.sameLine(.{});
                zgui.textColored(
                    if (loaded) palette.foreground else palette.yellow,
                    "{s}",
                    .{if (loaded) "loaded" else "not found for this loco — run `tsw-cli discover`"},
                );
            } else {
                zgui.textColored(palette.dark_foreground, "Active loco: waiting for Train Sim World...", .{});
            }
        }
    }
    zgui.end();
}

fn drawLeverWindow(bridge_ptr: ?*const bridge_mod.Bridge, palette: Palette) void {
    if (zgui.begin(lever_window_title, .{})) {
        for (ctl.levers, 0..) |lever, idx| {
            zgui.separatorText(lever.label);

            const snap: bridge_mod.LeverSnapshot = if (bridge_ptr) |br| br.lever_snapshot[idx] else .{};
            const span = lever.range.max - lever.range.min;
            const frac = if (span != 0) (snap.value - lever.range.min) / span else 0;

            var buf: [32]u8 = undefined;
            const overlay = std.fmt.bufPrintZ(&buf, "{d:.2}", .{snap.value}) catch "?";
            zgui.progressBar(.{ .fraction = frac, .overlay = overlay });

            if (!snap.mapped) {
                zgui.textColored(palette.dark_foreground, "unmapped for this loco", .{});
            } else {
                const mode_label: [:0]const u8 = switch (snap.mode) {
                    .absolute => "absolute axis",
                    .notched => "notched detents",
                    .notchless => "notchless detents",
                };
                zgui.textColored(if (snap.active) palette.foreground else palette.dark_foreground, "mode: {s}", .{mode_label});
            }
            zgui.spacing();
        }
    }
    zgui.end();
}

fn drawCategoryWindow(cat: ctl.Category, bridge_ptr: ?*const bridge_mod.Bridge, palette: Palette) void {
    if (zgui.begin(cat.label(), .{})) {
        var shown: usize = 0;
        for (ctl.controls, 0..) |c, idx| {
            if (c.category != cat) continue;
            shown += 1;

            const snap: bridge_mod.DigitalSnapshot = if (bridge_ptr) |br| br.digital_snapshot[idx] else .{};
            const color = if (snap.pressed)
                palette.accent
            else if (snap.mapped)
                palette.foreground
            else
                palette.dark_foreground;

            zgui.pushStyleColor4f(.{ .idx = .text, .c = color });
            zgui.bullet();
            zgui.sameLine(.{});
            zgui.text("{s}", .{c.label});
            zgui.popStyleColor(.{});
        }
        if (shown == 0) zgui.textColored(palette.dark_foreground, "(none)", .{});
    }
    zgui.end();
}
