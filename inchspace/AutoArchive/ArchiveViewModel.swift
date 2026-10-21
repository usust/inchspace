import AppKit
import Combine
import Foundation

enum ArchiveScreen: Equatable {
    case loading, onboarding, dashboard
}

enum ArchiveOnboardingStep: Int, CaseIterable {
    case welcome, folder, privacy
}

enum ArchiveActivity: Equatable {
    case idle
    case working(String)
    case failed(String)
}

@MainActor
final class ArchiveViewModel: ObservableObject {
    static let shared = ArchiveViewModel()

    private enum Keys {
        static let consent = "archive.autopilot.aiConsent"
        static let onboarded = "archive.autopilot.onboarded"
        static let watching = "archive.autopilot.watching"
    }

    @Published private(set) var state = ArchiveState()
    @Published private(set) var isReady = false
    @Published private(set) var loadError: String?
    @Published var onboardingStep: ArchiveOnboardingStep = .welcome
    @Published private(set) var activity: ArchiveActivity = .idle
    @Published private(set) var isWatching = false
    @Published private(set) var lastSummary: ArchiveRunSummary?
    @Published private(set) var lastRunAt: Date?
    @Published var showDetails = false

    private let defaults: UserDefaults
    private var service: ArchiveService?
    private var settings: TerminalAISettings?
    private var runTask: Task<Void, Never>?
    private var rerunRequested = false
    private lazy var watcher = ArchiveFolderWatcher { [weak self] in self?.folderChanged() }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var workspace: ArchiveFolder? { state.configuration.folders.first { $0.role == .workspace } }
    var hasConsent: Bool { defaults.bool(forKey: Keys.consent) }
    var isOnboarded: Bool { defaults.bool(forKey: Keys.onboarded) || hasConsent }
    /// AI is used only with consent and a working model; otherwise the offline planner takes over.
    var usesAI: Bool { hasConsent && isModelConfigured }
    var isRunning: Bool { runTask != nil }

    var screen: ArchiveScreen {
        guard isReady else { return .loading }
        return workspace != nil && isOnboarded ? .dashboard : .onboarding
    }

