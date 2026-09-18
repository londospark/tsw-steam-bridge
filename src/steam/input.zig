//! Thin, Zig-friendly wrapper over `ffi.zig`'s raw ISteamInput bindings.
//!
//! This talks to Steam Input using our *own* action manifest
//! (manifest/game_actions_480.vdf), not TSW's in-game bindings — that's the
//! whole point: we get real digital/analog action data straight from Steam
//! Input, so e.g. AWS reset and DSD reset can be bound to distinct physical
//! buttons with no keyboard-emulation collision, and throttle/brake get true
//! analog values instead of stepped key-taps.

const std = @import("std");
const ffi = @import("ffi.zig");

pub const InitError = error{
    NoSteamClient,
    VersionMismatch,
    FailedGeneric,
    InputInitFailed,
    ManifestRejected,
};

pub const SteamInput = struct {
    handle: *ffi.ISteamInput,
    controller: ffi.InputHandle,

    /// `manifest_abs_path` must be an absolute path — Steam resolves it
    /// relative to nothing in particular otherwise. Requires a
    /// `steam_appid.txt` (or `SteamAppId` env var) in place before this is
    /// called; see README for why we default to Spacewar's app id (480).
    pub fn init(manifest_abs_path: [:0]const u8) InitError!SteamInput {
        var err_msg: ffi.SteamErrMsg = undefined;
        switch (ffi.SteamAPI_InitFlat(&err_msg)) {
            .ok => {},
            .no_steam_client => return error.NoSteamClient,
            .version_mismatch => return error.VersionMismatch,
            else => return error.FailedGeneric,
        }
        errdefer ffi.SteamAPI_Shutdown();

        const steam_input = ffi.SteamAPI_SteamInput_v007() orelse return error.FailedGeneric;
        if (!ffi.SteamAPI_ISteamInput_Init(steam_input, false)) return error.InputInitFailed;
        errdefer _ = ffi.SteamAPI_ISteamInput_Shutdown(steam_input);

        if (!ffi.SteamAPI_ISteamInput_SetInputActionManifestFilePath(steam_input, manifest_abs_path.ptr)) {
            return error.ManifestRejected;
        }

        // Let Steam Input settle before the first GetConnectedControllers call.
        ffi.SteamAPI_RunCallbacks();
        ffi.SteamAPI_ISteamInput_RunFrame(steam_input, false);

        var handles: [16]ffi.InputHandle = undefined;
        const count = ffi.SteamAPI_ISteamInput_GetConnectedControllers(steam_input, &handles);
        const controller: ffi.InputHandle = if (count > 0) handles[0] else 0;

        return .{ .handle = steam_input, .controller = controller };
    }

    pub fn deinit(self: *SteamInput) void {
        _ = ffi.SteamAPI_ISteamInput_Shutdown(self.handle);
        ffi.SteamAPI_Shutdown();
    }

    /// Re-scans connected controllers; call after a `NoControllerConnected`
    /// warning to pick up a controller plugged in after startup.
    pub fn refreshController(self: *SteamInput) void {
        var handles: [16]ffi.InputHandle = undefined;
        const count = ffi.SteamAPI_ISteamInput_GetConnectedControllers(self.handle, &handles);
        self.controller = if (count > 0) handles[0] else 0;
    }

    pub fn hasController(self: SteamInput) bool {
        return self.controller != 0;
    }

    pub fn getActionSetHandle(self: SteamInput, name: [:0]const u8) ffi.InputActionSetHandle {
        return ffi.SteamAPI_ISteamInput_GetActionSetHandle(self.handle, name.ptr);
    }

    pub fn activateActionSet(self: SteamInput, set: ffi.InputActionSetHandle) void {
        if (!self.hasController()) return;
        ffi.SteamAPI_ISteamInput_ActivateActionSet(self.handle, self.controller, set);
    }

    pub fn getDigitalActionHandle(self: SteamInput, name: [:0]const u8) ffi.InputDigitalActionHandle {
        return ffi.SteamAPI_ISteamInput_GetDigitalActionHandle(self.handle, name.ptr);
    }

    pub fn getAnalogActionHandle(self: SteamInput, name: [:0]const u8) ffi.InputAnalogActionHandle {
        return ffi.SteamAPI_ISteamInput_GetAnalogActionHandle(self.handle, name.ptr);
    }

    pub const Digital = struct { pressed: bool, active: bool };
    pub const Analog = struct { x: f32, y: f32, active: bool };

    pub fn pollDigital(self: SteamInput, action: ffi.InputDigitalActionHandle) Digital {
        if (!self.hasController()) return .{ .pressed = false, .active = false };
        const d = ffi.SteamAPI_ISteamInput_GetDigitalActionData(self.handle, self.controller, action);
        return .{ .pressed = d.b_state, .active = d.b_active };
    }

    pub fn pollAnalog(self: SteamInput, action: ffi.InputAnalogActionHandle) Analog {
        if (!self.hasController()) return .{ .x = 0, .y = 0, .active = false };
        const d = ffi.SteamAPI_ISteamInput_GetAnalogActionData(self.handle, self.controller, action);
        return .{ .x = d.x, .y = d.y, .active = d.b_active };
    }

    /// Call once per tick before polling actions.
    pub fn runFrame(self: SteamInput) void {
        ffi.SteamAPI_RunCallbacks();
        ffi.SteamAPI_ISteamInput_RunFrame(self.handle, false);
    }
};
