import AppKit
import Combine
import SwiftTerm

@MainActor
final class TerminalPane: ObservableObject, Identifiable {
    let id: UUID
    @Published fileprivate(set) var terminalView: LocalProcessTerminalView
    @Published fileprivate(set) var connectionState: TerminalConnectionState
    @Published fileprivate(set) var workingDirectory: String?
    @Published fileprivate(set) var lastError: String?
    fileprivate weak var owner: TerminalSession?

    fileprivate init(id: UUID = UUID(), terminalView: LocalProcessTerminalView, kind: TerminalSessionKind) {
        self.id = id
        self.terminalView = terminalView
        self.connectionState = kind.isRemote ? .connecting : .starting
    }

    var isRunning: Bool { terminalView.process.running }
    func startIfNeeded() { owner?.startIfNeeded(self) }
    func reconnect() { owner?.reconnect(self) }
    func terminate() { owner?.terminate(self) }
    func focus() { owner?.activate(self) }
    func clearScrollback() {
        if let view = terminalView as? SessionTerminalView {
            view.clearTerminalScreen()
        } else {
            terminalView.clearScrollback()
        }
    }
    func applyAppearance(systemIsDark: Bool? = nil) { owner?.applyAppearance(to: self, systemIsDark: systemIsDark) }
    func showSearch() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        terminalView.performTextFinderAction(item)
    }
}

