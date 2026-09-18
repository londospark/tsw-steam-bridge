//! tsw-cli — a small debug/discovery tool for the TSW external API.
//!
//! This talks to TSW directly over HTTP; it does not touch Steam Input at
//! all. Use it to confirm the API is reachable (`info`), explore what
//! controls the currently-active locomotive exposes (`list`, `discover`),
//! and poke individual values by hand (`get`/`set`) while you figure out
//! which raw node is actually the AWS reset, which is DSD, etc.

const std = @import("std");
const tsw = @import("tsw/client.zig");
const profile = @import("tsw/profile.zig");

const default_base_url = "http://localhost:31270";

fn usage() void {
    std.debug.print(
        \\tsw-cli — talk to the Train Sim World external API (-HTTPAPI)
        \\
        \\Usage:
        \\  tsw-cli [--key-file PATH] [--base-url URL] <command> [args]
        \\
        \\Commands:
        \\  info                      check the API is reachable
        \\  list <path>               list nodes/endpoints under a path (e.g. CurrentDrivableActor)
        \\  get <path>                read a value (e.g. CurrentDrivableActor/Throttle_F.Value)
        \\  set <path> <value>        write a value (e.g. CurrentDrivableActor/Pantograph_F.Value true)
        \\  discover [out.json]       walk the current loco's writable controls into a profile skeleton
        \\
        \\Key file:
        \\  Pass --key-file, or set TSW_KEY_FILE, to the CommAPIKey.txt written by
        \\  TSW when launched with -HTTPAPI (under
        \\  "Documents/My Games/TrainSimWorld<N>/Saved/Config/", inside your Proton
        \\  prefix if applicable).
        \\
        \\Base URL:
        \\  Defaults to {s}. TSW5 was observed on this port; verify with `info`
        \\  since DTG hasn't published this officially and it may differ on TSW7.
        \\
    , .{default_base_url});
}

fn readKeyFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
    return std.mem.trim(u8, raw, " \t\r\n");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var key_file: ?[]const u8 = init.environ_map.get("TSW_KEY_FILE");
    var base_url: []const u8 = init.environ_map.get("TSW_BASE_URL") orelse default_base_url;

    var rest = std.ArrayList([]const u8).empty;
    defer rest.deinit(arena);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--key-file")) {
            i += 1;
            if (i >= args.len) return fail("--key-file needs a value", .{});
            key_file = args[i];
        } else if (std.mem.eql(u8, a, "--base-url")) {
            i += 1;
            if (i >= args.len) return fail("--base-url needs a value", .{});
            base_url = args[i];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage();
            return;
        } else {
            try rest.append(arena, a);
        }
    }

    if (rest.items.len == 0) {
        usage();
        return fail("missing command", .{});
    }

    const key_path = key_file orelse return fail(
        "no API key file given (pass --key-file or set TSW_KEY_FILE)",
        .{},
    );
    const api_key = readKeyFile(arena, io, key_path) catch |err| {
        return fail("couldn't read key file '{s}': {t}", .{ key_path, err });
    };

    var client = tsw.Client.init(gpa, io, base_url, api_key);
    defer client.deinit();

    const command = rest.items[0];
    const cmd_args = rest.items[1..];

    if (std.mem.eql(u8, command, "info")) {
        try cmdInfo(&client);
    } else if (std.mem.eql(u8, command, "list")) {
        if (cmd_args.len != 1) return fail("usage: list <path>", .{});
        try cmdList(&client, cmd_args[0]);
    } else if (std.mem.eql(u8, command, "get")) {
        if (cmd_args.len != 1) return fail("usage: get <path>", .{});
        try cmdGet(&client, cmd_args[0]);
    } else if (std.mem.eql(u8, command, "set")) {
        if (cmd_args.len != 2) return fail("usage: set <path> <value>", .{});
        try cmdSet(&client, cmd_args[0], cmd_args[1]);
    } else if (std.mem.eql(u8, command, "discover")) {
        const out_path = if (cmd_args.len >= 1) cmd_args[0] else null;
        try cmdDiscover(arena, io, &client, out_path);
    } else {
        usage();
        return fail("unknown command '{s}'", .{command});
    }
}

fn fail(comptime fmt: []const u8, args: anytype) !void {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.CliUsage;
}

fn printResponse(resp: tsw.Client.Response) void {
    std.debug.print("HTTP {d}\n{s}\n", .{ @intFromEnum(resp.status), resp.body });
}

fn cmdInfo(client: *tsw.Client) !void {
    const resp = try client.info();
    defer resp.deinit(client.allocator);
    printResponse(resp);
}

fn cmdList(client: *tsw.Client, path: []const u8) !void {
    const resp = try client.list(path);
    defer resp.deinit(client.allocator);
    printResponse(resp);
}

fn cmdGet(client: *tsw.Client, path: []const u8) !void {
    const resp = try client.get(path);
    defer resp.deinit(client.allocator);
    printResponse(resp);
}

