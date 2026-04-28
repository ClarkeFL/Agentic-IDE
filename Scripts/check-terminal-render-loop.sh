#!/usr/bin/env bash
set -euo pipefail

source_path="${1:-AgenticIDE/Terminal}"

require() {
  local pattern="$1"
  local message="$2"
  if ! grep -REq "$pattern" "$source_path"; then
    echo "terminal render loop check failed: $message" >&2
    exit 1
  fi
}

require 'private var tickTimer: Timer\?' 'GhosttyApp must own a periodic tick timer.'
require 'Timer\(timeInterval: 1\.0 / 60\.0, repeats: true\)' 'GhosttyApp must pump ghostty_app_tick at display cadence.'
require 'RunLoop\.main\.add\(timer, forMode: \.common\)' 'The tick timer must run in common run-loop modes.'
require 'tickTimer\?\.invalidate\(\)' 'GhosttyApp.shutdown must invalidate the tick timer.'
require 'drawSurface\(\)' 'GHOSTTY_ACTION_RENDER must present the CAMetalLayer via ghostty_surface_draw.'
require 'ghostty_surface_draw\(surface\)' 'GhosttyTerminalView must expose a draw path for render actions.'
require 'ghostty_surface_set_occlusion\(surface, !occluded\)' 'setOccluded must pass Ghostty the visible flag, not the occluded flag.'

echo "terminal render loop check passed"
