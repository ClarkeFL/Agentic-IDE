import Darwin
import Foundation
import OSLog

/// Local control channel that lets an agent running in one workspace cell
/// drive and observe its sibling cells. The app listens on a Unix-domain
/// socket; a tiny `agentide` helper (auto-added to each cell's PATH) speaks a
/// trivial line protocol to it:
///
///   `<verb> <surfaceId> [cell]\n[text]`  →  plain-text response
///
/// Requests are resolved against the live workspace grid by `CellBus`, scoped
/// to the caller's own workspace.
final class AgentBridge {
    static let shared = AgentBridge()

    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "AgentBridge")
    private var started = false
    private var cellBus: CellBus?
    private var listenFD: Int32 = -1

    private init() {}

    // MARK: - Well-known paths

    static var directoryURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        // Namespace the control socket + helper by bundle id so a dev build
        // (com.fabio.AgenticIDE.dev) and the release build don't share — and
        // fight over — one agentide.sock. Whichever launched second used to
        // unlink() the other's socket on startup, silently breaking every
        // orchestrated cell in the first instance. The App Support root stays
        // "AgenticIDE" so projects.json/sessions.json remain shared as before.
        let bundleId = Bundle.main.bundleIdentifier ?? "com.fabio.AgenticIDE"
        return base.appendingPathComponent("AgenticIDE", isDirectory: true)
                   .appendingPathComponent(bundleId, isDirectory: true)
    }
    static var socketURL: URL { directoryURL.appendingPathComponent("agentide.sock") }
    static var binDirectoryURL: URL { directoryURL.appendingPathComponent("bin", isDirectory: true) }
    static var helperURL: URL { binDirectoryURL.appendingPathComponent("agentide") }

    // MARK: - Lifecycle

    /// Idempotent. Wires the session manager (so cells can be resolved), writes
    /// the helper script, and starts the listener once.
    func start(sessions: SessionManager, store: ProjectStore, launchTools: LaunchToolStore) {
        if started {
            cellBus?.sessions = sessions
            cellBus?.store = store
            cellBus?.launchTools = launchTools
            return
        }
        started = true
        cellBus = CellBus(sessions: sessions, store: store, launchTools: launchTools)
        writeHelperScript()
        openSocket()
    }

    // MARK: - Helper script

    private func writeHelperScript() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.binDirectoryURL, withIntermediateDirectories: true)
        let script = Self.helperScript(socketPath: Self.socketURL.path)
        do {
            try script.write(to: Self.helperURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.helperURL.path)
        } catch {
            log.error("Failed to write agentide helper: \(error.localizedDescription)")
        }
    }

    private static func helperScript(socketPath: String) -> String {
        // Pure bash + nc so there are no extra runtime deps. `nc -U -N` connects
        // to the unix socket, sends stdin, half-closes, then prints the reply.
        """
        #!/bin/bash
        # AgenticIDE cell bridge. Control & observe the other cells in your workspace.
        sock="${AGENTIDE_SOCK:-\(socketPath)}"
        sid="$AGENTIDE_SURFACE_ID"
        if [ -z "$sid" ]; then
          echo "agentide: not running inside an AgenticIDE cell" >&2; exit 1
        fi

        usage() {
          cat >&2 <<'USAGE'
        Build out & orchestrate the other cells in your workspace.
          agentide cells              List cells (number, what's running, status).
          agentide tools              List the launchers you can start (claude, codex, ...).
          agentide grid <rows> <cols> Resize to a uniform grid (max 8 cells), or
          agentide grid rows|cols <n>... Uneven layout: groups along the axis,
                                      e.g. 'grid cols 1 2' = tall left + 2 stacked.
          agentide launch <n> <tool>  Launch <tool> in cell <n>.
          agentide close <n>          Close the program in cell <n>.
          agentide send <n> <text>    Type <text> into cell <n> and press Enter.
          agentide read <n>           Print cell <n>'s screen, to review its progress.
          agentide status <n>         Print cell <n>'s status (idle/working/completed/failed).
          agentide wait <n> [secs]    Block until cell <n> finishes (default 600s).
        USAGE
        }

        req() { # req <header> [text]; 0x04 terminates the request so plain nc works
          { printf '%s\\n%s' "$1" "${2-}"; printf '\\004'; } | nc -U "$sock"
        }

        cmd="$1"; [ $# -gt 0 ] && shift
        case "$cmd" in
          cells)  req "cells $sid" ;;
          tools)  req "tools $sid" ;;
          read)   req "read $sid $1" ;;
          status) req "status $sid $1" ;;
          close)  req "close $sid $1" ;;
          grid)   req "grid $sid $*" ;;
          send)   n="$1"; shift; req "send $sid $n" "$*" ;;
          launch) n="$1"; shift; req "launch $sid $n" "$*" ;;
          wait)
            n="$1"; secs="${2:-600}"; deadline=$(( $(date +%s) + secs ))
            while :; do
              st=$(req "status $sid $n")
              case "$st" in completed*|failed*|empty*) echo "$st"; exit 0 ;; esac
              [ "$(date +%s)" -ge "$deadline" ] && { echo "timeout"; exit 0; }
              sleep 2
            done ;;
          *) usage; exit 1 ;;
        esac
        """
    }

    // MARK: - Socket

    private func openSocket() {
        let path = Self.socketURL.path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log.error("socket() failed: \(errno)"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    for i in 0..<min(src.count, 104) { dst[i] = src[i] }
                }
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindResult == 0 else {
            log.error("bind() failed: \(errno)"); close(fd); return
        }
        guard listen(fd, 8) == 0 else {
            log.error("listen() failed: \(errno)"); close(fd); return
        }

        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        thread.name = "com.fabio.AgenticIDE.AgentBridge"
        thread.stackSize = 512 * 1024
        thread.start()
        log.info("Agent bridge listening at \(path, privacy: .public)")
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            handleConnection(client)
            close(client)
        }
        close(fd)
    }

    private func handleConnection(_ client: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        // Read until the 0x04 terminator (or EOF / 1 MB guard) so we don't
        // depend on the client half-closing the socket.
        while true {
            let n = read(client, &buf, buf.count)
            if n > 0 { data.append(contentsOf: buf[0..<n]) } else { break }
            if data.contains(0x04) || data.count > 1 << 20 { break }
        }
        if let idx = data.firstIndex(of: 0x04) { data = data[..<idx] }
        let response = process(data)
        response.withCString { ptr in
            _ = write(client, ptr, strlen(ptr))
        }
    }

    /// Parse `<verb> <surfaceId> [cell]\n[text]` and resolve via CellBus on the
    /// main thread (Ghostty surfaces are main-thread only).
    private func process(_ data: Data) -> String {
        guard let newline = data.firstIndex(of: 0x0A) else { return "error: malformed request\n" }
        let header = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
        let textStart = data.index(after: newline)
        let text = textStart < data.endIndex
            ? String(decoding: data[textStart...], as: UTF8.self)
            : nil

        let tokens = header.split(separator: " ").map(String.init)
        guard tokens.count >= 2, let surfaceId = UUID(uuidString: tokens[1]) else {
            return "error: malformed request\n"
        }
        let verb = tokens[0]
        let args = Array(tokens.dropFirst(2))

        var response = "error: app not ready"
        let bus = cellBus
        DispatchQueue.main.sync {
            response = bus?.handle(verb: verb, surfaceId: surfaceId, args: args, body: text)
                ?? "error: app not ready"
        }
        return response.hasSuffix("\n") ? response : response + "\n"
    }
}
