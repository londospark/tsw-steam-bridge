# Locomotive profiles

TSW's control node names aren't consistent across locomotives (or even
across versions of the same class), so there's no single "AWS reset" path
that works everywhere. Each loco gets its own `<ObjectClass>.json` file here,
built up as you encounter it in-game.

Generate a skeleton for whatever loco you're currently sitting in:

```sh
./zig-out/bin/tsw-cli --key-file <path-to-CommAPIKey.txt> discover
```

This walks `CurrentDrivableActor`'s writable nodes and writes
`profiles/<ObjectClass>.json` with every candidate control keyed by its raw
node name. From there:

1. While parked/stationary, try each candidate with
   `tsw-cli set <path> 1` / `0` (or a float for anything that looks
   continuous) and watch what happens in the cab. Confirmed live: TSW's
   `InputValue` only ever accepts a number — sending `true`/`false`
   fails with `{"Result":"Error","Message":"Invalid Value (Not a
   Float)"}`, even for controls that are conceptually boolean.
2. Rename the JSON key to the matching logical name the bridge expects
   (below). Only map what this loco actually has — a British loco's
   profile won't have any `pzb_*`/`sifa_*`/`lzb_*` entries, a German
   loco's won't have `tpws_*`/`dra_*`, etc.
3. Fix `"kind"` to `"float"` for anything that isn't a plain true/false.
4. Delete entries you don't care about mapping.

## Logical control names

These are the names the Steam Input action manifest
(`manifest/game_actions_480.vdf`) and `steam-bridge`'s `controls` table
know about. Add a new one to *both* those places (and here) if you need a
control that isn't listed.

| Category | Names |
|---|---|
| Power/brake (analog) | `combined_power_brake` (single lever, -1..1: negative = brake, positive = power), `throttle`, `brake` (separate handles, 0..1 each) |
| Core cab | `horn`, `sander`, `pantograph_up`, `pantograph_down`, `wipers_toggle`, `headlights_toggle`, `cab_light_toggle`, `doors_left_toggle`, `doors_right_toggle`, `coupler_toggle` |
| British safety | `aws_reset`, `dsd_reset`, `tpws_override`, `tpws_isolate`, `dra_toggle` |
| German safety (PZB/SIFA/LZB) | `sifa_reset`, `pzb_acknowledge`, `pzb_release`, `pzb_restriction_override`, `lzb_override`, `lzb_isolation` |
| ETCS DMI | `etcs_start`, `etcs_acknowledge`, `etcs_override`, `etcs_non_leading` |

You can map both `combined_power_brake` and separate `throttle`/`brake` on
the same loco if you want — nothing requires picking one.

The bridge picks the profile matching the currently-active loco's
`ObjectClass` automatically and only sends values for controls that loco's
profile actually maps — unmapped logical controls are silently skipped, so
it's fine for a profile to be incomplete.

## Notched vs. notchless levers

`throttle`, `brake` and `combined_power_brake` can each be driven two
ways, controlled per-lever by a `"mode"` field on that control's profile
entry:

```json
"combined_power_brake": {
  "path": "CurrentDrivableActor/CombinedPowerBrakeHandle.InputValue",
  "kind": "float",
  "mode": "notched",
  "notches": 9
}
```

(a real example, from `profiles/RVM_AWL_NT_Class333_DMSO_B_C.json` — that loco's actual notch count, read live from its own `Function.GetNotchCount`.)

- **`"absolute"`** (default, or just omit `"mode"`) — reads a plain analog
  axis directly (`throttle`/`brake`/`combined_power_brake` in Steam
  Input) and sends its position every tick it changes. Fine for a
  spring-centered stick, but means holding a precise deflection to hold a
  speed, which gets old fast.
- **`"notched"`** — for real levers with discrete positions. Reads
  `throttle_up`/`throttle_down`-style detent actions instead (bind these
  to anything: a Steam Input trackpad in "Scroll Wheel" circular mode
  makes a nice haptic rotary-encoder feel, but plain buttons/paddles work
  too) and steps exactly `1/notches` of the control's range per detent,
  snapped to the notch grid so it can't drift over a long session. Set
  `"notches"` to how many positions the real lever has (defaults to 8 if
  omitted — worth setting properly by counting in-cab).
- **`"notchless"`** — same detent-based input, but steps by a tunable
  `"step_size"` (in the control's own units, e.g. `0.03` for 3% of a 0..1
  range) instead of snapping to a grid. Falls back to `steam-bridge`'s
  `--step-size` flag (default `0.02`) if omitted from the profile.

We haven't found anywhere in TSW's API that reports whether a given
loco's lever is notched or how many notches it has, so this is set by
hand from watching the lever in the cab. `tsw-cli discover` does scan
endpoint names for anything containing "notch"/"detent" and prints a
heads-up if it finds one, on the chance some loco exposes it — but treat
that as a hint to test with `tsw-cli get`, not a confirmed source.

Every lever node does expose real `Function.GetNotchCount`,
`Function.GetMinimumInputValue`, and `Function.GetMaximumInputValue`
endpoints though (confirmed live, e.g.
`CurrentDrivableActor/Reverser.Function.GetNotchCount` — note the
`Function.` prefix is part of the endpoint name itself), so query those
directly with `tsw-cli get` rather than guessing notch counts by feel.

## Range varies per loco — don't assume 0..1

Confirmed live across two different locomotives: a Class 333's
`CombinedPowerBrakeHandle.InputValue` runs 0..1, but a Class 331's
`PowerBrakeController.InputValue` is genuinely -1..1 (negative = brake,
positive = power). There's no universal range. Always check
`Function.GetMinimumInputValue`/`GetMaximumInputValue` for a lever before
assuming, and if it differs from the default 0..1, add a `"range"`
override to that control's profile entry:

```json
"combined_power_brake": {
  "path": "CurrentDrivableActor/PowerBrakeController.InputValue",
  "kind": "float",
  "mode": "notched",
  "notches": 5,
  "range": { "min": -1, "max": 1 }
}
```

Omit `"range"` entirely when the lever matches the compiled-in default
(0..1 for every lever in `src/controls.zig` as of this writing).
