import AppKit
import Combine
import Foundation

enum TerminalSessionKind: Equatable {
    case local(shell: String)
    case ssh(serverID: UUID, endpoint: String)

    var symbol: String {
        switch self {
        case .local: "laptopcomputer"
        case .ssh: "server.rack"
        }
    }

    var isRemote: Bool {
        if case .ssh = self { return true }
        return false
    }
}

enum TerminalConnectionState: String {
    case starting
    case connecting
    case connected
    case disconnected
    case error

    var title: String {
        switch self {
        case .starting: "正在启动"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .disconnected: "已断开"
        case .error: "连接错误"
        }
    }
}

enum TerminalSplitOrientation: String, CaseIterable, Identifiable {
    case vertical
    case horizontal

    var id: String { rawValue }
    var title: String { self == .vertical ? "左右分屏" : "上下分屏" }
    var symbol: String { self == .vertical ? "rectangle.split.2x1" : "rectangle.split.1x2" }
}

enum TerminalThemePreference: String, CaseIterable, Identifiable {
    case macOSDark
    case dracula
    case oneDark
    case solarizedDark
    case catppuccinMocha
    case custom
    // Kept for existing installations. New installations default to macOS Dark.
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .macOSDark: "macOS Dark"
        case .dracula: "Dracula"
        case .oneDark: "One Dark"
        case .solarizedDark: "Solarized Dark"
        case .catppuccinMocha: "Catppuccin Mocha"
        case .custom: "自定义"
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "经典深色"
        }
    }
}

enum TerminalPromptStyle: String, CaseIterable, Identifiable {
    case compactPath
    case chevron
    case userAndHost
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .compactPath: "~/project ❯"
        case .chevron: "❯"
        case .userAndHost: "user@mac %"
        case .custom: "自定义"
        }
    }
}

enum TerminalCursorShape: String, CaseIterable, Identifiable {
    case block
    case bar
    case underline

    var id: String { rawValue }
    var title: String {
        switch self {
        case .block: "方块"
        case .bar: "竖线"
        case .underline: "下划线"
        }
    }
}

enum TerminalStartupDirectory: String, CaseIterable, Identifiable {
    case home
    case last
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "个人目录"
        case .last: "上次目录"
        case .custom: "自定义"
        }
    }
}

@MainActor
final class TerminalPreferences: ObservableObject {
    @Published var shellOverride: String { didSet { save() } }
    @Published var startupDirectory: TerminalStartupDirectory { didSet { save() } }
    @Published var customDirectory: String { didSet { save() } }
    @Published var fontSize: Double { didSet { save() } }
    @Published var fontFamily: String { didSet { save() } }
    @Published var lineHeight: Double { didSet { save() } }
    @Published var cursorShape: TerminalCursorShape { didSet { save() } }
    @Published var cursorBlinks: Bool { didSet { save() } }
    @Published var theme: TerminalThemePreference { didSet { save() } }
    @Published var customBackgroundColor: String { didSet { save() } }
    @Published var customForegroundColor: String { didSet { save() } }
    @Published var customCursorColor: String { didSet { save() } }
    @Published var customSelectionColor: String { didSet { save() } }
    @Published var promptStyle: TerminalPromptStyle { didSet { save() } }
    @Published var customPrompt: String { didSet { save() } }
    @Published var cleanShellStartup: Bool { didSet { save() } }
    @Published var copySelectionAutomatically: Bool { didSet { save() } }
    @Published var scrollbackLines: Int { didSet { save() } }
    @Published var confirmBeforeClosing: Bool { didSet { save() } }
    @Published var automaticallyReconnect: Bool { didSet { save() } }
    @Published var inheritWorkingDirectory: Bool { didSet { save() } }

    private enum Key {
        static let prefix = "terminal.preferences."
        static let shell = prefix + "shell"
        static let startupDirectory = prefix + "startupDirectory"
        static let customDirectory = prefix + "customDirectory"
        static let fontSize = prefix + "fontSize"
        static let fontFamily = prefix + "fontFamily"
        static let lineHeight = prefix + "lineHeight"
        static let cursorShape = prefix + "cursorShape"
        static let cursorBlinks = prefix + "cursorBlinks"
        static let theme = prefix + "theme"
        static let customBackground = prefix + "customBackground"
        static let customForeground = prefix + "customForeground"
        static let customCursor = prefix + "customCursor"
        static let customSelection = prefix + "customSelection"
        static let promptStyle = prefix + "promptStyle"
        static let customPrompt = prefix + "customPrompt"
        static let cleanStartup = prefix + "cleanStartup"
        static let autoCopy = prefix + "autoCopy"
        static let scrollback = prefix + "scrollback"
        static let confirmClose = prefix + "confirmClose"
        static let reconnect = prefix + "reconnect"
        static let inheritDirectory = prefix + "inheritDirectory"
        static let lastDirectory = prefix + "lastDirectory"
    }

