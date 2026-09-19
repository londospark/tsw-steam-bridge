//! Per-locomotive control profiles.
//!
//! TSW control node names are not consistent across locomotives (or even
//! across versions of the same class), so we can't hardcode a single
//! mapping from "AWS reset" -> a node path. Instead each locomotive gets a
//! small JSON profile, keyed by its `ObjectClass`, built up over time as you
//! play (see `tsw-cli discover`). The bridge looks up the active loco's
//! profile at runtime and uses it to translate logical control names
//! (stable, defined by our Steam Input action manifest) into that loco's
//! actual node paths.
//!
//! Profile shape:
//! ```json
//! {
//!   "objectClass": "RVM_CRG_DB_BR101_C",
//!   "displayName": "DB BR 101",
//!   "controls": {
//!     "throttle":  {
//!       "path": "CurrentDrivableActor/Throttle_F.Value",
//!       "kind": "float",
//!       "mode": "notched",
//!       "notches": 5
//!     },
//!     "brake": {
//!       "path": "CurrentDrivableActor/TrainBrake_F.Value",
//!       "kind": "float",
//!       "mode": "notchless",
//!       "step_size": 0.03
//!     },
//!     "combined_power_brake": {
//!       "path": "CurrentDrivableActor/PowerBrakeController.Value",
//!       "kind": "float",
//!       "mode": "notched",
//!       "notches": 5,
//!       "range": { "min": -1, "max": 1 }
//!     },
//!     "aws_reset": { "path": "CurrentDrivableActor/AWS_F.Value", "kind": "bool" }
//!   }
//! }
//! ```
//!
//! `mode`/`notches`/`step_size`/`range` only matter for the three lever
//! controls (throttle, brake, combined_power_brake — see
//! src/bridge_main.zig): `"mode"` is `"absolute"` (default, read a plain
//! analog axis directly), `"notched"` (read up/down detents, step exactly
//! `1/notches` of the control's range per detent, snapped to the notch
//! grid), or `"notchless"` (read up/down detents, step by `step_size` per
//! detent — real locos have both kinds of lever, and TSW's API doesn't
//! reliably expose which, so this is set by hand from testing in the cab).
//! `"range"` overrides the lever's compiled-in default min/max — TSW's
//! `InputValue` range genuinely varies per loco (confirmed 0..1 on one
//! Class 333 handle, -1..1 on a Class 331's), so check
//! `Function.GetMinimumInputValue`/`GetMaximumInputValue` in-cab and set
//! this whenever it differs from the default.

const std = @import("std");
const Io = std.Io;
const ctl = @import("../controls.zig");