indirect enum TerminalPaneLayout: Equatable {
    case pane(UUID)
    case split(TerminalSplitOrientation, TerminalPaneLayout, TerminalPaneLayout)

    func replacing(_ id: UUID, with replacement: TerminalPaneLayout) -> TerminalPaneLayout {
        switch self {
        case .pane(let paneID):
            return paneID == id ? replacement : self
        case .split(let orientation, let first, let second):
            return .split(
                orientation,
                first.replacing(id, with: replacement),
                second.replacing(id, with: replacement)
            )
        }
    }

    func removing(_ id: UUID) -> TerminalPaneLayout? {
        switch self {
        case .pane(let paneID):
            return paneID == id ? nil : self
        case .split(let orientation, let first, let second):
            switch (first.removing(id), second.removing(id)) {
            case (nil, let remaining?): return remaining
            case (let remaining?, nil): return remaining
            case (let first?, let second?): return .split(orientation, first, second)
            case (nil, nil): return nil
            }
        }
    }

    func contains(_ id: UUID) -> Bool {
        switch self {
        case .pane(let paneID): paneID == id
        case .split(_, let first, let second): first.contains(id) || second.contains(id)
        }
    }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: UUID
    let kind: TerminalSessionKind
    let createdAt: Date

    @Published var title: String
    @Published private(set) var panes: [TerminalPane] = []
    @Published private(set) var paneLayout: TerminalPaneLayout
    @Published private(set) var activePaneID: UUID
    @Published private(set) var maximizedPaneID: UUID?
    @Published private(set) var lastAICommand: String?
    @Published private(set) var lastAIExitCode: Int?
    var onAskAISelection: ((String, UUID) -> Void)?

    private let configurationProvider: (String?) throws -> TerminalProcessConfiguration
    private weak var preferences: TerminalPreferences?
    private var resources: [UUID: TerminalConnectionResource] = [:]
    private var startedPaneIDs = Set<UUID>()
    private var closingPaneIDs = Set<UUID>()
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var appearanceSignatures: [UUID: TerminalAppearanceSignature] = [:]
    private var commandCompletions: [UUID: (Result<Int, Error>) -> Void] = [:]

    init(
        id: UUID = UUID(),
        title: String,
        kind: TerminalSessionKind,
        preferences: TerminalPreferences,
        configurationProvider: @escaping (String?) throws -> TerminalProcessConfiguration
    ) {
        let firstID = UUID()
        self.id = id
        self.title = title
        self.kind = kind
        self.createdAt = Date()
        self.preferences = preferences
        self.configurationProvider = configurationProvider
        self.activePaneID = firstID
        self.paneLayout = .pane(firstID)
        super.init()
        let first = makePane(id: firstID)
        panes = [first]
        applyAppearance(to: first)
    }

    var activePane: TerminalPane { panes.first(where: { $0.id == activePaneID }) ?? panes[0] }
    var terminalView: LocalProcessTerminalView { activePane.terminalView }
    var connectionState: TerminalConnectionState { activePane.connectionState }
    var workingDirectory: String? { activePane.workingDirectory }
    var lastError: String? { activePane.lastError }
    var isRunning: Bool { panes.contains(where: \.isRunning) }

    func startIfNeeded() {
        startIfNeeded(activePane)
    }

    func split(_ orientation: TerminalSplitOrientation) {
        let source = activePane
        let pane = makePane()
        pane.workingDirectory = source.workingDirectory
        panes.append(pane)
        paneLayout = paneLayout.replacing(source.id, with: .split(orientation, .pane(source.id), .pane(pane.id)))
        maximizedPaneID = nil
        activePaneID = pane.id
        applyAppearance(to: pane)
    }

    @discardableResult
    func closePane(_ id: UUID) -> Bool {
        guard panes.count > 1, let pane = pane(id: id) else { return false }
        terminate(pane)
        panes.removeAll { $0.id == id }
        paneLayout = paneLayout.removing(id) ?? .pane(panes[0].id)
        if maximizedPaneID == id { maximizedPaneID = nil }
        if activePaneID == id { activePaneID = panes.first(where: { paneLayout.contains($0.id) })?.id ?? panes[0].id }
        DispatchQueue.main.async { [weak self] in self?.activePane.focus() }
        return true
    }

    func toggleMaximize(_ id: UUID) {
        guard pane(id: id) != nil else { return }
        maximizedPaneID = maximizedPaneID == id ? nil : id
        activate(id)
    }

    func activate(_ pane: TerminalPane) { activate(pane.id) }
    func activate(_ id: UUID) {
        guard let pane = pane(id: id) else { return }
        activePaneID = id
        pane.terminalView.window?.makeFirstResponder(pane.terminalView)
    }

    func pane(id: UUID) -> TerminalPane? { panes.first { $0.id == id } }

    fileprivate func startIfNeeded(_ pane: TerminalPane) {
        guard startedPaneIDs.insert(pane.id).inserted else { return }
        startProcess(pane)
    }

    fileprivate func reconnect(_ pane: TerminalPane, resetAttempts: Bool = true) {
        guard kind.isRemote else { return }
        if resetAttempts { reconnectAttempts[pane.id] = 0 }
        reconnectTasks[pane.id]?.cancel()
        closingPaneIDs.insert(pane.id)
        pane.terminalView.terminate()
        resources.removeValue(forKey: pane.id)?.finish()
        startedPaneIDs.insert(pane.id)
        pane.lastError = nil
        pane.connectionState = .connecting

        let replacement = Self.makeTerminalView(preferences: preferences)
        replacement.processDelegate = self
        pane.terminalView = replacement
        appearanceSignatures[pane.id] = nil
        configureTerminalCallbacks(for: pane)
        closingPaneIDs.remove(pane.id)
        applyAppearance(to: pane)
        startProcess(pane)
    }

    func terminate() {
        panes.forEach(terminate)
    }

    fileprivate func terminate(_ pane: TerminalPane) {
        closingPaneIDs.insert(pane.id)
        reconnectTasks.removeValue(forKey: pane.id)?.cancel()
        if pane.terminalView.process.running { pane.terminalView.terminate() }
        resources.removeValue(forKey: pane.id)?.finish()
    }

    func focus() { activePane.focus() }
    func clearScrollback() { activePane.clearScrollback() }
    func showSearch() { activePane.showSearch() }

    var selectedText: String? {
        guard let view = activePane.terminalView as? SessionTerminalView,
              view.selection.active else { return nil }
        let text = view.selection.getSelectedText().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var recentOutput: String? {
        (activePane.terminalView as? SessionTerminalView)?.recentOutput
    }

    func insert(command: String) throws {
        guard activePane.isRunning else { throw TerminalAIError.sessionUnavailable }
        let bytes = Array(command.utf8)
        activePane.terminalView.send(source: activePane.terminalView, data: bytes[...])
        activePane.focus()
    }

    func run(command: String, completion: @escaping (Result<Int, Error>) -> Void) throws {
        guard activePane.isRunning else { throw TerminalAIError.sessionUnavailable }
        let commandID = UUID()
        commandCompletions[commandID] = completion
        lastAICommand = command
        lastAIExitCode = nil
        let wrapped = "{\n\(command)\n}; __inchspace_ai_status=$?; printf '\\033]1337;inchspaceAIExit=\(commandID.uuidString):%s\\007' \"$__inchspace_ai_status\"\r"
        let bytes = Array(wrapped.utf8)
        (activePane.terminalView as? SessionTerminalView)?.isProgrammaticAIWrite = true
        activePane.terminalView.send(source: activePane.terminalView, data: bytes[...])
        (activePane.terminalView as? SessionTerminalView)?.isProgrammaticAIWrite = false
        activePane.focus()
    }

    func interruptActiveCommand() {
        guard activePane.isRunning else { return }
        activePane.terminalView.send(source: activePane.terminalView, data: [0x03][...])
    }

    func increaseFontSize() {
        guard let preferences else { return }
        preferences.fontSize = min(18, preferences.fontSize + 1)
        applyAppearance()
    }

    func decreaseFontSize() {
        guard let preferences else { return }
        preferences.fontSize = max(12, preferences.fontSize - 1)
        applyAppearance()
    }

    func resetFontSize() {
        preferences?.fontSize = 14
        applyAppearance()
    }

    func applyAppearance(systemIsDark: Bool? = nil) {
        panes.forEach { applyAppearance(to: $0, systemIsDark: systemIsDark) }
    }

    fileprivate func applyAppearance(to pane: TerminalPane, systemIsDark: Bool? = nil) {
        guard let preferences else { return }
        let view = pane.terminalView

        let dark: Bool
        switch preferences.theme {
        case .dark:
            dark = true
            view.appearance = NSAppearance(named: .darkAqua)
        case .light:
            dark = false
            view.appearance = NSAppearance(named: .aqua)
        case .system:
            view.appearance = nil
            dark = systemIsDark
                ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        case .macOSDark, .dracula, .oneDark, .solarizedDark, .catppuccinMocha, .custom:
            dark = true
            view.appearance = NSAppearance(named: .darkAqua)
        }

        let signature = TerminalAppearanceSignature(
            fontSize: preferences.fontSize,
            fontFamily: preferences.fontFamily,
            lineHeight: preferences.lineHeight,
            cursorShape: preferences.cursorShape,
            cursorBlinks: preferences.cursorBlinks,
            theme: preferences.theme,
            resolvedDark: dark,
            scrollbackLines: preferences.scrollbackLines,
            customColors: [
                preferences.customBackgroundColor,
                preferences.customForegroundColor,
                preferences.customCursorColor,
                preferences.customSelectionColor,
            ],
            automaticallyCopiesSelection: preferences.copySelectionAutomatically
        )
        guard appearanceSignatures[pane.id] != signature else { return }
        appearanceSignatures[pane.id] = signature

        let appearance = TerminalAppearance(theme: preferences.theme, resolvedDark: dark, preferences: preferences)
        view.font = Self.terminalFont(family: preferences.fontFamily, size: preferences.fontSize)
        view.lineSpacing = preferences.lineHeight
        view.changeScrollback(preferences.scrollbackLines)
        view.nativeBackgroundColor = appearance.background
        view.nativeForegroundColor = appearance.foreground
        view.layer?.backgroundColor = appearance.background.cgColor
        view.caretColor = appearance.cursor
        view.caretTextColor = appearance.cursorText
        view.selectedTextBackgroundColor = appearance.selectionBackground
        view.selectedTextForegroundColor = appearance.selectionForeground
        view.installColors(appearance.ansiPalette)
        view.getTerminal().setCursorStyle(cursorStyle(preferences))
        (view as? SessionTerminalView)?.automaticallyCopiesSelection = preferences.copySelectionAutomatically
        view.needsDisplay = true
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !kind.isRemote else { return }
        if pane(for: source)?.id == activePaneID { self.title = cleaned }
    }

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        guard let pane = pane(for: source) else { return }
        pane.workingDirectory = directory.flatMap { URL(string: $0)?.path ?? $0 }
        if pane.id == activePaneID { preferences?.remember(directory: directory) }
    }

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        guard let pane = pane(for: source), !closingPaneIDs.contains(pane.id) else { return }
        resources.removeValue(forKey: pane.id)?.finish()
        guard startedPaneIDs.contains(pane.id) else { return }
        if kind.isRemote {
            pane.connectionState = exitCode == 0 ? .disconnected : .error
            if let exitCode, exitCode != 0 {
                pane.lastError = "SSH 进程已退出（代码 \(exitCode)）。"
            }
            scheduleReconnectIfNeeded(pane)
        } else {
            pane.connectionState = exitCode == 0 ? .disconnected : .error
        }
        let error = TerminalAIError.sessionUnavailable
        commandCompletions.values.forEach { $0(.failure(error)) }
        commandCompletions.removeAll()
        objectWillChange.send()
    }

    private func startProcess(_ pane: TerminalPane) {
        do {
            let inheritedDirectory = preferences?.inheritWorkingDirectory == true ? pane.workingDirectory : nil
            let configuration = try configurationProvider(inheritedDirectory)
            resources[pane.id] = configuration.resource
            pane.terminalView.startProcess(
                executable: configuration.executable,
                args: configuration.arguments,
                environment: configuration.environment,
                execName: configuration.execName,
                currentDirectory: configuration.currentDirectory
            )
            if pane.terminalView.process.running {
                if !kind.isRemote { pane.connectionState = .connected }
                pane.focus()
            } else {
                pane.connectionState = .error
                pane.lastError = "无法启动终端进程。"
            }
        } catch {
            resources.removeValue(forKey: pane.id)?.finish()
            pane.connectionState = .error
            pane.lastError = error.localizedDescription
            pane.terminalView.feed(text: "\r\n\u{001B}[31m\(error.localizedDescription)\u{001B}[0m\r\n")
        }
        objectWillChange.send()
    }

    private func scheduleReconnectIfNeeded(_ pane: TerminalPane) {
        let attempt = reconnectAttempts[pane.id, default: 0]
        guard preferences?.automaticallyReconnect == true, attempt < 3 else { return }
        reconnectTasks[pane.id]?.cancel()
        reconnectAttempts[pane.id] = attempt + 1
        let delay = 3 * Int(pow(2.0, Double(attempt)))
        reconnectTasks[pane.id] = Task { [weak self, weak pane] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let pane else { return }
            self?.reconnect(pane, resetAttempts: false)
        }
    }

    private func makePane(id: UUID = UUID()) -> TerminalPane {
        let view = Self.makeTerminalView(preferences: preferences)
        let pane = TerminalPane(id: id, terminalView: view, kind: kind)
        pane.owner = self
        view.processDelegate = self
        configureTerminalCallbacks(for: pane)
        return pane
    }

    private func pane(for terminalView: SwiftTerm.TerminalView) -> TerminalPane? {
        panes.first { $0.terminalView === terminalView }
    }

    private func configureTerminalCallbacks(for pane: TerminalPane) {
        guard let view = pane.terminalView as? SessionTerminalView else { return }
        view.onDataReceived = { [weak self, weak pane] in
            guard let self, let pane, self.kind.isRemote, pane.connectionState == .connecting else { return }
            self.reconnectAttempts[pane.id] = 0
            pane.connectionState = .connected
            self.objectWillChange.send()
        }
        view.onAskAI = { [weak self, weak pane] selection in
            guard let self, let pane else { return }
            self.activate(pane)
            self.onAskAISelection?(selection, self.id)
        }
        view.onCommandExit = { [weak self] commandID, exitCode in
            guard let self else { return }
            self.lastAIExitCode = exitCode
            self.commandCompletions.removeValue(forKey: commandID)?(.success(exitCode))
        }
        view.onCommandSubmitted = { [weak self] command in
            self?.lastAICommand = command
        }
    }

    private func cursorStyle(_ preferences: TerminalPreferences) -> CursorStyle {
        switch (preferences.cursorShape, preferences.cursorBlinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        }
    }

    private static func makeTerminalView(preferences: TerminalPreferences?) -> LocalProcessTerminalView {
        let options = TerminalOptions(
            cols: 80,
            rows: 25,
            termName: "xterm-256color",
            cursorStyle: .blinkBlock,
            scrollback: preferences?.scrollbackLines ?? 10_000
        )
        let font = terminalFont(family: preferences?.fontFamily ?? "SF Mono", size: preferences?.fontSize ?? 14)
        let view = SessionTerminalView(frame: .zero, font: font, options: options)
        view.autoresizingMask = [.width, .height]
        view.caretViewTracksFocus = true
        view.linkReporting = .implicit
        return view
    }

    private static func terminalFont(family: String, size: Double) -> NSFont {
        let names: [String]
        switch family {
        case "SF Mono": names = ["SFMono-Regular", "SF Mono"]
        case "Menlo": names = ["Menlo-Regular", "Menlo"]
        default: names = [family]
        }
        return names.lazy.compactMap { NSFont(name: $0, size: size) }.first
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

private final class SessionTerminalView: LocalProcessTerminalView {
    var onDataReceived: (() -> Void)?
    var onAskAI: ((String) -> Void)?
    var onCommandExit: ((UUID, Int) -> Void)?
    var onCommandSubmitted: ((String) -> Void)?
    var automaticallyCopiesSelection = true
    var isProgrammaticAIWrite = false
    private(set) var recentOutput = ""
    private var markerBuffer = ""
    private let searchButtonCursorOwner = SearchButtonCursorOwner()
    private let searchFieldCursorOwner = SearchFieldCursorOwner()
    private var searchButtonTrackingAreas: [ObjectIdentifier: (NSButton, NSTrackingArea)] = [:]
    private var searchBarTrackingArea: (NSView, NSTrackingArea)?
    private var searchFieldTrackingArea: (NSSearchField, NSTrackingArea)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        updateSearchButtonCursorTracking()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if let text = String(bytes: slice, encoding: .utf8) {
            recentOutput += text
            if recentOutput.count > 24_000 { recentOutput = String(recentOutput.suffix(20_000)) }
            inspectCommandMarkers(text)
        }
        onDataReceived?()
    }

    override func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
        if !isProgrammaticAIWrite { captureSubmittedCommand(data) }
        super.send(source: source, data: data)
    }

    func clearTerminalScreen() {
        // Let the running line editor redraw its prompt, then discard both the
        // visible page and scrollback. This keeps shell and renderer state aligned.
        send(source: self, data: [0x0c][...])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            self.clearScrollback()
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard automaticallyCopiesSelection, selection.active else { return }
        let text = selection.getSelectedText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "终端")
        if selection.active, !selection.getSelectedText().isEmpty {
            menu.addItem(withTitle: "复制", action: #selector(copy(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "粘贴", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "清空", action: #selector(clearFromMenu(_:)), keyEquivalent: "")
        if selection.active, !selection.getSelectedText().isEmpty {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "询问 AI", action: #selector(askAIFromMenu(_:)), keyEquivalent: "")
        }
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func clearFromMenu(_ sender: Any?) {
        clearTerminalScreen()
    }

    @objc private func askAIFromMenu(_ sender: Any?) {
        let text = selection.getSelectedText()
        guard !text.isEmpty else { return }
        onAskAI?(text)
    }

    private func inspectCommandMarkers(_ text: String) {
        markerBuffer = String((markerBuffer + text).suffix(2_000))
        let pattern = #"inchspaceAIExit=([0-9A-Fa-f-]{36}):(-?\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = markerBuffer as NSString
        let matches = regex.matches(in: markerBuffer, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard let id = UUID(uuidString: ns.substring(with: match.range(at: 1))),
                  let code = Int(ns.substring(with: match.range(at: 2))) else { continue }
            onCommandExit?(id, code)
        }
        if !matches.isEmpty { markerBuffer = "" }
    }

    private var inputBuffer = ""
    private func captureSubmittedCommand(_ data: ArraySlice<UInt8>) {
        for byte in data {
            switch byte {
            case 0x0d, 0x0a:
                let command = inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty { onCommandSubmitted?(command) }
                inputBuffer = ""
            case 0x08, 0x7f:
                if !inputBuffer.isEmpty { inputBuffer.removeLast() }
            case 0x20...0x7e:
                inputBuffer.append(Character(UnicodeScalar(byte)))
            default:
                break
            }
        }
        if inputBuffer.count > 4_000 { inputBuffer = String(inputBuffer.suffix(4_000)) }
    }

    private func updateSearchButtonCursorTracking() {
        guard let findBar = subviews.first(where: {
            searchField(in: $0) != nil
        }), let searchField = searchField(in: findBar) else {
            removeSearchCursorTracking()
            return
        }

        updateSearchBarTracking(for: findBar)
        updateSearchFieldTracking(for: searchField)

        let buttons = descendants(of: NSButton.self, in: findBar)
        let buttonIDs = Set(buttons.map { ObjectIdentifier($0) })

        let staleIDs = searchButtonTrackingAreas.keys.filter { !buttonIDs.contains($0) }
        for id in staleIDs {
            guard let entry = searchButtonTrackingAreas[id] else { continue }
            entry.0.removeTrackingArea(entry.1)
            searchButtonTrackingAreas[id] = nil
        }

        for button in buttons {
            let id = ObjectIdentifier(button)
            guard searchButtonTrackingAreas[id] == nil else { continue }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
                owner: searchButtonCursorOwner,
                userInfo: nil
            )
            button.addTrackingArea(area)
            searchButtonTrackingAreas[id] = (button, area)
        }
    }

    private func updateSearchBarTracking(for findBar: NSView) {
        guard searchBarTrackingArea?.0 !== findBar else { return }
        if let current = searchBarTrackingArea {
            current.0.removeTrackingArea(current.1)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: searchButtonCursorOwner,
            userInfo: nil
        )
        findBar.addTrackingArea(area)
        searchBarTrackingArea = (findBar, area)
    }

    private func updateSearchFieldTracking(for searchField: NSSearchField) {
        guard searchFieldTrackingArea?.0 !== searchField else { return }
        if let current = searchFieldTrackingArea {
            current.0.removeTrackingArea(current.1)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: searchFieldCursorOwner,
            userInfo: nil
        )
        searchField.addTrackingArea(area)
        searchFieldTrackingArea = (searchField, area)
    }

    private func searchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField { return searchField }
        for subview in view.subviews {
            if let searchField = searchField(in: subview) { return searchField }
        }
        return nil
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { subview -> [View] in
            let match = (subview as? View).map { [$0] } ?? []
            return match + descendants(of: type, in: subview)
        }
    }

    private func removeSearchCursorTracking() {
        for entry in searchButtonTrackingAreas.values {
            entry.0.removeTrackingArea(entry.1)
        }
        searchButtonTrackingAreas.removeAll()
        if let current = searchBarTrackingArea {
            current.0.removeTrackingArea(current.1)
            searchBarTrackingArea = nil
        }
        if let current = searchFieldTrackingArea {
            current.0.removeTrackingArea(current.1)
            searchFieldTrackingArea = nil
        }
    }
}

