import AppKit

enum ExternalIDE: String, CaseIterable, Codable, Identifiable {
    case vscode = "com.microsoft.VSCode"
    case vscodium = "com.vscodium"
    case cursor = "todesktop.com.Cursor"
    case windsurf = "com.codeium.windsurf"
    case zed = "dev.zed.Zed"
    case sublime = "com.sublimetext.4"
    case fleet = "com.jetbrains.fleet"
    case intellij = "com.jetbrains.intellij"
    case webstorm = "com.jetbrains.WebStorm"
    case xcode = "com.apple.dt.Xcode"
    case nova = "com.panic.Nova"
    case textmate = "com.macromates.TextMate"
    case bbedit = "com.barebones.bbedit"
    case neovide = "com.neovide.neovide"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vscode: return "Visual Studio Code"
        case .vscodium: return "VSCodium"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        case .sublime: return "Sublime Text"
        case .fleet: return "Fleet"
        case .intellij: return "IntelliJ IDEA"
        case .webstorm: return "WebStorm"
        case .xcode: return "Xcode"
        case .nova: return "Nova"
        case .textmate: return "TextMate"
        case .bbedit: return "BBEdit"
        case .neovide: return "Neovide"
        }
    }

    var systemImage: String {
        switch self {
        case .xcode: return "hammer"
        default: return "curlybraces"
        }
    }
}

enum ExternalIDEService {
    static func installedIDEs() -> [ExternalIDE] {
        ExternalIDE.allCases.filter { ide in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: ide.rawValue) != nil
        }
    }

    static func open(_ url: URL, in ide: ExternalIDE) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ide.rawValue) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
    }

    static func preferredIDE() -> ExternalIDE? {
        guard let raw = UserDefaults.standard.string(forKey: AppSettings.Keys.preferredIDE),
              let ide = ExternalIDE(rawValue: raw) else {
            return installedIDEs().first
        }
        return ide
    }
}