pub const Profile = struct {
    arena: std.heap.ArenaAllocator,
    root: std.json.Value,

    pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Profile {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        const data = try Io.Dir.cwd().readFileAlloc(io, path, arena.allocator(), .limited(1 << 20));
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{});

        return .{ .arena = arena, .root = root };
    }

    pub fn deinit(self: *Profile) void {
        self.arena.deinit();
    }

    fn asObject(v: std.json.Value) ?std.json.ObjectMap {
        if (v != .object) return null;
        return v.object;
    }

    fn asString(v: std.json.Value) ?[]const u8 {
        if (v != .string) return null;
        return v.string;
    }

    pub fn objectClass(self: Profile) ?[]const u8 {
        const obj = asObject(self.root) orelse return null;
        return asString(obj.get("objectClass") orelse return null);
    }

    fn controlEntry(self: Profile, name: []const u8) ?std.json.ObjectMap {
        const root_obj = asObject(self.root) orelse return null;
        const controls = asObject(root_obj.get("controls") orelse return null) orelse return null;
        return asObject(controls.get(name) orelse return null);
    }

    /// Physical node path for a logical control name (e.g. "aws_reset"),
    /// or null if this loco's profile doesn't map that control yet.
    pub fn controlPath(self: Profile, name: []const u8) ?[]const u8 {
        const entry = self.controlEntry(name) orelse return null;
        return asString(entry.get("path") orelse return null);
    }

    /// "bool" or "float" — how to format the value when calling /set.
    pub fn controlKind(self: Profile, name: []const u8) ?[]const u8 {
        const entry = self.controlEntry(name) orelse return null;
        return asString(entry.get("kind") orelse return null);
    }

    pub const LeverMode = enum { absolute, notched, notchless };

    /// How a lever control (throttle/brake/combined_power_brake) should be
    /// driven. Defaults to `.absolute` (read the plain analog axis) when
    /// unset or unrecognized.
    pub fn controlMode(self: Profile, name: []const u8) LeverMode {
        const entry = self.controlEntry(name) orelse return .absolute;
        const s = asString(entry.get("mode") orelse return .absolute) orelse return .absolute;
        if (std.mem.eql(u8, s, "notched")) return .notched;
        if (std.mem.eql(u8, s, "notchless")) return .notchless;
        return .absolute;
    }

    fn asNumber(v: std.json.Value) ?f64 {
        return switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    /// Notch count for `mode: "notched"` levers, if set.
    pub fn controlNotches(self: Profile, name: []const u8) ?u32 {
        const entry = self.controlEntry(name) orelse return null;
        const n = asNumber(entry.get("notches") orelse return null) orelse return null;
        if (n < 1) return null;
        return @intFromFloat(n);
    }

    /// Per-detent step size for `mode: "notchless"` levers, in the
    /// control's own units (e.g. 0.03 for 3% of a 0..1 range). Falls back
    /// to the bridge's `--step-size` default when unset.
    pub fn controlStepSize(self: Profile, name: []const u8) ?f32 {
        const entry = self.controlEntry(name) orelse return null;
        const n = asNumber(entry.get("step_size") orelse return null) orelse return null;
        return @floatCast(n);
    }

    /// Override for a lever's `InputValue` range, e.g. `"range": { "min":
    /// -1, "max": 1 }`. TSW does not use a consistent range across locos —
    /// confirmed live that a Class 333's CombinedPowerBrakeHandle is 0..1
    /// but a Class 331's PowerBrakeController is genuinely -1..1 — so this
    /// falls back to the lever's compiled-in default (see controls.zig)
    /// when the profile doesn't say otherwise. Always check
    /// `Function.GetMinimumInputValue`/`GetMaximumInputValue` in-cab rather
    /// than assuming.
    pub fn controlRange(self: Profile, name: []const u8) ?ctl.AnalogRange {
        const entry = self.controlEntry(name) orelse return null;
        const range_obj = asObject(entry.get("range") orelse return null) orelse return null;
        const min = asNumber(range_obj.get("min") orelse return null) orelse return null;
        const max = asNumber(range_obj.get("max") orelse return null) orelse return null;
        return .{ .min = @floatCast(min), .max = @floatCast(max) };
    }
};

/// One discovered writable endpoint, used by `tsw-cli discover` to build a
/// skeleton profile that the user then annotates with logical names.
pub const DiscoveredControl = struct {
    /// Raw node name, e.g. "Throttle_F". Used as the placeholder JSON key
    /// until the user renames it to a logical name.
    name: []const u8,
    /// Full API path, e.g. "CurrentDrivableActor/Throttle_F.Value".
    path: []const u8,
};

/// Writes a skeleton profile JSON: real node paths filled in under their
/// raw node names, `kind` defaulted to "bool" (the most common case) for
/// the user to correct, and empty logical-name slots for the safety
/// controls that are always worth checking first.
pub fn writeSkeleton(
    gpa: std.mem.Allocator,
    io: Io,
    out_path: []const u8,
    object_class: []const u8,
    controls: []const DiscoveredControl,
) !void {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    var w = &buf.writer;

    try w.writeAll("{\n");
    try w.print("  \"objectClass\": \"{s}\",\n", .{object_class});
    try w.writeAll("  \"displayName\": \"\",\n");
    try w.writeAll("  \"_notes\": \"Rename these keys to logical names (throttle, brake, aws_reset, dsd_reset, horn, sander, pantograph_up, pantograph_down, wipers_toggle, ...) as you identify what each raw node does in-game. Fix 'kind' to float where the control takes a continuous value instead of true/false.\",\n");
    try w.writeAll("  \"controls\": {\n");
    for (controls, 0..) |ctrl, i| {
        try w.print("    \"{s}\": {{ \"path\": \"{s}\", \"kind\": \"bool\" }}", .{ ctrl.name, ctrl.path });
        if (i != controls.len - 1) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  }\n");
    try w.writeAll("}\n");

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.written() });
}
