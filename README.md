# tsw-steam-bridge

A Zig bridge between Steam Input and Train Sim World, so a controller can
drive TSW's cab controls with real analog precision and independently
bindable safety controls (AWS reset, DSD/vigilance reset, ...) instead of
being flattened through Steam Input's keyboard/mouse emulation.

## Why not just emulate a keyboard

Steam Input's default desktop-config mode maps controller input to
synthetic key presses, which is how most "just make it work" controller
setups happen. That's fine for a game with few, coarse controls, but it
collapses two things TSW needs kept apart:

- **Digital vs analog.** Throttle and brake want continuous 0..1 values;
  a keyboard only gives you "tap" or "held", so you lose fine control.
- **Independent safety controls.** AWS reset and DSD (Driver's Safety
  Device / vigilance) reset are separate physical controls in the real cab
  and often end up sharing or fighting over the same key in a simple
  keybind scheme.

So instead this reads real Steam Input digital/analog *actions* (via our
own action manifest, `manifest/game_actions_480.vdf`) and writes values
straight into TSW through its external HTTP API — no synthetic input
device involved.

## Architecture

Two executables, because they have very different dependency footprints:

- **`tsw-cli`** — pure Zig, zero external dependencies. Talks to TSW's
  `-HTTPAPI` over plain HTTP. Use it to check the API is reachable, explore
  a locomotive's control tree, and hand-test individual values.
- **`steam-bridge`** — the actual bridge. Links against the Steamworks SDK
  to read Steam Input actions and drives them into TSW via the same client
  code `tsw-cli` uses.

```
src/
  main.zig          tsw-cli entry point
  bridge_main.zig    steam-bridge entry point (the real-time poll loop)
  tsw/
    client.zig       TSW external API HTTP client
    profile.zig       per-locomotive control-mapping profiles
  steam/
    ffi.zig           hand-written extern bindings for the Steamworks flat C API
    input.zig         higher-level ISteamInput wrapper
manifest/
  game_actions_480.vdf   Steam Input action manifest (our own, not TSW's)
profiles/
  <ObjectClass>.json     per-locomotive control mappings, built up over time
```

## The TSW external API

