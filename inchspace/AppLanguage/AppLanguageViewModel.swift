import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppLanguageViewModel: ObservableObject {
    @Published var applications: [LanguageApplication] = []
    @Published var selection: String?
    @Published var search = "" { didSet { reconcileSelection() } }
    @Published var filter: AppLanguageFilter = .all { didSet { reconcileSelection() } }
    @Published var selectedLanguage = ""
    @Published var savedLanguage = ""
    @Published var isScanning = false
    @Published var isSaving = false
    @Published var isRestarting = false

    var isBusy: Bool { isSaving || isRestarting }
    @Published var preferenceReadable = false
    @Published var warnings: [String] = []
    @Published var error: String?
    @Published var status: String?
    private var additionalURLs: [URL] = []
    private let service = AppLanguageService()

    var filteredApplications: [LanguageApplication] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return applications.filter {
            filter.includes($0) && (query.isEmpty
                || $0.name.localizedStandardContains(query)
                || ($0.bundleIdentifier?.localizedStandardContains(query) ?? false)
                || $0.url.path.localizedStandardContains(query))
        }
    }

    func reconcileSelection() {
        let visible = filteredApplications
        if !visible.contains(where: { $0.id == selection }) {
            selection = visible.first?.id
        }
    }

    var selectedApp: LanguageApplication? { applications.first { $0.id == selection } }

    func refresh() async {
        guard !isScanning, !isBusy else { return }
        isScanning = true
        let service = service
        let urls = additionalURLs
        let result = await Task.detached(priority: .userInitiated) {
            service.scan(additionalURLs: urls)
        }.value
        applications = result.applications
        warnings = result.warnings
        isScanning = false
        reconcileSelection()
        loadPreference()
    }

    func loadPreference() {
        status = nil
        selectedLanguage = ""
        savedLanguage = ""
        preferenceReadable = false
        guard let identifier = selectedApp?.bundleIdentifier else { return }
        do {
            savedLanguage = try service.overrideLanguages(for: identifier)?.first ?? ""
            selectedLanguage = savedLanguage
            preferenceReadable = true
        } catch { self.error = error.localizedDescription }
    }

    func save(restart: Bool = false) async {
        guard let app = selectedApp, !isBusy, !isScanning, preferenceReadable else { return }
        isSaving = true
        status = nil
        let language = selectedLanguage.isEmpty ? nil : selectedLanguage
        let service = service
        do {
            try await Task.detached(priority: .userInitiated) { try service.setLanguage(language, for: app) }.value
            savedLanguage = language ?? ""
            status = "已保存，重启后生效。"
            isSaving = false
            if restart { await restartApplication(app) }
        } catch { self.error = error.localizedDescription }
        isSaving = false
    }


    func restartSelectedApplication() async {
        guard let app = selectedApp, !isBusy, !isScanning else { return }
        await restartApplication(app)
    }

    private func restartApplication(_ app: LanguageApplication) async {
        isRestarting = true
        status = "正在重启…"
        defer { isRestarting = false }
        do {
            try await AppLanguageRestartService().restart(app)
            status = "已重新打开。"
        } catch {
            status = "语言设置已保留。"
            self.error = error.localizedDescription
        }
    }

    func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加应用"
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            do {
                for url in panel.urls {
                    _ = try self.service.inspect(url)
                    self.additionalURLs.append(url)
                }
                Task { await self.refresh() }
            } catch { self.error = error.localizedDescription }
        }
    }
}
