//! Hand-written Zig bindings for the subset of the Steamworks "flat" C API
//! we need (SteamAPI init/shutdown + ISteamInput).
//!
//! Why not `@cImport(@cInclude("steam/steam_api_flat.h"))`: that header
//! transitively includes real C++-only headers (steamclientpublic.h has
//! `class CSteamID { ... }` with inline methods, templates, etc.), which
//! Zig's C importer (a C, not C++, frontend) cannot parse. The actual
//! exported symbols in libsteam_api.so are plain `extern "C"` functions
//! though (see the `S_API` macro in steam_api_common.h), so we just declare
//! them directly and link against the .so — no header parsing needed.
//!
//! Every signature and struct layout here was verified against the real
//! SDK (vendor/sdk/public/steam/{steam_api.h,steam_api_common.h,isteaminput.h})
//! and by actually compiling and running a probe against
//! vendor/sdk/redistributable_bin/linux64/libsteam_api.so, which confirmed
//! symbol resolution and that `@sizeOf(InputAnalogActionData) == 13` /
//! `@sizeOf(InputDigitalActionData) == 2`, matching the SDK's
//! `#pragma pack(push, 1)` layout. It has not been exercised against a
//! live Steam client / real controller yet.

pub const InputHandle = u64;
pub const InputActionSetHandle = u64;
pub const InputDigitalActionHandle = u64;
pub const InputAnalogActionHandle = u64;

pub const ISteamInput = opaque {};

/// `typedef char SteamErrMsg[1024]` in steam_api_common.h.
pub const SteamErrMsg = [1024]u8;

/// `enum ESteamAPIInitResult` in steam_api.h.
pub const InitResult = enum(c_int) {
    ok = 0,
    failed_generic = 1,
    no_steam_client = 2,
    version_mismatch = 3,
    _,
};

/// `enum EInputSourceMode` in isteaminput.h (only the members we reference).
pub const InputSourceMode = enum(c_int) {
    none = 0,
    _,
};

/// `struct InputAnalogActionData_t` — `#pragma pack(push, 1)` in the SDK,
/// hence the explicit `align(1)` on every field to reproduce that layout.
pub const InputAnalogActionData = extern struct {
    e_mode: c_int align(1),
    x: f32 align(1),
    y: f32 align(1),
    b_active: bool align(1),
};

/// `struct InputDigitalActionData_t`.
pub const InputDigitalActionData = extern struct {
    b_state: bool align(1),
    b_active: bool align(1),
};

pub extern fn SteamAPI_InitFlat(err_msg: *SteamErrMsg) callconv(.c) InitResult;
pub extern fn SteamAPI_Shutdown() callconv(.c) void;
pub extern fn SteamAPI_RunCallbacks() callconv(.c) void;
pub extern fn SteamAPI_IsSteamRunning() callconv(.c) bool;

pub extern fn SteamAPI_SteamInput_v007() callconv(.c) ?*ISteamInput;

pub extern fn SteamAPI_ISteamInput_Init(self: *ISteamInput, explicitly_call_run_frame: bool) callconv(.c) bool;
pub extern fn SteamAPI_ISteamInput_Shutdown(self: *ISteamInput) callconv(.c) bool;
pub extern fn SteamAPI_ISteamInput_SetInputActionManifestFilePath(self: *ISteamInput, absolute_path: [*:0]const u8) callconv(.c) bool;
pub extern fn SteamAPI_ISteamInput_RunFrame(self: *ISteamInput, reserved: bool) callconv(.c) void;
pub extern fn SteamAPI_ISteamInput_BWaitForData(self: *ISteamInput, wait_forever: bool, timeout_ms: u32) callconv(.c) bool;
pub extern fn SteamAPI_ISteamInput_GetConnectedControllers(self: *ISteamInput, handles_out: [*]InputHandle) callconv(.c) c_int;

pub extern fn SteamAPI_ISteamInput_GetActionSetHandle(self: *ISteamInput, action_set_name: [*:0]const u8) callconv(.c) InputActionSetHandle;
pub extern fn SteamAPI_ISteamInput_ActivateActionSet(self: *ISteamInput, input_handle: InputHandle, action_set_handle: InputActionSetHandle) callconv(.c) void;

pub extern fn SteamAPI_ISteamInput_GetDigitalActionHandle(self: *ISteamInput, action_name: [*:0]const u8) callconv(.c) InputDigitalActionHandle;
pub extern fn SteamAPI_ISteamInput_GetDigitalActionData(self: *ISteamInput, input_handle: InputHandle, action: InputDigitalActionHandle) callconv(.c) InputDigitalActionData;

pub extern fn SteamAPI_ISteamInput_GetAnalogActionHandle(self: *ISteamInput, action_name: [*:0]const u8) callconv(.c) InputAnalogActionHandle;
pub extern fn SteamAPI_ISteamInput_GetAnalogActionData(self: *ISteamInput, input_handle: InputHandle, action: InputAnalogActionHandle) callconv(.c) InputAnalogActionData;

const std = @import("std");

test "packed struct layouts match the SDK's #pragma pack(1)" {
    try std.testing.expectEqual(@as(usize, 13), @sizeOf(InputAnalogActionData));
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(InputDigitalActionData));
}