private final class SearchButtonCursorOwner: NSResponder {
    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

private final class SearchFieldCursorOwner: NSResponder {
    override func mouseEntered(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }
}

private struct TerminalAppearanceSignature: Equatable {
    let fontSize: Double
    let fontFamily: String
    let lineHeight: Double
    let cursorShape: TerminalCursorShape
    let cursorBlinks: Bool
    let theme: TerminalThemePreference
    let resolvedDark: Bool
    let scrollbackLines: Int
    let customColors: [String]
    let automaticallyCopiesSelection: Bool
}

private struct TerminalAppearance {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let cursorText: NSColor
    let selectionBackground: NSColor
    let selectionForeground: NSColor
    let ansiPalette: [SwiftTerm.Color]

    init(theme: TerminalThemePreference, resolvedDark: Bool, preferences: TerminalPreferences) {
        let colors: (String, String, String, String, [SwiftTerm.Color])
        switch theme {
        case .dracula:
            colors = ("#282A36", "#F8F8F2", "#BD93F9", "#44475A", Self.draculaANSI)
        case .oneDark:
            colors = ("#1E2127", "#ABB2BF", "#61AFEF", "#3E4451", Self.oneDarkANSI)
        case .solarizedDark:
            colors = ("#002B36", "#839496", "#268BD2", "#073642", Self.solarizedANSI)
        case .catppuccinMocha:
            colors = ("#1E1E2E", "#CDD6F4", "#89B4FA", "#45475A", Self.catppuccinANSI)
        case .custom:
            colors = (
                preferences.customBackgroundColor,
                preferences.customForegroundColor,
                preferences.customCursorColor,
                preferences.customSelectionColor,
                Self.darkANSI
            )
        case .light:
            colors = ("#F6F7F9", "#23252A", "#007AFF", "#007AFF38", Self.lightANSI)
        case .system where !resolvedDark:
            colors = ("#F6F7F9", "#23252A", "#007AFF", "#007AFF38", Self.lightANSI)
        case .macOSDark, .dark, .system:
            colors = ("#1E1E1E", "#E6E6E6", "#0A84FF", "#0A84FF59", Self.darkANSI)
        }
        background = NSColor(hex: colors.0) ?? .black
        foreground = NSColor(hex: colors.1) ?? .white
        cursor = NSColor(hex: colors.2) ?? .controlAccentColor
        cursorText = background
        selectionBackground = NSColor(hex: colors.3) ?? cursor.withAlphaComponent(0.34)
        selectionForeground = foreground
        ansiPalette = colors.4
    }

