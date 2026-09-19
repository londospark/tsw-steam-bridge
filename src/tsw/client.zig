//! Client for the official Train Sim World external API.
//!
//! Enable it in-game via the `-HTTPAPI` Steam launch option. On first launch
//! this writes `CommAPIKey.txt` under
//! `Documents/My Games/TrainSimWorld<N>/Saved/Config/` (inside the Proton
//! prefix if you're running TSW through Proton). Every request must carry
//! that key in a `DTGCommKey` header.
//!
//! Protocol reference (unofficial, reverse-engineered from ThirdRails'
//! TSWDataService): GET /info, GET /list/{path}, GET /get/{path},
//! PATCH /set/{path}?Value={value}. Default port observed on TSW5 was 31270;
//! verify with `info` against your own install since DTG has not published
//! this officially.

const std = @import("std");

pub const Client = struct {
    allocator: std.mem.Allocator,
    http: std.http.Client,
    base_url: []const u8,
    api_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_url: []const u8, api_key: []const u8) Client {
        return .{
            .allocator = allocator,
            .http = .{ .allocator = allocator, .io = io },
            .base_url = base_url,
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    pub const Response = struct {
        status: std.http.Status,
        body: []u8,

        pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
            allocator.free(self.body);
        }
    };

    pub const RequestError = std.http.Client.FetchError || std.mem.Allocator.Error;

    fn requestRaw(self: *Client, method: std.http.Method, path: []const u8, query: ?[]const u8) RequestError!Response {
        const url = if (query) |q|
            try std.fmt.allocPrint(self.allocator, "{s}{s}?{s}", .{ self.base_url, path, q })
        else
            try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
        defer self.allocator.free(url);

        var body: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body.deinit();

        // std.http.Client.fetch() only sends an actual body when `payload`
        // is non-null; otherwise it takes the bodiless send path, which
        // asserts `!method.requestHasBody()`. PATCH always reports true
        // there, so a bodiless PATCH (everything we send is in the path
        // and query string) needs an explicit empty payload or it panics.
        const result = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = if (method.requestHasBody()) "" else null,
            .extra_headers = &.{
                .{ .name = "DTGCommKey", .value = self.api_key },
            },
            .response_writer = &body.writer,
        });

        return .{ .status = result.status, .body = try body.toOwnedSlice() };
    }

    /// GET /info — confirms the API is up and reachable, and tells you the
    /// game name/build so you can sanity-check the port/version.
    pub fn info(self: *Client) RequestError!Response {
        return self.requestRaw(.GET, "/info", null);
    }

    /// GET /list/{path} — enumerate child nodes and writable/readable
    /// endpoints under a path, e.g. "CurrentDrivableActor". This is how you
    /// discover the real control names for whatever loco is currently
    /// active; they differ per locomotive class.
    pub fn list(self: *Client, path: []const u8) RequestError!Response {
        const full = try std.fmt.allocPrint(self.allocator, "/list/{s}", .{path});
        defer self.allocator.free(full);
        return self.requestRaw(.GET, full, null);
    }

    /// GET /get/{path} — read a value, e.g. "CurrentDrivableActor/Throttle_F.Value".
    pub fn get(self: *Client, path: []const u8) RequestError!Response {
        const full = try std.fmt.allocPrint(self.allocator, "/get/{s}", .{path});
        defer self.allocator.free(full);
        return self.requestRaw(.GET, full, null);
    }

    /// PATCH /set/{path}?Value={value} — write a value. `value` is sent
    /// verbatim in the query string (e.g. "true", "0.5"); the caller is
    /// responsible for formatting it and for only passing values that don't
    /// need URL escaping (bools/numbers, which is all TSW controls take).
    pub fn set(self: *Client, path: []const u8, value: []const u8) RequestError!Response {
        const full = try std.fmt.allocPrint(self.allocator, "/set/{s}", .{path});
        defer self.allocator.free(full);
        const query = try std.fmt.allocPrint(self.allocator, "Value={s}", .{value});
        defer self.allocator.free(query);
        return self.requestRaw(.PATCH, full, query);
    }

    /// Confirmed live against TSW7: even a "bool" control's `InputValue`
    /// only accepts a numeric 0/1 — sending "true"/"false" fails with
    /// `{"Result":"Error","Message":"Invalid Value (Not a Float)"}`.
    pub fn setBool(self: *Client, path: []const u8, value: bool) RequestError!Response {
        return self.set(path, if (value) "1" else "0");
    }

    pub fn setFloat(self: *Client, path: []const u8, value: f32) RequestError!Response {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        return self.set(path, s);
    }
};
