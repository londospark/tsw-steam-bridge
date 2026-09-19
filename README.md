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
- **`tsw-gui`** — a live dashboard shell (Dear ImGui, docked panels) for
  watching the bridge. Not yet wired to `steam-bridge`'s live loop — see
  "The GUI" below.

```
src/
  main.zig          tsw-cli entry point
  bridge_main.zig   steam-bridge entry point (thin wrapper around bridge.zig)
  gui_main.zig      tsw-gui entry point (ImGui dashboard, also runs bridge.zig live)
  bridge.zig        the actual live bridge: poll Steam Input, translate, PATCH to TSW
  controls.zig      shared control vocabulary (single source of truth for both entry points)
  tsw/
    client.zig      TSW external API HTTP client
    profile.zig     per-locomotive control-mapping profiles
  steam/
    ffi.zig         hand-written extern bindings for the Steamworks flat C API
    input.zig       higher-level ISteamInput wrapper
manifest/
  game_actions_480.vdf   Steam Input action manifest (our own, not TSW's)
profiles/
  <ObjectClass>.json     per-locomotive control mappings, built up over time
scripts/
  run-gui.sh        launches tsw-gui with your current Omarchy font
docs/
  manual.tex        user manual source (see "Building the manual")
  images/           screenshots used by the manual
```

## The TSW external API

