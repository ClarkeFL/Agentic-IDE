# Agentic IDE — Design Spec

**Status:** Draft, ready for implementation planning
**Date:** 2026-04-27
**Author:** Fabio (with Claude)
**Target platform:** macOS 14+ (built and run on macOS 26)

---

## Goal

A single-user macOS app for running and supervising multiple terminal-based AI coding agents (Claude, Codex) and project servers across multiple project folders, with a live file tree and git diff view always visible alongside the active terminal.

The app embeds the real Ghostty terminal (via `GhosttyKit.xcframework`) for terminal panes — no homegrown terminal emulator. It is, in spirit, a focused project-switching wrapper around Ghostty + a file/git inspector.

## Non-goals (v1)

- **No splits within a tab.** Tabs only. Splits are a deliberate v2 feature so the data model is split-ready, but the v1 UI exposes only tabs.
- **No PTY restoration across app quits.** Tabs respawn empty after a relaunch; `projects.json` and per-project `QuickLaunch` lists persist, the running PTYs do not.
- **No code editor.** The right column shows a file tree and a git diff, nothing else. Editing happens in `$EDITOR` from within a terminal tab.
- **No UI git operations.** No commit / push / pull buttons. Diff *view* only. Use a terminal tab for any git command.
- **No multi-window.** Single window, multiple projects via the sidebar.
- **No SSH / remote terminals.** Local PTY only.
- **No themes beyond Ghostty's built-in light/dark + macOS appearance.**

## Stack

| Layer | Choice |
|---|---|
| Language | Swift 5.10 |
| UI | SwiftUI for layout/state, AppKit (`NSViewRepresentable`) for the Ghostty surface and any SwiftUI gaps |
| Terminal | `GhosttyKit.xcframework` (vendored from a checksum-pinned release tarball) |
| Build | Xcode 16, single-target macOS app |
| Min macOS | 14.0 (Sonoma) |
| Arch | Apple Silicon (`arm64`) primary; universal binary if cheap |

Why Swift over Rust: Ghostty's embedding API (`libghostty` / `GhosttyKit.xcframework`) is C-API-first with mature Swift bindings; cmux is the proven reference implementation in Swift. Rust bindings (`libghostty-rs`) only cover the VT-parser subset, not the renderer, so a Rust host would have to write substantial new FFI plus its own Metal renderer — far more work than the Swift path, with no win on RAM or speed.

## Layout

Three-region `NavigationSplitView`:

```
┌──────────────┬──────────────────────────────────┬──────────────┐
│  PROJECTS    │  ╭ Run Server ╮ Claude  Codex  + │  FILES       │
│              │  ╰────────────╯                  │  ▸ src       │
│ ◆ Agentic-IDE│                                  │    App.swift │
│   $ swift run│  ┌────────────────────────────┐  │  ▸ Sources   │
│   2m         │  │                            │  │              │
│              │  │   (Ghostty terminal pane)  │  │  ─────────── │
│   relist_ebay│  │                            │  │  GIT DIFF    │
│   $ npm run  │  │                            │  │              │
│   1m         │  │                            │  │  M  App.swift│
│              │  │                            │  │  + 12  -3    │
│   flippedit  │  └────────────────────────────┘  │              │
│   No activity│                                  │  ?  newfile  │
│              │                                  │              │
│  + Add       │                                  │              │
└──────────────┴──────────────────────────────────┴──────────────┘
```

- **Left sidebar** (~240pt, `⌘B` to toggle): project list. Each row shows project name, last command + relative timestamp, archive button on hover. `+ Add Project` at the bottom opens a folder picker. Drag-drop a folder onto the window also adds it. Active project is highlighted.
- **Middle pane** (flexible): tab bar at top — `Run Server`, `Claude`, `Codex`, any per-project custom buttons, `+`. Active terminal below. When `tabs.isEmpty`, a centered prompt: *"Click Run Server, Claude, Codex, or + to start a terminal."*
- **Right sidebar** (~280pt, `⌘⌥B` to toggle): file tree on top half, git diff on bottom half, draggable horizontal divider between them. File tree is a recursive `OutlineGroup` rooted at the project path, decorated with git status colors (green=new/untracked, yellow=modified, red=deleted). Click a file → bottom half shows `git diff -- <path>` rendered as a unified diff.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘1` … `⌘9` | Switch to tab 1–9 |
| `⌘W` | Close current tab |
| `⌘T` | New default-shell tab (same as `+`) |
| `⌘⇧[` / `⌘⇧]` | Switch project (prev / next) |
| `⌘N` | Add project (folder picker) |
| `⌘,` | Settings |
| `⌘B` | Toggle left sidebar |
| `⌘⌥B` | Toggle right sidebar |

## Data model

```swift
struct Project: Identifiable, Codable {
    let id: UUID
    var name: String                  // derived from folder, editable
    var path: URL                     // absolute project root
    var quickLaunches: [QuickLaunch]  // tab-bar buttons (excluding "+")
    var lastActivityAt: Date?
    var lastActivityCommand: String?  // shown in sidebar preview
    var archived: Bool = false
}