    private static func color(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red8: red, green8: green, blue8: blue)
    }

    /// Base ANSI colors are theme-specific for legibility. ANSI 256 and true color
    /// sequences continue to be interpreted by SwiftTerm without prompt parsing.
    private static let lightANSI: [SwiftTerm.Color] = [
        color(46, 49, 56), color(188, 52, 50), color(36, 122, 62), color(138, 93, 0),
        color(36, 90, 199), color(132, 61, 154), color(8, 122, 134), color(91, 95, 103),
        color(116, 120, 130), color(217, 62, 58), color(45, 145, 73), color(163, 111, 0),
        color(52, 107, 222), color(158, 75, 181), color(0, 143, 157), color(30, 33, 40),
    ]

    private static let darkANSI: [SwiftTerm.Color] = [
        color(43, 45, 49), color(232, 86, 80), color(70, 190, 101), color(211, 168, 65),
        color(91, 143, 245), color(189, 111, 207), color(61, 184, 195), color(205, 208, 216),
        color(119, 123, 133), color(255, 107, 100), color(86, 212, 122), color(232, 194, 94),
        color(120, 169, 255), color(211, 140, 229), color(84, 205, 214), color(244, 245, 247),
    ]

    private static let draculaANSI: [SwiftTerm.Color] = [
        color(33, 34, 44), color(255, 85, 85), color(80, 250, 123), color(241, 250, 140),
        color(98, 114, 164), color(255, 121, 198), color(139, 233, 253), color(248, 248, 242),
        color(98, 98, 110), color(255, 110, 110), color(105, 255, 148), color(255, 255, 165),
        color(130, 145, 195), color(255, 146, 223), color(164, 255, 255), color(255, 255, 255),
    ]

