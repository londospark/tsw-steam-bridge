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
   `tsw-cli set <path> true` / `false` (or a float for anything that looks
   continuous) and watch what happens in the cab.
2. Rename the JSON key to the matching logical name the bridge expects:
   `throttle`, `brake`, `aws_reset`, `dsd_reset`, `horn`, `sander`,
   `pantograph_up`, `pantograph_down`, `wipers_toggle`.
3. Fix `"kind"` to `"float"` for anything that isn't a plain true/false.
4. Delete entries you don't care about mapping.

The bridge picks the profile matching the currently-active loco's
`ObjectClass` automatically and only sends values for controls that loco's
profile actually maps — unmapped logical controls are silently skipped, so
it's fine for a profile to be incomplete.