TSW ships a real, DTG-documented "External Interface API" (see Dovetail's
own *External Interface API v1.5* doc — written for TSW6, and confirmed
working as described against a live TSW7 session while building this).
Enable it by adding `-HTTPAPI` to TSW's Steam launch options; on next
launch it writes `CommAPIKey.txt` under
`Documents/My Games/TrainSimWorld<N>/Saved/Config/` (inside your Proton
prefix if you're running TSW through Proton — e.g. under
`~/.local/share/Steam/steamapps/compatdata/<appid>/pfx/drive_c/users/steamuser/Documents/...`,
though older Proton/Wine versions used `My Documents` instead of
`Documents`; `find ~/.steam ~/.local/share/Steam -iname CommAPIKey.txt`
after one launch will find it for you, or see "Finding your key file
automatically" below). Every request needs that key in a `DTGCommKey`
header.

### Finding your key file automatically

Neither `tsw-gui` nor `steam-bridge` require `--key-file`/`TSW_KEY_FILE`
to be passed by hand: if neither is given, both search for
`CommAPIKey.txt` themselves (`bridge_mod.findKeyFile` in `src/bridge.zig`)
by walking every `TrainSimWorld<N>` folder under every Steam library they
can find — natively under `%USERPROFILE%\Documents\My Games` on Windows,
or under each Proton prefix's `compatdata/<appid>/.../My Games` on Linux
(checking `~/.local/share/Steam`, `~/.steam/steam`, `~/.steam/root`, and
Flatpak Steam's data dir). If more than one TSW version's key file turns
up, the most recently modified one wins. `--key-file` still overrides
this if you ever need to point at something else.

Endpoints (all under `http://localhost:31270` — confirmed the same on a
live TSW7 session, build 834):

- `GET /info` — confirms the API's up, tells you game name/build.
- `GET /list/{path}` — enumerate child nodes and endpoints under a path.
- `GET /get/{path}` — read a value.
- `PATCH /set/{path}?Value={value}` — write a value. The writable
  endpoint on every interactive control is `InputValue` (DTG's own doc
  confirms this — always normalized 0..1, equal to
  `notch_index / (notch_count - 1)` for a notched lever, regardless of
  what real-world range/units the control has); `Function.GetNotchCount`,
  `Function.GetMinimumInputValue` and `Function.GetMaximumInputValue` are
  real, documented functions for querying that per-control, not a guess.

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

## The GUI

`tsw-gui` is a docked ImGui dashboard shell, built on
[zgui](https://github.com/zig-gamedev/zgui) +
[zglfw](https://github.com/zig-gamedev/zglfw) +
[zopengl](https://github.com/zig-gamedev/zopengl) (all `zig fetch`-ed, all
declare `minimum_zig_version = "0.16.0"`). It runs the *same* live bridge
as `steam-bridge` — see `src/bridge.zig`, shared by both — just driven
once per rendered frame instead of a sleep loop, so the dashboard and the
headless service can never drift apart. Panels are generated from
`src/controls.zig`'s control list, so the GUI always reflects the actual
current vocabulary (levers plus every British/German/ETCS/cab-basics
control), not a hand-picked subset:

- **Status** — Steam Input/controller state, active loco, profile load
  state.
- **Power & Brake** — live value + mode (absolute/notched/notchless) for
  each of the three levers.
- One tabbed panel per category (Core Cab, British Safety, German Safety,
  ETCS) — each control's label is colored by state: dim if unmapped for
  the current loco, normal if mapped, accent-colored while actively
  pressed.

A sensible default dock layout (Status + Power & Brake on the left,
categories tabbed together on the right) is built automatically the first
time it runs (detected by the absence of `imgui.ini`); once you rearrange
panels, that layout is remembered on subsequent launches the same way
`steam-bridge`'s window layout would be in any other ImGui app.

Runs with zero setup on any platform: `./zig-out/bin/tsw-gui` (or
`tsw-gui.exe` on Windows) alone is enough to see the dashboard. It'll try
to go live automatically too — see "Finding your key file automatically"
below — and falls back to a clearly-labeled preview mode if nothing's
found or Steam isn't running, rather than failing to start. Fonts
(JetBrains Mono, SIL OFL 1.1 — see
`src/assets/fonts/LICENSE-JetBrainsMono.txt`) are embedded directly into
the binary, so there's no font file to find at runtime either.

On Linux, theming reads Omarchy's *current* theme colors live from
`~/.local/state/omarchy/current/theme/colors.toml` at startup (not
hardcoded, so it follows whatever theme is active), mapped onto ImGui's
full `StyleCol` palette; elsewhere it falls back to the same defaults
Omarchy's Coaster theme happens to use. Pass `--theme-file`/`--font-file`
to point at your own files instead, or on Linux use `scripts/run-gui.sh`,
which resolves your current Omarchy font (`omarchy font current` ->
`fc-match`) and launches with it:

```sh
./scripts/run-gui.sh
```

### A real bug worth knowing about if you touch this code

zgui's OpenGL3 backend is compiled with `IMGUI_IMPL_OPENGL_LOADER_CUSTOM`,
which means **you must call `zopengl.loadCoreProfile(...)` before
`zgui.backend.init()`** — otherwise the very first GL call inside ImGui's
init jumps through an uninitialized pointer and segfaults.

Less obviously: once you've loaded zopengl, **never declare your own
`extern fn glViewport`/`glClearColor`/etc.** zopengl `@export`s its *own*
global symbols with those exact names (function-pointer variables it fills
in via `zglfw.getProcAddress`), specifically so C/C++ code expecting to
link against real GL functions gets zopengl's loaded pointers instead. A
second same-named `extern fn` in Zig code doesn't error at link time — the
linker just binds your call to the address of zopengl's pointer *variable*
instead of the function it points to, and it segfaults on first use with a
useless, unwindable-looking backtrace. Call through `zopengl.bindings`
(`const gl = zopengl.bindings; gl.viewport(...)`) instead. This cost a lot
of debugging time; see git history around `gui_main.zig` if it resurfaces.

## Building

Requires Zig 0.16.0+ and the vendored Steamworks SDK (see below). The GUI's
dependencies (zgui/zglfw/zopengl) are fetched automatically by `zig build`.

```sh
zig build            # builds tsw-cli and tsw-gui always; steam-bridge if the SDK is vendored
zig build run-cli -- info --key-file /path/to/CommAPIKey.txt
zig build run-bridge -- --key-file /path/to/CommAPIKey.txt
zig build run-gui                    # or: ./scripts/run-gui.sh
```

### Platform support

Not just an Omarchy thing — this builds for Windows and macOS too:

```sh
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=x86_64-macos
```

| | Linux | Windows | macOS |
|---|---|---|---|
| `tsw-cli` | yes, verified | cross-compiles cleanly | cross-compiles cleanly |
| `steam-bridge` | yes, verified against a real Steam client | cross-compiles cleanly (untested at runtime) | cross-compiles cleanly (untested at runtime) |
| `tsw-gui` | yes, verified | cross-compiles cleanly (untested at runtime) | **doesn't cross-compile from Linux** — zgui's own build script doesn't wire up macOS SDK framework paths for that; should be fine building natively on an actual Mac, just not from here |

Cross-compiling Windows/macOS `steam-bridge`/`tsw-gui` needs `vendor/sdk/`
to contain that platform's redistributable too (`redistributable_bin/win64/`
or `redistributable_bin/osx/`) — already true if you extracted the full
`steamworks_sdk.zip` or pulled via `scripts/fetch-sdk.sh`, since both
include every platform. The build copies the matching `.dll`/`.dylib`
next to the built binary automatically.

Windows/macOS builds are verified by cross-compiling successfully (real
PE32+/Mach-O binaries come out, `zig build test` passes), not by actually
running them on that OS — there's no Windows or macOS machine in this
project's development loop. If something's off at runtime there, it's
likely one of: the Steamworks calling convention/struct packing in
`src/steam/ffi.zig` (should be fine — Zig's `callconv(.c)` picks the
correct ABI per target automatically, and this was written from and
matches the SDK headers directly, not guessed), or something specific to
`zgui`/`zglfw`'s own platform code, which is out of this project's hands.

### Vendoring the Steamworks SDK

If you're the project owner setting up another machine you control, with
SSH access to the private companion repo:

```sh
./scripts/fetch-sdk.sh
```

Otherwise: download `steamworks_sdk.zip` from
<https://partner.steamgames.com/downloads/list> (any Steam account can get
it) and extract it so `vendor/sdk/public/...` and
`vendor/sdk/redistributable_bin/...` exist. `vendor/sdk/` is gitignored in
this (public) repo — it's a large, license-encumbered redistributable,
not project source, so it isn't published here.

### A note on Linux's linker specifically

Zig 0.16.0's self-hosted ELF linker can't yet handle the `.sframe` unwind
sections that current glibc/gcc emit into `crt1.o` (reproduced independent
of this project — any libc-linked Zig binary fails with `fatal linker
error: unhandled relocation type R_X86_64_PC64 ... .sframe` here). The
system linker (via `cc`/`c++`) handles it fine, so on Linux specifically,
`build.zig` builds `steam-bridge` and `tsw-gui` as `.o`/`.a` artifacts
with `zig build-obj` and links the final binaries by shelling out to `cc`
(`c++` for `tsw-gui`, since it links C++ object code from imgui and needs
libstdc++ pulled in) instead of `b.addExecutable`'s normal path. Windows
and macOS don't have this bug (it's specific to this glibc/gcc
combination), so they use Zig's own linker normally via `addExecutable` —
see `needsExternalLinker` in `build.zig`. `tsw-cli` doesn't need libc on
any platform, so it's unaffected everywhere. Revisit the Linux branches
once Zig's linker supports SFrame relocations upstream.

## Workflow

1. Launch TSW with `-HTTPAPI`, get in a cab, note the key file path.
2. `tsw-cli discover --key-file <path>` to build a control-mapping
   skeleton for whatever loco you're in (see `profiles/README.md`). To
   build skeletons for several locomotives without asking someone to run
   this by hand each time, use `scripts/discover-all-locos.sh` instead: it
   loops, discovering whichever loco you're currently in each time you
   press Enter, and skips anything it's already grabbed or that already
   has a hand-curated profile.
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
- `tsw-gui` and `steam-bridge` are two separate processes that each run
  their own independent copy of the live bridge (`src/bridge.zig`) rather
  than one polling the other — running both at once against the same
  controller/profile would have them race each other sending `/set`
  calls. Run one or the other, not both, until there's a reason not to.
  (Docking layout itself *is* persisted between runs — ImGui does that
  automatically via `imgui.ini` in the working directory, which is
  gitignored.)
- `throttle`/`brake`/`combined_power_brake` support both a plain analog
  axis and notched/notchless up-down stepping (see
  `profiles/README.md`); step size is tunable per-profile or globally via
  `steam-bridge --step-size`. We haven't found a TSW API field that
  reports a lever's real notch count, so that's set by hand from testing.
