#!/usr/bin/env bash
# Launches tsw-gui using whatever font Omarchy is currently set to, so the
# dashboard's font follows your system font without gui_main.zig needing to
# know anything about Omarchy or fontconfig itself.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

font_file="$(fc-match -f '%{file}' "$(omarchy font current)")"

exec ./zig-out/bin/tsw-gui --font-file "$font_file" "$@"