TSW ships an (unofficial, reverse-engineered — DTG hasn't published this)
HTTP API. Enable it by adding `-HTTPAPI` to TSW's Steam launch options; on
next launch it writes `CommAPIKey.txt` under
`Documents/My Games/TrainSimWorld<N>/Saved/Config/` (inside your Proton
prefix if you're running TSW through Proton — e.g. under
`~/.local/share/Steam/steamapps/compatdata/<appid>/pfx/drive_c/users/steamuser/My Documents/...`;
`find ~/.steam ~/.local/share/Steam -iname CommAPIKey.txt` after one launch
will find it for you). Every request needs that key in a `DTGCommKey`
header.

Endpoints (all under `http://localhost:31270`, verify the port with `info`
since it may differ on TSW7 — this was observed on TSW5):

- `GET /info` — confirms the API's up, tells you game name/build.
- `GET /list/{path}` — enumerate child nodes and endpoints under a path.
- `GET /get/{path}` — read a value.
- `PATCH /set/{path}?Value={value}` — write a value.

Control names are **not consistent across locomotives** (or even across
versions of the same class), so there's no universal "AWS reset" path.
That's what the profile system in `profiles/` is for — see
`profiles/README.md`.

## Steam Input integration

`src/steam/ffi.zig` is a hand-written set of `extern fn` declarations for
the Steamworks flat C API, not a `@cImport`. The real SDK headers
(`steam_api_flat.h` and friends) transitively pull in genuine C++-only
headers (`class CSteamID { ... }` with inline methods, templates), which
Zig's C importer can't parse. The actual exported symbols in
`libsteam_api.so` are plain `extern "C"` functions though, so we declare
them directly and link against the `.so` — no header parsing needed.

Every symbol name and struct layout in `ffi.zig` was checked against the
vendored SDK headers and verified by actually compiling and running a probe
against `vendor/sdk/redistributable_bin/linux64/libsteam_api.so`
(confirmed `@sizeOf(InputAnalogActionData) == 13` /
`@sizeOf(InputDigitalActionData) == 2`, matching the SDK's
`#pragma pack(push, 1)`, and confirmed all referenced symbols resolve at
link time).

**Status as of this writing:** `SteamAPI_InitFlat` and `ISteamInput::Init`
were confirmed working end-to-end against a real, running Steam client
(`SteamAPI_Init(): Loaded '.../steamclient.so' OK`, real Steam ID cached).
`SetInputActionManifestFilePath` currently fails
(`"Timed out waiting for game mapping!"` from Steam's own log) — next thing
to debug once you're testing with a controller attached, likely something
about how app id 480 (see below) accepts a custom manifest, or async
timing around when Steam is ready to receive it.

### Why app id 480

The Steam Input API needs to run as *some* recognized Steam app
(`SteamAPI_Init` needs a `steam_appid.txt` or `SteamAppId` env var pointing
at one). For a personal, unpublished tool, the standard approach is Valve's
public "Spacewar" test app, id `480` — `steam-bridge` writes
`steam_appid.txt` containing `480` on first run if it's missing. If you
ever publish this under your own Steam app id, swap it there and
regenerate `manifest/game_actions_480.vdf` for that id.

## Building

Requires Zig 0.16.0+ and the vendored Steamworks SDK (see below).

```sh
zig build            # builds tsw-cli always; steam-bridge if the SDK is vendored
zig build run-cli -- info --key-file /path/to/CommAPIKey.txt
zig build run-bridge -- --key-file /path/to/CommAPIKey.txt
```

### Vendoring the Steamworks SDK

Download `steamworks_sdk.zip` from
<https://partner.steamgames.com/downloads/list> (any Steam account can get
it) and extract it so `vendor/sdk/public/...` and
`vendor/sdk/redistributable_bin/...` exist. `vendor/sdk/` is gitignored —
it's a large, license-encumbered redistributable, not project source.

### A note on this machine's linker

Zig 0.16.0's self-hosted ELF linker can't yet handle the `.sframe` unwind
sections that current glibc/gcc emit into `crt1.o` (reproduced independent
of this project — any libc-linked Zig binary fails with `fatal linker
error: unhandled relocation type R_X86_64_PC64 ... .sframe` here). The
system linker (via `cc`) handles it fine, so `build.zig` builds
`steam-bridge` as a `.o` with `zig build-obj` and links the final binary by
shelling out to `cc` instead of `b.addExecutable`'s normal path. `tsw-cli`
doesn't need libc at all, so it's unaffected and links normally. Revisit
the `have_sdk` branch in `build.zig` once Zig's linker supports SFrame
relocations upstream.

## Workflow

1. Launch TSW with `-HTTPAPI`, get in a cab, note the key file path.
2. `tsw-cli discover --key-file <path>` to build a control-mapping
   skeleton for whatever loco you're in (see `profiles/README.md`).
3. Test candidate paths by hand with `tsw-cli set`/`get` while parked, and
   fill in logical names (`throttle`, `aws_reset`, `dsd_reset`, ...).
4. Configure your controller's bindings for the `Driving` action set in
   Steam's controller configurator (once manifest activation is working).
5. `steam-bridge --key-file <path>` to run the live bridge.

## Known gaps / next steps

- Steam Input manifest activation (`SetInputActionManifestFilePath`) isn't
  confirmed working yet — needs debugging with a controller attached.
- Single controller only (`GetConnectedControllers` takes the first
  handle).
- Digital controls are sent as "hold" (true on press, false on release);
  some TSW controls are toggles instead (e.g. pantograph). No per-control
  override for this yet — add one in the profile format if you hit it.
- No escaping on `/set` values beyond what we generate ourselves (bools and
  floats); fine for now since that's all TSW controls take.
