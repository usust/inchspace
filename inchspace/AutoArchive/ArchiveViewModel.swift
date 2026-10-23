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

/// Which rows of the file list are shown.
enum ArchiveEntryFilter: String, CaseIterable, Identifiable {
    case all, moved, renamed, unplaced, failed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .moved: "已移动"
        case .renamed: "已改名"
        case .unplaced: "未归位"
        case .failed: "失败"
        }
    }
}

/// One row of the file list: a file autopilot has looked at, live from this run or saved from an earlier one.
struct ArchiveFileEntry: Identifiable, Equatable {
    enum Change: Equatable {
        case none
        case renamed(from: String, to: String)
        case moved(from: String, to: String)
        case movedAndRenamed(fromFolder: String, toFolder: String, fromName: String, toName: String)
    }

    var id: String { path }
    /// Current path of the file (after any move).
    var path: String
    var status: ArchiveFileActivity.Status
    var detail: String?
    var record: ArchiveFileRecord?
    var updatedAt: Date
    /// True for files touched by the run in progress or the one just finished.
    var isLive: Bool
    /// Folder relative to the workspace; empty for the workspace itself.
    var folder: String

    var name: String { (path as NSString).lastPathComponent }
    var topic: String { record?.topic ?? "" }

    var change: Change {
        guard let record else { return .none }
        let renamed = record.wasRenamed
        let moved = record.previousFolder != nil && record.previousFolder != folder
        switch (moved, renamed) {
        case (true, true): return .movedAndRenamed(fromFolder: record.previousFolder ?? "", toFolder: folder, fromName: record.originalName, toName: record.name)
        case (true, false): return .moved(from: record.previousFolder ?? "", to: folder)
        case (false, true): return .renamed(from: record.originalName, to: record.name)
        case (false, false): return .none
        }
    }

    var isMoved: Bool { if case .none = change { return false }; if case .renamed = change { return false }; return true }
    var isRenamed: Bool { record?.wasRenamed == true }
}

@MainActor
final class ArchiveViewModel: ObservableObject {
    static let shared = ArchiveViewModel()

    private enum Keys {
        static let consent = "archive.autopilot.aiConsent"
        static let onboarded = "archive.autopilot.onboarded"
        static let watching = "archive.autopilot.watching"
    }

    @Published private(set) var state = ArchiveState() { didSet { rebuildEntries() } }
    @Published private(set) var isReady = false
    @Published private(set) var loadError: String?
    @Published var onboardingStep: ArchiveOnboardingStep = .welcome
    @Published private(set) var activity: ArchiveActivity = .idle
    /// Live detail for the status card while a run is in progress.
    @Published private(set) var progress: ArchiveRunProgress?
    @Published private(set) var runStartedAt: Date?
    @Published private(set) var isWatching = false
    @Published private(set) var lastSummary: ArchiveRunSummary?
    @Published private(set) var lastRunAt: Date?
    /// Files seen by recent runs, the ones still in flight first, then newest result first.
    @Published private(set) var fileActivity: [ArchiveFileActivity] = [] { didSet { rebuildEntries() } }
    /// Every file with a result, live ones first, newest first.
    @Published private(set) var entries: [ArchiveFileEntry] = []
    @Published var filter: ArchiveEntryFilter = .all
    @Published var searchText = ""
    @Published var selectedPath: String?

    private let defaults: UserDefaults
    private var service: ArchiveService?
    private var settings: TerminalAISettings?
    private var settingsObserver: AnyCancellable?
    private var runTask: Task<Void, Never>?
    private var rerunRequested = false
    private lazy var watcher = ArchiveFolderWatcher { [weak self] in self?.folderChanged() }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var workspace: ArchiveFolder? { state.configuration.folders.first { $0.role == .workspace } }
    var isOnboarded: Bool { defaults.bool(forKey: Keys.onboarded) || defaults.bool(forKey: Keys.consent) }
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

    /// Organizing is done by the model only; without a working connection nothing starts.
    var isModelConfigured: Bool {
        guard let settings, let configuration = try? settings.configuration.validated() else { return false }
        return (try? settings.apiKey(for: configuration.baseURL)) != nil
    }

    var modelName: String? { try? settings?.configuration.validated().model }

