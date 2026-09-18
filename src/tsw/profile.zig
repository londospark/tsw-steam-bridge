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
//!     "throttle":  { "path": "CurrentDrivableActor/Throttle_F.Value", "kind": "float" },
//!     "aws_reset": { "path": "CurrentDrivableActor/AWS_F.Value",      "kind": "bool" }
//!   }
//! }
//! ```

const std = @import("std");
const Io = std.Io;

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