struct QuickLaunch: Identifiable, Codable {
    let id: UUID
    var label: String                 // "Run Server", "Claude", "Codex", custom
    var command: String               // shell command; empty = prompt on first click
    var icon: String?                 // optional SF Symbol name
    var isBuiltin: Bool               // true for seeded defaults; built-ins can be edited but not deleted, custom ones can be deleted
}

@Observable final class TerminalTab {
    let id: UUID
    var title: String
    var command: String?              // nil → default login shell
    var surface: GhosttySurface       // owned wrapper around ghostty_surface_t
    var createdAt: Date
    var isRunning: Bool
}

@Observable final class ProjectSession {
    let project: Project
    var tabs: [TerminalTab] = []
    var activeTabId: UUID?
    var selectedFile: URL?
    var fileTree: FileNode
    var gitStatus: [URL: GitFileStatus] = [:]
}

struct FileNode: Identifiable {
    let id: URL
    let url: URL
    var name: String
    var isDirectory: Bool
    var children: [FileNode]?         // nil = unloaded; [] = empty/ leaf
}

enum GitFileStatus { case untracked, modified, added, deleted, renamed, conflicted }
```

### Seeded built-ins on project creation

| Label | command | isBuiltin |
|---|---|---|
| Run Server | `""` (empty — prompts on first click) | true |
| Claude | `claude` | true |
| Codex | `codex` | true |

`+` is a synthetic always-present button, not a stored `QuickLaunch`. It opens a default login shell (`$SHELL -l` or `/bin/zsh -l` if unset).

### "Run Server" first-click flow

When the user clicks "Run Server" and its `command` is empty, show an inline popover anchored to the button: *"Set the command for this project's Run Server"* + a text field + Save. On save, write the command into the project's `QuickLaunch`, persist, then immediately spawn the tab.

## Components

```
AgenticIDEApp
└─ MainWindow
   └─ NavigationSplitView (3-column)
      ├─ ProjectSidebarView          ← project list, + Add, drag-drop target
      ├─ ProjectWorkspaceView        ← per-project; reads from current ProjectSession
      │   ├─ TabBarView              ← QuickLaunch buttons + open tabs + close × per tab
      │   └─ TabContentView
      │       ├─ EmptyStateView      ← shown when tabs.isEmpty
      │       └─ TerminalPaneView    ← NSViewRepresentable(GhosttySurfaceView)
      └─ RightInspectorView
          ├─ FileTreeView            ← OutlineGroup over FileNode, decorated w/ git status
          └─ GitDiffView             ← unified-diff renderer for selectedFile
