#!/usr/bin/env bash
# scripts/sound-latency.sh — press-to-sound for Wax's play/pause, next and previous (#679).
#
#   scripts/sound-latency.sh [--pid <Wax pid>] [--rounds N] [--only pause,resume,next,previous]
#
# Start Wax (any build) and play a playlist first. The tool presses Space, ⇧⌘→ and ⇧⌘← in that
# Wax and times, from each press, when the Mac's audio output goes silent or sounds again. It
# hears the output before volume and mute, so the Mac can stay muted. See docs/latency.md.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/sound-latency
BIN="$OUT/sound-latency"
SRC=scripts/sound-latency/main.swift
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    mkdir -p "$OUT"
    swiftc -O -suppress-warnings "$SRC" -o "$BIN"
fi

args=("$@")
if [[ " ${args[*]-} " != *" --pid "* ]]; then
    pid=$(pgrep -x Wax | head -1 || true)
    [ -n "$pid" ] || { echo "sound-latency: Wax isn't running; start it and play a playlist" >&2; exit 1; }
    args+=(--pid "$pid")
fi
exec "$BIN" "${args[@]}"
