#!/usr/bin/env bash
set -euo pipefail

pty_path="${1:-AgenticIDE/Services/PtyService.swift}"
ghostty_app_path="${2:-AgenticIDE/Terminal/GhosttyApp.swift}"
ghostty_view_path="${3:-AgenticIDE/Terminal/GhosttyTerminalView.swift}"
session_path="${4:-AgenticIDE/Services/SessionManager.swift}"

require_in_file() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "terminal color config check failed: $message" >&2
    exit 1
  fi
}

require_in_file "$pty_path" 'terminalEnvironment\(\)' 'PtyService must centralize terminal environment defaults.'
require_in_file "$pty_path" '"COLORTERM": "truecolor"' 'Terminal sessions must advertise truecolor support to color-aware CLIs.'
require_in_file "$pty_path" '"CLICOLOR": "1"' 'Terminal sessions must enable color for macOS/BSD command-line tools.'
require_in_file "$pty_path" '"TERM_PROGRAM": "AgenticIDE"' 'Terminal sessions must identify the embedding terminal program.'
require_in_file "$pty_path" 'unset NO_COLOR' 'Terminal command wrappers must remove inherited NO_COLOR so CLIs are allowed to emit color.'
require_in_file "$pty_path" 'commandEnsuringTerminalBootstrap' 'PtyService must migrate restored commands to strip inherited NO_COLOR.'
require_in_file "$pty_path" 'env: terminalEnvironment\(\)' 'New terminal sessions must receive the terminal environment defaults.'
require_in_file "$session_path" 'PtyService\.commandEnsuringTerminalBootstrap\(tabSnap\.command\)' 'Restored terminal commands must be migrated through the terminal bootstrap.'
require_in_file "$session_path" 'env: PtyService\.terminalEnvironment\(\)' 'Restored terminal sessions must receive the same terminal environment defaults.'
require_in_file "$ghostty_app_path" 'configureGhosttyResourcesEnvironment\(\)' 'GhosttyApp must configure GHOSTTY_RESOURCES_DIR before ghostty_init.'
require_in_file "$ghostty_app_path" 'setenv\("GHOSTTY_RESOURCES_DIR"' 'GhosttyApp must expose the Ghostty resources directory to libghostty.'
require_in_file "$ghostty_app_path" 'ghostty_app_set_color_scheme' 'GhosttyApp must initialize libghostty with the current macOS color scheme.'
require_in_file "$ghostty_view_path" 'metalLayer\.isOpaque = false' 'Ghostty CAMetalLayer must allow Ghostty to own its terminal background compositing.'
require_in_file "$ghostty_view_path" 'ghostty_surface_set_color_scheme' 'Ghostty surfaces must track macOS light/dark appearance.'

echo "terminal color config check passed"