```

Plus `SettingsScene` (`⌘,`) — global font, theme (system / light / dark), default shell path, GhosttyKit version info, "Reveal projects.json in Finder" debug button.

## Services

| Service | Job |
|---|---|
| `ProjectStore` | Loads/saves `projects.json`. Publishes `[Project]`. Handles add/remove/rename/reorder/archive. Atomic writes. |
| `SessionManager` | Maps `Project.id → ProjectSession`. Lazy-creates on first activation, retains until app quit. Switching projects is a dictionary lookup, no I/O. |
| `GhosttyManager` | Owns the `ghostty_app_t`. Creates/destroys `ghostty_surface_t` instances. Wraps the C API in Swift. One per app. Main-thread-only. |
| `PtyService` | Resolves a `QuickLaunch` (or "+") into argv + cwd + env, hands it to `GhosttyManager` for surface creation. GhosttyKit handles the actual PTY spawn. |
| `FileWatcher` | One `DispatchSource` per active project root. Coalesces FSEvents (~50ms debounce), emits change events for `FileTreeView` and `GitService`. |
| `GitService` | Shells out to `/usr/bin/git` for `status --porcelain=v2 --branch` and `diff --no-color -- <file>`. Parses results. Throttled to ~250ms after FSEvent bursts. |

All services are app singletons injected into views via `@Environment` and observed via Swift's `@Observable` macro.

## Ghostty integration

Following the cmux pattern (verified working reference: `manaflow-ai/cmux`, `Sources/GhosttyTerminalView.swift`):

1. **Vendor `GhosttyKit.xcframework`** from a checksum-pinned release tarball. Drop a `Scripts/fetch-ghosttykit.sh` script that downloads + verifies SHA256 and unpacks into `Vendor/GhosttyKit.xcframework`. Linked as a binary framework in Xcode, *not* built from source.
2. **App init.** `GhosttyManager.init()` calls `ghostty_config_new()`, applies our config (font, theme, scrollback size), then `ghostty_app_new(cfg, callbacks)`. Callbacks are `@convention(c)` closures bridged via a context pointer back to `GhosttyManager`.
3. **Per-tab surface.** `GhosttyManager.makeSurface(argv:cwd:env:)` calls `ghostty_surface_new(app, surfaceCfg)` and returns a `GhosttySurface` wrapper. Each `TerminalTab` owns one surface.
4. **Rendering.** `GhosttySurfaceView` is an `NSViewRepresentable` whose backing `NSView` subclass has a `CAMetalLayer` backing layer. Ghostty's Metal renderer draws into it directly. We override `acceptsFirstResponder`, `keyDown(with:)`, `mouseDown(with:)`, `scrollWheel(with:)`, `resizeSubviews(withOldSize:)`, and the IME methods to forward events to the surface via `ghostty_surface_*` calls. Adapted from cmux's `GhosttyTerminalView.swift` — we translate, not reinvent.
5. **Lifecycle.** On surface close (process exits or user closes tab): `ghostty_surface_free()`, remove from `tabs`. On app quit: free all surfaces, then `ghostty_app_free()`.

GhosttyKit handles the PTY spawn (we pass argv + cwd + env), ANSI parsing, scrollback, selection, link detection, and rendering. We are not writing terminal-emulator code.

### Open question

The exact Ghostty config knobs we want to surface in our Settings UI (font family/size, theme, scrollback, cursor style) need to be confirmed against the GhosttyKit version we vendor. Defer to implementation time.

## Persistence

| What | Where | Format |
|---|---|---|
| Projects + their QuickLaunches | `~/Library/Application Support/AgenticIDE/projects.json` | JSON via `Codable`, atomic write |
| App settings (window size, font, theme, sidebar widths, last active project) | `~/Library/Preferences/com.fabio.AgenticIDE.plist` | `@AppStorage` / `UserDefaults` |
| Per-tab state (PTY, scrollback, output) | Not persisted | Ephemeral; respawn empty after relaunch |
| File tree, git status, git diff | Not persisted | Always live from disk |

## Threading

- **Main actor:** all SwiftUI views, AppKit views, Ghostty surface API calls (`ghostty_surface_*` is documented as main-thread-only).
- **Background dispatch queues:** `GitService` (`git` subprocesses), `FileWatcher` callbacks, `ProjectStore` disk writes. Results bounce back to `MainActor` for UI updates.

## User flows

### Add project

1. Sidebar `+ Add Project` (or drag-drop a folder onto the window, or `⌘N`).
2. `NSOpenPanel` (folder mode); rejects non-folders.
3. Create `Project` with `id = UUID()`, `name = path.lastPathComponent`, seeded `QuickLaunches`.
4. `ProjectStore.add(project)` → save `projects.json`.
5. Activate the project. `SessionManager` creates an empty `ProjectSession`. Middle pane shows empty state.

### Click "Claude" (configured QuickLaunch)

1. Resolve `QuickLaunch.command = "claude"`.
2. `PtyService.spawn` → builds argv `[$SHELL, "-l", "-c", "claude"]`, env from process env, cwd from `project.path`.
3. `GhosttyManager.makeSurface(argv:cwd:env:)` returns a `GhosttySurface`.
4. Create `TerminalTab` wrapping the surface, append to `session.tabs`, set `activeTabId`.
5. Update `project.lastActivityCommand = "claude"`, `lastActivityAt = .now`. Persist.

### Click "Run Server" with empty command

1. Inline popover anchored to button: text field + Save.
2. On Save, write into the project's `QuickLaunch`, persist, then proceed as the "Click Claude" flow with the new command.

### Switch project

1. Click a project in the sidebar.
2. `currentProjectId` updates → `SessionManager` returns existing `ProjectSession` (or creates one).
3. Right-column `FileWatcher` and `GitService` switch to the new project root (kill old watcher, start new).
4. Existing terminals in other projects keep running silently in the background — they are not paused or killed.

### Select file in tree

1. `selectedFile = url`.
2. `GitDiffView` runs `git -C <project.path> diff --no-color -- <relative-path>` (or `git diff --no-index /dev/null <file>` for untracked) on a background queue.
3. Parse unified diff into hunks of `+` / `-` / context lines. Render with monospace font, green / red / default colors.

### App quit

1. Send `SIGHUP` to all child PTY processes (Ghostty handles this on `ghostty_surface_free`).
2. Free all surfaces, then `ghostty_app_free()`.
3. Save `projects.json` if dirty.
4. No tab restoration on next launch — projects and quick-launches persist, terminals do not.

## Settings UI (`⌘,`)

| Setting | Default | Notes |
|---|---|---|
| Font family | Ghostty default ("JetBrains Mono" if available else system mono) | Resolved at app launch |
| Font size | 13 pt | |
| Theme | System | System / Light / Dark |
| Default shell | `$SHELL` | Falls back to `/bin/zsh` |
| Scrollback lines | 10000 | Per-surface |
| Reveal `projects.json` | — | Debug button |
| GhosttyKit version | — | Read-only display |

Per-project settings (custom QuickLaunches, rename project, change path, archive) live in a per-project context menu in the sidebar, not in the global Settings window.

## Module layout (proposed)

```
AgenticIDE/
├─ AgenticIDE.xcodeproj
├─ Sources/
│  ├─ App/
│  │  ├─ AgenticIDEApp.swift
│  │  └─ MainWindow.swift
│  ├─ Projects/
│  │  ├─ Project.swift
│  │  ├─ QuickLaunch.swift
│  │  ├─ ProjectStore.swift
│  │  └─ ProjectSidebarView.swift
│  ├─ Sessions/
│  │  ├─ ProjectSession.swift
│  │  ├─ SessionManager.swift
│  │  └─ TerminalTab.swift
│  ├─ Workspace/
│  │  ├─ ProjectWorkspaceView.swift
│  │  ├─ TabBarView.swift
│  │  ├─ TabContentView.swift
│  │  └─ EmptyStateView.swift
│  ├─ Terminal/
│  │  ├─ GhosttyManager.swift
│  │  ├─ GhosttySurface.swift
│  │  ├─ GhosttySurfaceView.swift   ← NSViewRepresentable
│  │  ├─ GhosttyNSView.swift        ← NSView + CAMetalLayer
│  │  └─ PtyService.swift
│  ├─ Inspector/
│  │  ├─ RightInspectorView.swift
│  │  ├─ FileTreeView.swift
│  │  ├─ FileNode.swift
│  │  ├─ FileWatcher.swift
│  │  ├─ GitDiffView.swift
│  │  └─ GitService.swift
│  └─ Settings/
│     ├─ SettingsScene.swift
│     └─ AppSettings.swift
├─ Vendor/
│  └─ GhosttyKit.xcframework        ← gitignored, fetched by script
├─ Scripts/
│  └─ fetch-ghosttykit.sh
└─ docs/
   └─ superpowers/specs/
      └─ 2026-04-27-agentic-ide-design.md  ← this file
