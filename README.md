# Agentic IDE

A macOS workspace for running agentic command-line tools (Claude Code, Codex,
and friends) project-by-project, instead of juggling them in a generic
terminal emulator.

It's a native SwiftUI app with three panes:

- **Sidebar** — your projects, optionally grouped, with a "Working / Idle"
  indicator that lights up when an agent is actively doing something in any
  of that project's tabs.
- **Workspace** — per-project terminal tabs backed by an embedded
  [Ghostty](https://ghostty.org) surface (truecolor, real PTY, GPU-rendered).
  Sessions persist across launches.
- **Inspector** — git status, recent activity, resource usage.

Each project gets a row of **Quick Launch** buttons. The defaults are
`Run Server`, `Claude`, and `Codex`, and you can add your own. Clicking a
button opens a new tab and runs the command in a login shell rooted at the
project folder, so `claude`, `codex`, `asdf`, `brew`, etc. resolve the way
they do in your normal terminal.

The "Working / Idle" indicator is driven by file-system hooks rather than
terminal escape codes, so it stays accurate even when a tab is in the
background or the project is collapsed in the sidebar.

Other niceties:

- **Speak Selection** (`⌘⇧S`) — sends the active terminal's selection to the
  system speech synth. Useful for long error messages or agent commentary.
- **Drag a folder onto the window** to add it as a project.
- **Sparkle auto-update** — `Agentic IDE → Check for Updates…`.

Requirements: **macOS 14 (Sonoma) or later, Apple Silicon.**

---

## Install (prebuilt)

1. Grab the latest `AgenticIDE-<version>.zip` from the
   [Releases page](https://github.com/ClarkeFL/Agentic-IDE/releases).
2. Unzip and drag `AgenticIDE.app` into `/Applications`.
3. **First launch:** right-click the app → **Open** → confirm the prompt.
   The app is signed with a self-signed certificate (no paid Apple Developer
   account), so Gatekeeper asks once and then remembers. Subsequent updates
   shipped via Sparkle install silently.
4. The first time you open a project that lives under `~/Documents`,
   `~/Desktop`, or `~/Downloads`, macOS will prompt for folder access. Grant
   it once per location. For broader access (the embedded terminal reading
   arbitrary paths via `claude`, `codex`, etc.) the app will offer to walk
   you through enabling **Full Disk Access** in System Settings.

---

## Build from source

### Prerequisites

```bash
brew install xcodegen
xcode-select --install        # if you don't already have command-line tools
```

You also need **Xcode 16** for the toolchain that matches the generated
project.

### Clone + first build

```bash
git clone https://github.com/ClarkeFL/Agentic-IDE.git
cd Agentic-IDE

# One-time: create the self-signed "AgenticIDE Dev" identity used by Debug
# builds. This keeps macOS TCC grants (Documents/Downloads/Full Disk Access)
# stable across rebuilds — without it every clean build looks like a
# different app to TCC and you'd re-prompt every launch.
./Scripts/create-dev-signing-cert.sh

# Generate the .xcodeproj (it's gitignored — project.yml is the source of truth).
xcodegen

# Build.
xcodebuild -project AgenticIDE.xcodeproj \
           -scheme AgenticIDE \
           -configuration Debug build
```

`xcodegen` must be re-run any time `project.yml` changes. The
pre-build script `Scripts/fetch-ghosttykit.sh` will pull a checksum-pinned
`GhosttyKit.xcframework` into `Vendor/` on first build — no manual download.

You can also just open `AgenticIDE.xcodeproj` in Xcode and hit **Run**.

### Run the local Debug build outside Xcode

```bash
pkill -f AgenticIDE; sleep 1
open ~/Library/Developer/Xcode/DerivedData/AgenticIDE-*/Build/Products/Debug/AgenticIDE.app
```

### Reset persisted state

The app stores its project list and per-project tab snapshots under
`~/Library/Application Support/AgenticIDE/`:

```bash
rm ~/Library/Application\ Support/AgenticIDE/projects.json \
   ~/Library/Application\ Support/AgenticIDE/sessions.json
```

If a `PersistentSplitView` change leaves the panes at weird positions:

```bash
defaults delete com.fabio.AgenticIDE "NSSplitView Subview Frames AgenticIDE.MainSplit"
```

---

## Project layout

```
project.yml                   # source of truth — edit this, then run `xcodegen`
AgenticIDE/
  AgenticIDEApp.swift         # @main entry, Sparkle wiring, Speech menu
  Views/                      # SwiftUI views (sidebar, workspace, inspector, …)
  Services/                   # ProjectStore, SessionManager, PtyService,
                              # AgentStatusWatcher, UpdaterManager, …
  Models/                     # Project, ProjectGroup, TerminalTab, QuickLaunch
  Terminal/                   # GhosttyKit bridge (GhosttyTerminalView, …)
Scripts/
  fetch-ghosttykit.sh         # pulls Vendor/GhosttyKit.xcframework
  create-dev-signing-cert.sh  # one-time self-signed identity for Debug
  create-release-signing-cert.sh
  release.sh                  # tag origin/main and push
  update-appcast.sh           # used by the release workflow
.github/workflows/release.yml # tag-push triggered build/sign/release
appcast.xml                   # Sparkle feed (committed by CI)
docs/release-setup.md         # one-time release infrastructure setup
CLAUDE.md                     # working notes (git workflow, release runbook)
```

Both `AgenticIDE.xcodeproj/` and `Vendor/GhosttyKit.xcframework/` are
gitignored — the project file is regenerated from `project.yml`, and the
xcframework is fetched by a checksum-pinned tarball at build time. Don't
edit either by hand.

---

## Releasing

The full release runbook lives in [`CLAUDE.md`](./CLAUDE.md) and one-time
infrastructure setup is in [`docs/release-setup.md`](./docs/release-setup.md).
Short version: merge `dev` → `main` via PR, then from `dev` run

```bash
./Scripts/release.sh X.Y.Z
```

which tags `origin/main` and pushes it. The
[`release.yml`](./.github/workflows/release.yml) workflow takes over from
there: builds, signs with the `AgenticIDE Release` identity, signs the zip
with Sparkle's Ed25519 key, updates `appcast.xml`, and publishes a GitHub
Release.

---

## License

No license file yet — treat this as source-available for inspection until
one is added.
