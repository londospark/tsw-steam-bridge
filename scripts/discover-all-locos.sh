#!/usr/bin/env bash
# Repeatedly runs `tsw-cli discover` as you sit in each locomotive in turn,
# so building profile skeletons for every train you own doesn't mean
# asking someone to run it by hand, one locomotive at a time.
#
# TSW's API only ever exposes whatever locomotive is currently in the
# driver's seat (CurrentDrivableActor) -- there's no endpoint to list or
# switch locomotives from outside the game, so this genuinely can't run
# unattended. What it removes is the "ask Claude to run discover again"
# step: get in a cab in-game, press Enter here, get in the next one, press
# Enter again, and so on until you've covered everything you want a
# skeleton for.
#
# Skips locomotives it's already grabbed this run, and skips (without
# overwriting) any profile that already looks hand-curated -- a
# non-skeleton profile always has a non-empty "displayName", which
# `tsw-cli discover` never sets, so that's used as the "don't clobber
# this" signal.
#
# Requires jq and a built tsw-cli (`zig build`). Any arguments you pass
# are forwarded to `tsw-cli` as-is (e.g. `--key-file /path/to/CommAPIKey.txt`
# or `--base-url` if you need to override auto-discovery).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

cli=./zig-out/bin/tsw-cli
if [ ! -x "$cli" ]; then
    echo "tsw-cli not built yet -- run 'zig build' first." >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "this script needs jq (used to read the current locomotive's ObjectClass)." >&2
    exit 1
fi

cli_args=("$@")
seen=()

was_seen() {
    local needle="$1"
    for s in "${seen[@]:-}"; do
        [ "$s" = "$needle" ] && return 0
    done
    return 1
}

echo "Get in a locomotive's cab in TSW, then press Enter here to grab it."
echo "Type 'q' then Enter (or Ctrl+C) once you've covered every train you want."
echo

while true; do
    read -r -p "> " line || break
    if [ "$line" = "q" ] || [ "$line" = "quit" ]; then
        break
    fi

    raw_output="$("$cli" "${cli_args[@]}" get CurrentDrivableActor.ObjectClass 2>&1)" || {
        echo "couldn't reach TSW -- is it running with -HTTPAPI?"
        echo "$raw_output" | tail -3
        continue
    }
    object_class="$(echo "$raw_output" | tail -1 | jq -r '.Values.ObjectClass // empty' 2>/dev/null || true)"

    if [ -z "$object_class" ]; then
        echo "couldn't read the current locomotive's ObjectClass -- get in a cab first."
        continue
    fi

    if was_seen "$object_class"; then
        echo "$object_class: already grabbed this run, skipping."
        continue
    fi

    profile_path="profiles/${object_class}.json"
    if [ -f "$profile_path" ]; then
        display_name="$(jq -r '.displayName // ""' "$profile_path" 2>/dev/null || true)"
        if [ -n "$display_name" ]; then
            echo "$object_class: $profile_path already has a real displayName (\"$display_name\") -- looks hand-curated, skipping."
            echo "  (delete it first if you really want to regenerate it from scratch)"
            seen+=("$object_class")
            continue
        fi
    fi

    echo "discovering $object_class..."
    "$cli" "${cli_args[@]}" discover
    seen+=("$object_class")
    echo "-> get in the next locomotive and press Enter, or 'q' to stop."
done

echo
echo "done. locomotives handled this run: ${#seen[@]}"
for s in "${seen[@]:-}"; do
    echo "  - profiles/${s}.json"
done