```

## Risks & open questions

- **GhosttyKit API drift.** The Ghostty C API is documented but evolving. We pin to a specific release SHA and update deliberately. Mitigated by following cmux's working integration as our reference.
- **Surface lifecycle bugs.** Forgetting to `ghostty_surface_free` leaks Metal resources; freeing too early crashes. Plan to wrap surface creation/destruction in a Swift class with `deinit` ownership and a unit test that creates/destroys 100 surfaces in a loop.
- **`git status --porcelain=v2` for very large repos.** Could be slow on a multi-GB monorepo. Acceptable for v1; can add a "pause git inspector" toggle if it bites.
- **PATH inside spawned terminals.** Spawning via `$SHELL -l -c "<cmd>"` runs the user's login init files so PATH matches their normal terminal. Verify this works for `claude` / `codex` installed via brew/npm/asdf etc. on first integration test.
- **Drag-drop folder onto window vs onto Dock icon.** Both should work. macOS handles Dock-icon drop via `NSApplicationDelegate.application(_:openURLs:)`; window drop via `.onDrop(of: [.fileURL], …)`.

## Success criteria for v1

- Add a project from a folder picker; it appears in the sidebar and persists across app quits.
- Click `+` in a project → a working `zsh` terminal pane appears in the project's cwd.
- Click `Claude` → a Ghostty pane opens running `claude` in the project's cwd; output renders correctly; keyboard input works including arrow keys, IME, and `⌘C`/`⌘V`.
- Configure `Run Server` for a project → click it → server runs; output streams correctly.
- Open multiple tabs in one project, switch between them with `⌘1/⌘2/...`, close with `⌘W`.
- Switch projects via the sidebar — terminals from the previous project keep running, the right column re-roots to the new project's files.
- File tree shows the project's files with correct git status colors; FSEvents updates the tree within ~500ms of a change.
- Click a modified file → unified diff renders correctly with `+` / `-` / context lines.
- Cold-start RAM with 3 idle terminals: under ~150 MB.
- App quits cleanly (no zombie PTYs, no Metal warnings).
