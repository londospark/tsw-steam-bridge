//! Shared control vocabulary for the bridge and the GUI — single source of
//! truth so both always agree on what exists. Must match the action names
//! in manifest/game_actions_480.vdf. Not every locomotive maps every one
//! of these — see profiles/README.md.

pub const AnalogRange = struct { min: f32, max: f32 };
pub const unit_range: AnalogRange = .{ .min = 0.0, .max = 1.0 };
pub const bipolar_range: AnalogRange = .{ .min = -1.0, .max = 1.0 };

pub const default_step_size: f32 = 0.02;
pub const default_notches: u32 = 8;

pub const ControlKind = union(enum) {
    digital,
    /// `min`/`max` bound what we clamp the raw Steam Input axis value to.
    /// Unit (0..1) for a physical trigger/lever; bipolar (-1..1) for a
    /// single combined power/brake handle where negative means brake and
    /// positive means power.
    analog: AnalogRange,
};

pub const Category = enum {
    power_brake,
    core_cab,
    safety_gb,
    safety_de,
    etcs,

    pub fn label(self: Category) [:0]const u8 {
        return switch (self) {
            .power_brake => "Power & Brake",
            .core_cab => "Core Cab",
            .safety_gb => "British Safety",
            .safety_de => "German Safety (PZB / SIFA / LZB)",
            .etcs => "ETCS",
        };
    }
};

pub const categories = [_]Category{ .power_brake, .core_cab, .safety_gb, .safety_de, .etcs };

pub const LogicalControl = struct {
    name: [:0]const u8,
    label: [:0]const u8,
    kind: ControlKind,
    category: Category,
};

/// A lever-style control (throttle, brake, combined_power_brake) can be
/// driven two ways: a plain analog axis (`absolute_action`), or a pair of
/// digital up/down detent actions that the bridge accumulates into an
/// absolute position itself — see `tsw.profile.Profile.LeverMode`. Real
/// locos have both notched and notchless levers and TSW's API doesn't
/// reliably say which, so the active loco's profile picks the mode.
pub const Lever = struct {
    /// Also the profile lookup key.
    name: [:0]const u8,
    label: [:0]const u8,
    /// The range sent to TSW's `InputValue` (confirmed live against a
    /// real TSW7 loco: it's a plain 0..1 normalized value, equal to
    /// `notch_index / (notch_count - 1)` for a notched lever — not the
    /// signed/bipolar range you might expect for something conceptually
    /// "negative = brake, positive = power").
    range: AnalogRange,
    /// Whether the *physical* Steam Input axis bound to `absolute_action`
    /// is naturally bipolar (a StickPadGyro joystick axis, -1..1 — true
    /// for combined_power_brake/reverser, since "push forward for power,
    /// pull back for brake" only makes sense as a centered physical
    /// motion) or already matches `range` directly (an AnalogTrigger,
    /// naturally 0..1 — true for separate throttle/brake handles). When
    /// bipolar, the raw axis is remapped from -1..1 onto `range` rather
    /// than just clamped into it.
    physical_bipolar: bool,
    absolute_action: [:0]const u8,
    up_action: [:0]const u8,
    down_action: [:0]const u8,
    category: Category = .power_brake,
};

pub const levers = [_]Lever{
    .{ .name = "combined_power_brake", .label = "Combined Power/Brake", .range = unit_range, .physical_bipolar = true, .absolute_action = "combined_power_brake", .up_action = "combined_power_brake_up", .down_action = "combined_power_brake_down" },
    .{ .name = "throttle", .label = "Throttle", .range = unit_range, .physical_bipolar = false, .absolute_action = "throttle", .up_action = "throttle_up", .down_action = "throttle_down" },
    .{ .name = "brake", .label = "Brake", .range = unit_range, .physical_bipolar = false, .absolute_action = "brake", .up_action = "brake_up", .down_action = "brake_down" },
    // Reverse/Neutral/Forward. Same 0..1 InputValue shape as the others
    // (confirmed live: a 4-notch reverser reported InputValue 0.666 at
    // notch index 2 of 3, i.e. index/max_index) — physically still a
    // centered stick motion (back = reverse, forward = forward), so also
    // bipolar on the Steam Input side.
    .{ .name = "reverser", .label = "Reverser", .range = unit_range, .physical_bipolar = true, .absolute_action = "reverser", .up_action = "reverser_up", .down_action = "reverser_down" },
};

pub const controls = [_]LogicalControl{
    // Core cab controls.
    .{ .name = "horn", .label = "Horn", .kind = .digital, .category = .core_cab },
    .{ .name = "sander", .label = "Sander", .kind = .digital, .category = .core_cab },
    .{ .name = "pantograph_up", .label = "Pantograph Up", .kind = .digital, .category = .core_cab },
    .{ .name = "pantograph_down", .label = "Pantograph Down", .kind = .digital, .category = .core_cab },
    .{ .name = "wipers_toggle", .label = "Wipers", .kind = .digital, .category = .core_cab },
    .{ .name = "headlights_toggle", .label = "Headlights", .kind = .digital, .category = .core_cab },
    .{ .name = "cab_light_toggle", .label = "Cab Light", .kind = .digital, .category = .core_cab },
    .{ .name = "doors_left_toggle", .label = "Doors Left", .kind = .digital, .category = .core_cab },
    .{ .name = "doors_right_toggle", .label = "Doors Right", .kind = .digital, .category = .core_cab },
    .{ .name = "coupler_toggle", .label = "Coupler", .kind = .digital, .category = .core_cab },
    .{ .name = "master_key_toggle", .label = "Master Key", .kind = .digital, .category = .core_cab },

    // British safety systems.
    .{ .name = "aws_reset", .label = "AWS Reset", .kind = .digital, .category = .safety_gb },
    .{ .name = "dsd_reset", .label = "DSD Reset", .kind = .digital, .category = .safety_gb },
    .{ .name = "tpws_override", .label = "TPWS Override", .kind = .digital, .category = .safety_gb },
    .{ .name = "tpws_isolate", .label = "TPWS Isolate", .kind = .digital, .category = .safety_gb },
    .{ .name = "dra_toggle", .label = "DRA", .kind = .digital, .category = .safety_gb },

    // German safety systems (PZB/SIFA/LZB).
    .{ .name = "sifa_reset", .label = "SIFA Reset", .kind = .digital, .category = .safety_de },
    .{ .name = "pzb_acknowledge", .label = "PZB Acknowledge (Wachsam)", .kind = .digital, .category = .safety_de },
    .{ .name = "pzb_release", .label = "PZB Release (Frei)", .kind = .digital, .category = .safety_de },
    .{ .name = "pzb_restriction_override", .label = "PZB Restriction Override", .kind = .digital, .category = .safety_de },
    .{ .name = "lzb_override", .label = "LZB Override", .kind = .digital, .category = .safety_de },
    .{ .name = "lzb_isolation", .label = "LZB Isolation", .kind = .digital, .category = .safety_de },

    // ETCS DMI soft-buttons.
    .{ .name = "etcs_start", .label = "ETCS Start", .kind = .digital, .category = .etcs },
    .{ .name = "etcs_acknowledge", .label = "ETCS Acknowledge", .kind = .digital, .category = .etcs },
    .{ .name = "etcs_override", .label = "ETCS Override", .kind = .digital, .category = .etcs },
    .{ .name = "etcs_non_leading", .label = "ETCS Non-Leading", .kind = .digital, .category = .etcs },
};
