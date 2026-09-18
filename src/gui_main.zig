//! tsw-gui — live dashboard shell for the bridge, built on Dear ImGui
//! (via zgui/zglfw + OpenGL3) with docking enabled.
//!
//! This is a windowing/theming/layout scaffold: the panels below show a
//! representative layout (controller state, active loco/profile, mapped
//! controls) but are not yet wired to a running steam-bridge's live poll
//! loop — see README "Known gaps". Drag panel tabs to rearrange/dock them;
//! layout is not currently persisted between runs.
//!
//! Theming: colors are read at startup from Omarchy's *current* theme
//! (`~/.local/state/omarchy/current/theme/colors.toml`) rather than
//! hardcoded, so the panel follows whatever theme is active system-wide.
//! The font is not auto-detected here (Omarchy's font tracker is
//! monospace-only and shelling out to `fc-match` isn't worth the
//! complexity inside this binary) — pass `--font-file` yourself, e.g.:
//!
//!   ./zig-out/bin/tsw-gui --font-file "$(fc-match -f '%{file}' "$(omarchy font current)")"
//!
//! `scripts/run-gui.sh` does exactly this and is the normal way to launch it.

const std = @import("std");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");

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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var font_file: ?[:0]const u8 = null;
    var theme_path: []const u8 = init.environ_map.get("HOME") orelse "";
    const default_theme_suffix = "/.local/state/omarchy/current/theme/colors.toml";
    const theme_path_buf = try std.fmt.allocPrint(arena, "{s}{s}", .{ theme_path, default_theme_suffix });
    theme_path = theme_path_buf;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--font-file")) {
            i += 1;
            if (i < args.len) font_file = args[i];
        } else if (std.mem.eql(u8, args[i], "--theme-file")) {
            i += 1;
            if (i < args.len) theme_path = args[i];
        }
    }

    const palette = loadPalette(arena, io, theme_path);

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
        std.debug.print("note: no --font-file given, using ImGui's built-in default font\n", .{});
        _ = zgui.io.addFontDefault(null);
    }

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    applyTheme(palette);

    while (!window.shouldClose()) {
        zglfw.pollEvents();

        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

        const viewport = zgui.getMainViewport();
        _ = zgui.dockSpaceOverViewport(0, viewport, .{});

        if (zgui.begin("Controller", .{})) {
            zgui.textColored(palette.yellow, "preview build - not wired to a live steam-bridge yet", .{});
            zgui.separator();
            zgui.text("Steam Input: {s}", .{"not connected"});
            zgui.text("Action set: {s}", .{"Driving"});
            const throttle: f32 = 0.35;
            const brake: f32 = 0.0;
            zgui.text("throttle", .{});
            zgui.progressBar(.{ .fraction = throttle, .overlay = "throttle" });
            zgui.text("brake", .{});
            zgui.progressBar(.{ .fraction = brake, .overlay = "brake" });
            var aws = false;
            var dsd = false;
            _ = zgui.checkbox("aws_reset", .{ .v = &aws });
            _ = zgui.checkbox("dsd_reset", .{ .v = &dsd });
        }
        zgui.end();

        if (zgui.begin("Locomotive", .{})) {
            zgui.text("Active loco: {s}", .{"(none)"});
            zgui.text("Profile: {s}", .{"profiles/<ObjectClass>.json"});
            zgui.separatorText("Mapped controls");
            zgui.bulletText("throttle -> (unmapped)", .{});
            zgui.bulletText("aws_reset -> (unmapped)", .{});
            zgui.bulletText("dsd_reset -> (unmapped)", .{});
        }
        zgui.end();

        if (zgui.begin("TSW API", .{})) {
            zgui.text("Base URL: {s}", .{"http://localhost:31270"});
            zgui.textColored(palette.red, "not connected", .{});
        }
        zgui.end();

        gl.viewport(0, 0, fb_size[0], fb_size[1]);
        gl.clearColor(palette.background[0], palette.background[1], palette.background[2], 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        zgui.backend.draw();

        window.swapBuffers();
    }
}