    private static let oneDarkANSI: [SwiftTerm.Color] = [
        color(40, 44, 52), color(224, 108, 117), color(152, 195, 121), color(229, 192, 123),
        color(97, 175, 239), color(198, 120, 221), color(86, 182, 194), color(171, 178, 191),
        color(92, 99, 112), color(234, 126, 136), color(173, 219, 143), color(241, 209, 148),
        color(116, 195, 255), color(218, 143, 239), color(104, 211, 224), color(255, 255, 255),
    ]

    private static let solarizedANSI: [SwiftTerm.Color] = [
        color(7, 54, 66), color(220, 50, 47), color(133, 153, 0), color(181, 137, 0),
        color(38, 139, 210), color(211, 54, 130), color(42, 161, 152), color(238, 232, 213),
        color(0, 43, 54), color(203, 75, 22), color(88, 110, 117), color(101, 123, 131),
        color(131, 148, 150), color(108, 113, 196), color(147, 161, 161), color(253, 246, 227),
    ]

    private static let catppuccinANSI: [SwiftTerm.Color] = [
        color(69, 71, 90), color(243, 139, 168), color(166, 227, 161), color(249, 226, 175),
        color(137, 180, 250), color(245, 194, 231), color(148, 226, 213), color(186, 194, 222),
        color(88, 91, 112), color(243, 139, 168), color(166, 227, 161), color(249, 226, 175),
        color(137, 180, 250), color(245, 194, 231), color(148, 226, 213), color(205, 214, 244),
    ]
}

private extension NSColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let raw = UInt64(value, radix: 16) else { return nil }
        let hasAlpha = value.count == 8
        let red = CGFloat((raw >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = CGFloat((raw >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = CGFloat((raw >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? CGFloat(raw & 0xff) / 255 : 1
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
