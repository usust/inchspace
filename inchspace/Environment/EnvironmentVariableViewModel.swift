import AppKit
import Combine
import Foundation

@MainActor
final class EnvironmentVariableViewModel: ObservableObject {
    @Published private(set) var variables: [EnvironmentVariable] = []
    @Published private(set) var scanIssues: [EnvironmentScanIssue] = []
    @Published var searchText = ""
    @Published var sourceFilter: EnvironmentSourceFilter = .all
    @Published var selectedVariable: EnvironmentVariable?
    @Published var selectedRowID: String?
    @Published var editingVariable: EnvironmentVariable?
    @Published var editingSource: EnvironmentVariableSource?
    @Published var showsEditor = false
    @Published var showsPathManager = false
    @Published var pathSource: EnvironmentVariableSource?
    @Published var pendingDeletion: EnvironmentVariable?
    @Published var presentedError: EnvironmentPresentedError?
    @Published var toast: String?
    @Published private(set) var isLoading = false

    let service: EnvironmentVariableService
    private let terminalManager: TerminalManager

    init(service: EnvironmentVariableService, terminalManager: TerminalManager) {
        self.service = service
        self.terminalManager = terminalManager
    }

    var filteredVariables: [EnvironmentVariable] {
        variables.filter { variable in
            let matchesSource = sources(for: variable).isEmpty == false
            guard matchesSource else { return false }
            guard !searchText.isEmpty else { return true }
            let displayedSources = sources(for: variable)
            return variable.name.localizedCaseInsensitiveContains(searchText)
                || displayedSources.contains { $0.value.localizedCaseInsensitiveContains(searchText) }
                || displayedSources.contains { $0.displayName.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var sourceFilters: [EnvironmentSourceFilter] {
        [.all] + service.shellConfigURLs.map(EnvironmentSourceFilter.file)
    }

    func sources(for variable: EnvironmentVariable) -> [EnvironmentVariableSource] {
        switch sourceFilter {
        // The process environment contains implementation details injected by
        // macOS and Xcode. It is still used by the service as the inherited
        // environment, but it is not a user-managed configuration source.
        case .all: variable.sources.filter { !$0.isProcessEnvironment }
        case .process: variable.sources.filter(\.isProcessEnvironment)
        case let .file(url): variable.sources.filter { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }
        }
    }

    func displayedValue(for variable: EnvironmentVariable) -> String {
        switch sourceFilter {
        case .all:
            if variable.variableType == .path { return variable.effectiveValue }
            let displayedSources = sources(for: variable)
            return displayedSources.last(where: \.isEnabled)?.value
                ?? displayedSources.last?.value
                ?? variable.effectiveValue
        case .process, .file: return sources(for: variable).last?.value ?? variable.effectiveValue
        }
    }

    func displayedSourceSummary(for variable: EnvironmentVariable) -> String {
        switch sourceFilter {
        case .all: variable.sourceSummary
        case .process, .file: sources(for: variable).last?.displayName ?? variable.sourceSummary
        }
    }

    func displayedStatus(for variable: EnvironmentVariable) -> EnvironmentVariableStatus {
        let displayed = sources(for: variable)
        if !displayed.isEmpty, displayed.allSatisfy({ !$0.isEnabled }) { return .disabled }
        if !displayed.isEmpty, displayed.allSatisfy(\.isProcessEnvironment) { return .readOnly }
        if displayed.contains(where: { $0.isEnabled && $0.isExportedToPath }) { return .exportedToPath }
        return variable.status
    }

    func load() {
        isLoading = true
        variables = service.reloadEnvironment()
        scanIssues = service.scanIssues
        isLoading = false
    }

    func reload() {
        load()
        showToast("环境变量已重新加载")
    }

    func newVariable() {
        editingVariable = nil
        editingSource = nil
        showsEditor = true
    }

    func edit(_ variable: EnvironmentVariable, source: EnvironmentVariableSource) {
        guard source.fileURL != nil, source.isEnabled else { return }
        editingVariable = variable
        editingSource = source
        showsEditor = true
    }

    func open(_ variable: EnvironmentVariable) {
        selectedRowID = variable.id
        let pathSources = editableSources(for: variable).filter(\.isEnabled)
        if variable.variableType == .path, pathSources.count == 1 {
            pathSource = pathSources[0]
            showsPathManager = true
        } else {
            selectedVariable = variable
        }
    }

    func save(name: String, value: String, destination: URL?, exportToPath: Bool) {
        do {
            let variable = try service.updateEnvironmentVariable(
                name: name,
                value: value,
                destination: editingSource?.fileURL ?? destination,
                exportToPath: exportToPath
            )
            let savedURL = editingSource?.fileURL
                ?? destination
                ?? variable.sources.last(where: { !$0.isProcessEnvironment && $0.isEnabled })?.fileURL
            let sourced = savedURL.map(terminalManager.sourceEnvironmentFile) ?? false
            showsEditor = false
            load()
            showToast(sourced ? "\(name) 已保存并在当前终端重新加载" : "\(name) 已保存")
        } catch {
            presentedError = EnvironmentPresentedError(error)
        }
    }

    func editableSources(for variable: EnvironmentVariable) -> [EnvironmentVariableSource] {
        sources(for: variable).filter { $0.fileURL != nil }
    }

    func setEnabled(_ enabled: Bool, variable: EnvironmentVariable, source: EnvironmentVariableSource) {
        guard let url = source.fileURL else { return }
        do {
            if enabled { try service.enableEnvironmentVariable(name: variable.name, in: url) }
            else { try service.disableEnvironmentVariable(name: variable.name, in: url) }
            load()
            showToast("\(variable.name) 已\(enabled ? "启用" : "禁用")")
        } catch {
            presentedError = EnvironmentPresentedError(error)
        }
    }

    func delete(_ variable: EnvironmentVariable, sources: [URL]? = nil) {
        do {
            try service.deleteEnvironmentVariable(name: variable.name, from: sources)
            pendingDeletion = nil
            selectedVariable = nil
            load()
            showToast("\(variable.name) 已删除")
        } catch {
            presentedError = EnvironmentPresentedError(error)
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showToast("已复制")
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if toast == message { toast = nil }
        }
    }
}

struct EnvironmentPresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(_ error: Error, title: String = "操作失败") {
        self.title = title
        message = error.localizedDescription
    }
}