    func attach(settings: TerminalAISettings) {
        guard self.settings !== settings else { return }
        self.settings = settings
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

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
            fileActivity = []
            selectedPath = nil
            state = await service.snapshot()
            activity = .idle
            lastSummary = nil
            if onboardingStep == .folder { onboardingStep = .privacy }
            if screen == .dashboard { startWatching(); organize() }
        } catch { activity = .failed(error.localizedDescription) }
    }

    /// Finishes the guide; the model plans the folder from here on.
    func finishOnboarding() {
        defaults.set(true, forKey: Keys.onboarded)
        defaults.set(true, forKey: Keys.consent)
        defaults.set(true, forKey: Keys.watching)
        objectWillChange.send()
        startWatching()
        organize()
    }

    // MARK: Running

    func organize() {
        guard runTask == nil, let service else {
            rerunRequested = runTask != nil
            return
        }
        guard let settings, let configuration = try? settings.configuration.validated(),
              let key = try? settings.apiKey(for: configuration.baseURL) else {
            // Nothing runs without a model; the status strip says so and offers the settings.
            objectWillChange.send()
            return
        }
        let tuning = ArchiveAITuning.tuning(for: configuration)
        let planner = ArchiveStagePlanner.ai(configuration: configuration, apiKey: key, tuning: tuning) { [weak self] received in
            // Chunks arrive far faster than the eye can follow; publish roughly 20 characters at a time.
            guard let current = self?.progress?.receivedCharacters, received < current || received - current >= 20 else { return }
            self?.progress?.receivedCharacters = received
        }
        progress = ArchiveRunProgress()
        runStartedAt = Date()
        activity = .working(title(for: ArchiveRunProgress()))
        // Utility priority: the model and the disk get their breathing room, the UI stays first.
        runTask = Task(priority: .utility) { [weak self] in
            var autopilot = ArchiveAutopilot(service: service, planner: planner)
            autopilot.batchSize = tuning.batchSize
            autopilot.reviewBatch = tuning.reviewBatch
            autopilot.keywordLimit = tuning.keywordLimit
            autopilot.siblingLimit = tuning.siblingLimit
            autopilot.cooldown = .milliseconds(Int(tuning.cooldown * 1_000))
            autopilot.report = { [weak self] updates in self?.record(updates) }
            var failure: String?
            var summary: ArchiveRunSummary?
            do {
                summary = try await autopilot.run { progress in
                    guard let self else { return }
                    self.progress = progress
                    self.activity = .working(self.title(for: progress))
                }
            } catch is CancellationError {
            } catch { failure = error.localizedDescription }
            await self?.finishRun(summary: summary, failure: failure)
        }
    }

    private static let fileActivityLimit = 300
    private static let entryLimit = 600

    private func record(_ updates: [ArchiveFileActivity]) {
        guard !updates.isEmpty else { return }
        let changed = Set(updates.map(\.path))
        var merged = fileActivity.filter { !changed.contains($0.path) } + updates
        merged.sort { lhs, rhs in
            let left = lhs.status == .processing, right = rhs.status == .processing
            return left != right ? left : lhs.updatedAt > rhs.updatedAt
        }
        fileActivity = Array(merged.prefix(Self.fileActivityLimit))
    }

    func clearFileActivity() { fileActivity.removeAll { $0.status != .processing } }

    /// Counts for the status strip: what this run has done so far.
    var liveCounts: (completed: Int, unplaced: Int, failed: Int, waiting: Int) {
        var counts = (completed: 0, unplaced: 0, failed: 0, waiting: 0)
        for item in fileActivity {
            switch item.status {
            case .completed: counts.completed += 1
            case .unplaced: counts.unplaced += 1
            case .skipped, .failed: counts.failed += 1
            case .queued, .processing: counts.waiting += 1
            }
        }
        return counts
    }

    // MARK: File list

    private func rebuildEntries() {
        let root = workspace?.url.path ?? ""
        func relativeFolder(_ path: String) -> String {
            let folder = (path as NSString).deletingLastPathComponent
            guard !root.isEmpty, folder.hasPrefix(root) else { return folder }
            return String(folder.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        var byPath: [String: ArchiveFileEntry] = [:]
        for (path, record) in state.files ?? [:] {
            let status: ArchiveFileActivity.Status = switch record.resolution ?? .organized {
            case .organized: .completed
            case .unplaced: .unplaced
            case .unrecognized: .skipped
            }
            byPath[path] = ArchiveFileEntry(path: path, status: status, detail: nil, record: record,
                                            updatedAt: record.processedAt, isLive: false, folder: relativeFolder(path))
        }
        for item in fileActivity {
            // A live item is keyed by where the file was when the run picked it up; a saved result knows where it went.
            let path = item.record?.path ?? item.path
            if path != item.path { byPath.removeValue(forKey: item.path) }
            var entry = byPath[path] ?? ArchiveFileEntry(path: path, status: item.status, detail: item.detail, record: nil,
                                                          updatedAt: item.updatedAt, isLive: true, folder: relativeFolder(path))
            entry.status = item.status
            entry.detail = item.detail
            entry.updatedAt = max(entry.updatedAt, item.updatedAt)
            entry.isLive = true
            if let record = item.record { entry.record = record }
            byPath[path] = entry
        }
        var list = Array(byPath.values)
        list.sort { lhs, rhs in
            let left = lhs.status == .processing, right = rhs.status == .processing
            if left != right { return left }
            if lhs.isLive != rhs.isLive { return lhs.isLive }
            return lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.path < rhs.path
        }
        entries = Array(list.prefix(Self.entryLimit))
        if let selectedPath, !entries.contains(where: { $0.path == selectedPath }) {
            // The selected file moved: follow it to its new path when the record went along.
            self.selectedPath = entries.first { $0.record?.originalName == (selectedPath as NSString).lastPathComponent && $0.isLive }?.path
        }
    }

    var filteredEntries: [ArchiveFileEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            switch filter {
            case .all: break
            case .moved: guard entry.isMoved else { return false }
            case .renamed: guard entry.isRenamed else { return false }
            case .unplaced: guard entry.status == .unplaced else { return false }
            case .failed: guard entry.status == .failed || entry.status == .skipped else { return false }
            }
            guard !needle.isEmpty else { return true }
            return entry.name.lowercased().contains(needle) || entry.folder.lowercased().contains(needle)
                || entry.topic.lowercased().contains(needle) || (entry.record?.summary ?? "").lowercased().contains(needle)
                || (entry.record?.originalName ?? "").lowercased().contains(needle)
        }
    }

    var selectedEntry: ArchiveFileEntry? { selectedPath.flatMap { path in entries.first { $0.path == path } } }

    /// The journal entry that moved the file, while it can still be undone.
    func undoableOperation(for entry: ArchiveFileEntry) -> ArchiveOperation? {
        guard let id = entry.record?.operationID else { return nil }
        return state.operations.first { $0.id == id && $0.status == .complete && $0.destination.path == entry.path }
    }

    func fileExists(_ entry: ArchiveFileEntry) -> Bool { ArchiveFileSystem.exists(URL(fileURLWithPath: entry.path)) }

    private func title(for progress: ArchiveRunProgress) -> String {
        switch progress.phase {
        case .scanning: progress.round == 0 ? "正在查看文件…" : "正在重新扫描文件夹…"
        case .waitingForStableFiles: "等待 \(progress.remainingFiles) 个新文件写入完成…"
        case .consolidating: "正在合并含义相同的文件夹…"
        case .reviewing: progress.batchFiles > 1 ? "正在识别 \(progress.batchFiles) 个文件…" : "正在查看「\(progress.directory)」…"
        case .grouping: "正在为「\(progress.directory)」中的 \(progress.batchFiles) 个文件归类…"
        case .nesting: "正在梳理「\(progress.directory)」的文件夹层级…"
        case .applying: "正在应用更改…"
        }
    }

    /// Secondary line under the title: where this run stands and whether the model is talking.
    var progressDetail: String? {
        guard let progress, case .working = activity else { return nil }
        var parts: [String] = []
        if progress.round > 0 { parts.append("第 \(progress.round) 轮") }
        if progress.totalFiles > 0 { parts.append("已处理 \(progress.processedFiles)/\(progress.totalFiles) 个文件") }
        if [.consolidating, .reviewing, .grouping, .nesting].contains(progress.phase) {
            parts.append(progress.receivedCharacters > 0 ? "模型已回复 \(progress.receivedCharacters) 字" : "等待模型回复")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func finishRun(summary: ArchiveRunSummary?, failure: String?) async {
        runTask = nil
        progress = nil
        runStartedAt = nil
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
                try await undoOperation(operation, service: service)
            }
            for operation in plan.directories.reversed() where operation.status == .complete {
                try await service.undoAIDirectory(planID: plan.id, operationID: operation.id)
            }
            activity = .idle
        } catch { activity = .failed(error.localizedDescription) }
        fileActivity.removeAll { item in plan.files.contains { $0.source.path == item.path || $0.destination.path == (item.record?.path ?? item.path) } }
        state = await service.snapshot()
    }

    /// Puts one file back where it was, leaving the rest of its batch alone.
    func undoFile(_ entry: ArchiveFileEntry) async {
        guard let service, runTask == nil, let operation = undoableOperation(for: entry) else { return }
        let wasWatching = isWatching
        stopWatching()
        activity = .working("正在撤销…")
        defer { if wasWatching { startWatching() } }
        do {
            try await undoOperation(operation, service: service)
            activity = .idle
        } catch { activity = .failed(error.localizedDescription) }
        fileActivity.removeAll { ($0.record?.path ?? $0.path) == entry.path || $0.path == operation.source.path }
        selectedPath = operation.source.path
        state = await service.snapshot()
    }

    private func undoOperation(_ operation: ArchiveOperation, service: ArchiveService) async throws {
        try await service.undo(operation.id)
        // A file the user moved back must stay where they put it, with its result still recorded.
        try await service.markSettled([operation.source.path: operation.fingerprint], removing: [operation.destination.path])
        try await service.moveRecords(from: operation.destination.path, to: operation.source.path)
    }

    func reorganizeEverything() async {
        guard let service, runTask == nil else { return }
        do {
            try await service.clearSettled()
            fileActivity = []
            selectedPath = nil
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