    private var isLoading = true
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shellOverride = defaults.string(forKey: Key.shell) ?? ""
        startupDirectory = TerminalStartupDirectory(rawValue: defaults.string(forKey: Key.startupDirectory) ?? "") ?? .home
        customDirectory = defaults.string(forKey: Key.customDirectory) ?? ""
        let storedSize = defaults.double(forKey: Key.fontSize)
        fontSize = storedSize == 0 ? 14 : min(max(storedSize, 12), 18)
        fontFamily = defaults.string(forKey: Key.fontFamily) ?? "SF Mono"
        let storedLineHeight = defaults.double(forKey: Key.lineHeight)
        lineHeight = storedLineHeight == 0 ? 1.12 : min(max(storedLineHeight, 1.0), 1.5)
        cursorShape = TerminalCursorShape(rawValue: defaults.string(forKey: Key.cursorShape) ?? "") ?? .block
        cursorBlinks = defaults.object(forKey: Key.cursorBlinks) as? Bool ?? true
        theme = TerminalThemePreference(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .macOSDark
        customBackgroundColor = defaults.string(forKey: Key.customBackground) ?? "#1E1E1E"
        customForegroundColor = defaults.string(forKey: Key.customForeground) ?? "#E6E6E6"
        customCursorColor = defaults.string(forKey: Key.customCursor) ?? "#0A84FF"
        customSelectionColor = defaults.string(forKey: Key.customSelection) ?? "#0A84FF59"
        promptStyle = TerminalPromptStyle(rawValue: defaults.string(forKey: Key.promptStyle) ?? "") ?? .compactPath
        customPrompt = defaults.string(forKey: Key.customPrompt) ?? "❯ "
        cleanShellStartup = defaults.object(forKey: Key.cleanStartup) as? Bool ?? true
        copySelectionAutomatically = defaults.object(forKey: Key.autoCopy) as? Bool ?? true
        let storedScrollback = defaults.integer(forKey: Key.scrollback)
        scrollbackLines = storedScrollback == 0 ? 10_000 : storedScrollback
        confirmBeforeClosing = defaults.object(forKey: Key.confirmClose) as? Bool ?? true
        automaticallyReconnect = defaults.bool(forKey: Key.reconnect)
        inheritWorkingDirectory = defaults.object(forKey: Key.inheritDirectory) as? Bool ?? true
        isLoading = false
    }

    var resolvedShell: String {
        if !shellOverride.isEmpty, FileManager.default.isExecutableFile(atPath: shellOverride) {
            return shellOverride
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }

        let suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard suggestedSize > 0 else { return "/bin/zsh" }
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: suggestedSize)
        defer { buffer.deallocate() }
        var password = passwd()
        var result: UnsafeMutablePointer<passwd>?
        guard getpwuid_r(getuid(), &password, buffer, suggestedSize, &result) == 0,
              result != nil else { return "/bin/zsh" }
        return String(cString: password.pw_shell)
    }

    var workingDirectory: String {
        switch startupDirectory {
        case .home:
            return FileManager.default.homeDirectoryForCurrentUser.path
        case .last:
            return defaults.string(forKey: Key.lastDirectory)
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        case .custom:
            let expanded = NSString(string: customDirectory).expandingTildeInPath
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue
                ? expanded
                : FileManager.default.homeDirectoryForCurrentUser.path
        }
    }

    func remember(directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        let path = URL(string: directory)?.path ?? directory
        defaults.set(path, forKey: Key.lastDirectory)
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(shellOverride, forKey: Key.shell)
        defaults.set(startupDirectory.rawValue, forKey: Key.startupDirectory)
        defaults.set(customDirectory, forKey: Key.customDirectory)
        defaults.set(fontSize, forKey: Key.fontSize)
        defaults.set(fontFamily, forKey: Key.fontFamily)
        defaults.set(lineHeight, forKey: Key.lineHeight)
        defaults.set(cursorShape.rawValue, forKey: Key.cursorShape)
        defaults.set(cursorBlinks, forKey: Key.cursorBlinks)
        defaults.set(theme.rawValue, forKey: Key.theme)
        defaults.set(customBackgroundColor, forKey: Key.customBackground)
        defaults.set(customForegroundColor, forKey: Key.customForeground)
        defaults.set(customCursorColor, forKey: Key.customCursor)
        defaults.set(customSelectionColor, forKey: Key.customSelection)
        defaults.set(promptStyle.rawValue, forKey: Key.promptStyle)
        defaults.set(customPrompt, forKey: Key.customPrompt)
        defaults.set(cleanShellStartup, forKey: Key.cleanStartup)
        defaults.set(copySelectionAutomatically, forKey: Key.autoCopy)
        defaults.set(scrollbackLines, forKey: Key.scrollback)
        defaults.set(confirmBeforeClosing, forKey: Key.confirmClose)
        defaults.set(automaticallyReconnect, forKey: Key.reconnect)
        defaults.set(inheritWorkingDirectory, forKey: Key.inheritDirectory)
    }
}