fn cmdSet(client: *tsw.Client, path: []const u8, value: []const u8) !void {
    const resp = try client.set(path, value);
    defer resp.deinit(client.allocator);
    printResponse(resp);
}

fn jsonObject(v: std.json.Value) ?std.json.ObjectMap {
    if (v != .object) return null;
    return v.object;
}

fn jsonString(v: std.json.Value) ?[]const u8 {
    if (v != .string) return null;
    return v.string;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Walks CurrentDrivableActor's node tree one level deep, collecting any
/// node that exposes a writable "Value" endpoint, and writes a profile
/// skeleton for the loco currently in the cab.
fn cmdDiscover(arena: std.mem.Allocator, io: std.Io, client: *tsw.Client, out_path_opt: ?[]const u8) !void {
    const object_class = blk: {
        const resp = client.get("CurrentDrivableActor.ObjectClass") catch break :blk null;
        defer resp.deinit(client.allocator);
        if (resp.status != .ok) break :blk null;
        var parsed = std.json.parseFromSlice(std.json.Value, arena, resp.body, .{}) catch break :blk null;
        defer parsed.deinit();
        const obj = jsonObject(parsed.value) orelse break :blk null;
        const s = jsonString(obj.get("ObjectClass") orelse break :blk null) orelse break :blk null;
        break :blk try arena.dupe(u8, s);
    } orelse "unknown_loco";

    std.debug.print("discovering controls for loco: {s}\n", .{object_class});

    const top_resp = try client.list("CurrentDrivableActor");
    defer top_resp.deinit(client.allocator);
    if (top_resp.status != .ok) return fail("GET /list/CurrentDrivableActor -> HTTP {d}: {s}", .{ @intFromEnum(top_resp.status), top_resp.body });

    var top_parsed = try std.json.parseFromSlice(std.json.Value, arena, top_resp.body, .{});
    defer top_parsed.deinit();
    const top_obj = jsonObject(top_parsed.value) orelse return fail("unexpected /list response shape", .{});
    const nodes_v = top_obj.get("Nodes") orelse return fail("no Nodes in /list response", .{});
    if (nodes_v != .array) return fail("Nodes is not an array", .{});

    var controls = std.ArrayList(profile.DiscoveredControl).empty;
    defer controls.deinit(arena);

    for (nodes_v.array.items) |node_v| {
        const node_obj = jsonObject(node_v) orelse continue;
        const node_name = jsonString(node_obj.get("Name") orelse continue) orelse continue;

        const sub_path = try std.fmt.allocPrint(arena, "CurrentDrivableActor/{s}", .{node_name});
        const sub_resp = client.list(sub_path) catch continue;
        defer sub_resp.deinit(client.allocator);
        if (sub_resp.status != .ok) continue;

        var sub_parsed = std.json.parseFromSlice(std.json.Value, arena, sub_resp.body, .{}) catch continue;
        defer sub_parsed.deinit();
        const sub_obj = jsonObject(sub_parsed.value) orelse continue;
        const endpoints_v = sub_obj.get("Endpoints") orelse continue;
        if (endpoints_v != .array) continue;

        for (endpoints_v.array.items) |ep_v| {
            const ep_obj = jsonObject(ep_v) orelse continue;
            const ep_name = jsonString(ep_obj.get("Name") orelse continue) orelse continue;

            // Best-effort: TSW's API doesn't document a notch-count field
            // anywhere we've found, but if some loco happens to expose one
            // under a name like this, it's worth knowing about when you're
            // filling in a lever's "notches" in its profile.
            if (containsIgnoreCase(ep_name, "notch") or containsIgnoreCase(ep_name, "detent")) {
                std.debug.print("  possible notch-count endpoint: CurrentDrivableActor/{s}.{s} (untested — try `tsw-cli get` on it)\n", .{ node_name, ep_name });
            }

            if (!std.mem.eql(u8, ep_name, "Value")) continue;
            const writable = ep_obj.get("Writable") orelse continue;
            if (writable != .bool or !writable.bool) continue;

            const full_path = try std.fmt.allocPrint(arena, "CurrentDrivableActor/{s}.Value", .{node_name});
            try controls.append(arena, .{ .name = try arena.dupe(u8, node_name), .path = full_path });
            std.debug.print("  writable: {s}\n", .{full_path});
        }
    }

    const default_out = try std.fmt.allocPrint(arena, "profiles/{s}.json", .{object_class});
    const out_path = out_path_opt orelse default_out;

    try profile.writeSkeleton(arena, io, out_path, object_class, controls.items);
    std.debug.print(
        "\nwrote {d} candidate controls to {s}\n" ++
            "next: rename the keys to logical names (throttle, brake, aws_reset, dsd_reset, ...)\n" ++
            "by testing each path with `tsw-cli set <path> true/false` (or a float) while parked,\n" ++
            "and fix \"kind\" for anything that isn't a plain bool.\n",
        .{ controls.items.len, out_path },
    );
}
