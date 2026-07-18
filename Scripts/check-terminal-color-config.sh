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
# Claude Code only enables full color for a short TERM_PROGRAM allowlist
# (ghostty, iTerm.app, …). We embed Ghostty, so advertise that — not AgenticIDE.
require_in_file "$pty_path" '"TERM_PROGRAM": "ghostty"' 'Terminal sessions must advertise as ghostty so Claude/Ink enable truecolor.'
require_in_file "$pty_path" '"AGENTIDE": "1"' 'Terminal sessions must still identify AgenticIDE via AGENTIDE=1.'
require_in_file "$pty_path" 'unset NO_COLOR' 'Terminal command wrappers must remove inherited NO_COLOR so CLIs are allowed to emit color.'
require_in_file "$pty_path" 'FORCE_COLOR-.*" = 0' 'Terminal bootstrap must drop FORCE_COLOR=0 (chalk hard-monochrome).'
require_in_file "$pty_path" 'commandEnsuringTerminalBootstrap' 'PtyService must migrate restored commands to strip inherited monochrome kill-switches.'
require_in_file "$pty_path" 'env: terminalEnvironment\(\)' 'New terminal sessions must receive the terminal environment defaults.'
require_in_file "$session_path" 'PtyService\.commandEnsuringTerminalBootstrap\(' 'Restored terminal commands must be migrated through the terminal bootstrap.'
require_in_file "$session_path" 'env: PtyService\.terminalEnvironment\(\)' 'Restored terminal sessions must receive the same terminal environment defaults.'
require_in_file "$ghostty_app_path" 'configureGhosttyResourcesEnvironment\(\)' 'GhosttyApp must configure GHOSTTY_RESOURCES_DIR before ghostty_init.'
require_in_file "$ghostty_app_path" 'setenv\("GHOSTTY_RESOURCES_DIR"' 'GhosttyApp must expose the Ghostty resources directory to libghostty.'
require_in_file "$ghostty_app_path" 'ghostty_app_set_color_scheme' 'GhosttyApp must initialize libghostty with the current macOS color scheme.'
require_in_file "$ghostty_app_path" 'scrubInheritedMonochromeEnvironment\(\)' 'GhosttyApp must scrub inherited monochrome kill-switches before surfaces spawn.'
require_in_file "$ghostty_app_path" 'unsetenv\("NO_COLOR"\)' 'GhosttyApp must unset process-level NO_COLOR.'
require_in_file "$ghostty_app_path" 'FORCE_COLOR' 'GhosttyApp must scrub FORCE_COLOR=0 inherited from agent harnesses.'
# Do not force color on globally — CLIs keep their own themes (Grok, etc.).
# Only active code paths count; legacy bootstrap *strings* used for migration may mention FORCE_COLOR.
if grep -Eq '"FORCE_COLOR":|"CLICOLOR_FORCE":' "$pty_path"; then
  echo "terminal color config check failed: PtyService must not force FORCE_COLOR/CLICOLOR_FORCE on every CLI." >&2
  exit 1
fi
# Match bare setenv only — unsetenv("FORCE_COLOR") is the kill-switch scrub.
if grep -Eq '(^|[^[:alnum:]_])setenv\("FORCE_COLOR"|(^|[^[:alnum:]_])setenv\("CLICOLOR_FORCE"' "$ghostty_app_path"; then
  echo "terminal color config check failed: GhosttyApp must not force FORCE_COLOR/CLICOLOR_FORCE on the process." >&2
  exit 1
fi
require_in_file "$ghostty_view_path" 'ghostty_surface_set_color_scheme' 'Ghostty surfaces must track macOS light/dark appearance.'

echo "terminal color config check passed"