    /// Completed batches that still have something to undo, newest first.
    var batches: [ArchiveAIPlan] {
        (state.ai?.plans ?? []).filter { plan in
            plan.files.contains { $0.status == .complete } || plan.directories.contains { $0.status == .complete }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var isModelConfigured: Bool {
        guard let settings, let configuration = try? settings.configuration.validated() else { return false }
        return (try? settings.apiKey(for: configuration.baseURL)) != nil
    }

    func attach(settings: TerminalAISettings) { self.settings = settings }

    // MARK: Lifecycle

    func bootstrap() async {
        guard !isReady else { return }
        loadError = nil
        do {
            let service = try await Task.detached(priority: .utility) { try ArchiveService() }.value
            self.service = service
            try await service.recoverAIDirectories()
            if !(await service.snapshot()).operations.isEmpty { try await service.recover() }
            state = await service.snapshot()
            isReady = true
            if screen == .dashboard, defaults.object(forKey: Keys.watching) as? Bool ?? true {
                startWatching()
                organize()
            }
        } catch { loadError = error.localizedDescription }
    }

    // MARK: Onboarding

    func advanceOnboarding() {
        if let next = ArchiveOnboardingStep(rawValue: onboardingStep.rawValue + 1) { onboardingStep = next }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择要整理的文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        Task { await adopt(selected) }
    }

    private func adopt(_ selected: URL) async {
        guard let service else { return }
        stopWatching()
        runTask?.cancel()
        do {
            let started = selected.startAccessingSecurityScopedResource()
            defer { if started { selected.stopAccessingSecurityScopedResource() } }
            let url = selected.resolvingSymlinksInPath().standardizedFileURL
            let bookmark = try SecurityScopedBookmarkService.makeWritableBookmark(for: url)
            // Autopilot owns the folder: it may add subfolders and clear the ones it empties.
            let folder = ArchiveFolder(role: .workspace, url: url, bookmark: bookmark,
                                       directoryPermission: ArchiveDirectoryPermission(canCreate: true, canRemoveEmpty: true))
            try await service.configure(ArchiveConfiguration(folders: [folder]))
            state = await service.snapshot()
            activity = .idle
            lastSummary = nil
            if onboardingStep == .folder { onboardingStep = .privacy }
            if screen == .dashboard { startWatching(); organize() }
        } catch { activity = .failed(error.localizedDescription) }
    }

    /// Finishes the guide. With consent the model plans the folder; without it the offline planner does.
    func finishOnboarding(useAI: Bool) {
        defaults.set(true, forKey: Keys.onboarded)
        defaults.set(useAI, forKey: Keys.consent)
        defaults.set(true, forKey: Keys.watching)
        objectWillChange.send()
        startWatching()
        organize()
    }

    func setAI(_ enabled: Bool) {
        if enabled, !isModelConfigured { openModelSettings(); return }
        defaults.set(enabled, forKey: Keys.consent)
        objectWillChange.send()
    }

    // MARK: Running

    func organize() {
        guard runTask == nil, let service else {
            rerunRequested = runTask != nil
            return
        }
        let planner: ArchiveAutopilot.Planner
        if usesAI, let settings, let configuration = try? settings.configuration.validated(),
           let key = try? settings.apiKey(for: configuration.baseURL) {
            planner = { context in
                try await ArchiveAIClient().plan(context: context, preference: ArchiveAIPrompt.defaultPreference,
                                                 configuration: configuration, apiKey: key)
            }
        } else {
            planner = { ArchiveLocalPlanner.plan($0) }
        }
        activity = .working("正在查看文件…")
        runTask = Task { [weak self] in
            let autopilot = ArchiveAutopilot(service: service, planner: planner)
            var failure: String?
            var summary: ArchiveRunSummary?
            do {
                summary = try await autopilot.run { progress in
                    switch progress {
                    case .scanning: self?.activity = .working("正在查看文件…")
                    case .planning(_, let files): self?.activity = .working("正在规划 \(files) 个文件的归类…")
                    case .applying(_, let files): self?.activity = .working("正在整理 \(files) 个文件…")
                    }
                }
            } catch is CancellationError {
            } catch { failure = error.localizedDescription }
            await self?.finishRun(summary: summary, failure: failure)
        }
    }

    private func finishRun(summary: ArchiveRunSummary?, failure: String?) async {
        runTask = nil
        if let service { state = await service.snapshot() }
        if let failure {
            activity = .failed(failure)
            rerunRequested = false
            return
        }
        activity = .idle
        if let summary {
            lastRunAt = Date()
            lastSummary = summary.isEmpty ? lastSummary : summary
            if summary.hasMore { organize(); return }
        }
        if rerunRequested, isWatching {
            rerunRequested = false
            organize()
        }
    }

    func cancelRun() { runTask?.cancel() }

    private func folderChanged() {
        guard isWatching else { return }
        if runTask != nil { rerunRequested = true } else { organize() }
    }

    func setWatching(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.watching)
        if enabled { startWatching(); organize() } else { stopWatching() }
    }

    private func startWatching() {
        guard let workspace else { return }
        let resolved = workspace.bookmark.flatMap { try? SecurityScopedBookmarkService.resolve($0) }
        isWatching = watcher.start(url: resolved ?? workspace.url)
    }

    private func stopWatching() {
        watcher.stop()
        isWatching = false
    }

    // MARK: Undo and reset

    func undo(_ plan: ArchiveAIPlan) async {
        guard let service, runTask == nil else { return }
        let wasWatching = isWatching
        stopWatching()
        activity = .working("正在撤销…")
        defer { if wasWatching { startWatching() } }
        do {
            for operation in plan.files.reversed() where operation.status == .complete {
                try await service.undo(operation.id)
                // A file the user moved back must stay where they put it.
                try await service.markSettled([operation.source.path: operation.fingerprint], removing: [operation.destination.path])
            }
            for operation in plan.directories.reversed() where operation.status == .complete {
                try await service.undoAIDirectory(planID: plan.id, operationID: operation.id)
            }
            activity = .idle
        } catch { activity = .failed(error.localizedDescription) }
        state = await service.snapshot()
    }

    func reorganizeEverything() async {
        guard let service, runTask == nil else { return }
        do {
            try await service.clearSettled()
            state = await service.snapshot()
            organize()
        } catch { activity = .failed(error.localizedDescription) }
    }

    func dismissFailure() { if case .failed = activity { activity = .idle } }

    func openModelSettings() {
        NotificationCenter.default.post(name: .inchspaceOpenSettings, object: nil, userInfo: ["tab": SettingsTab.ai.rawValue])
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
