import AppKit
import Combine
import Foundation

struct HostEditorDraft: Identifiable {
    let id = UUID()
    var entry: HostEntry?
    var address = "127.0.0.1"
    var hostnames = ""
    var comment = ""
}

@MainActor
final class HostsViewModel: ObservableObject {
    @Published var document = HostsDocument(lines: [], endsWithNewline: true)
    @Published var searchText = ""
    @Published var filter: HostsFilter = .all
    @Published var editor: HostEditorDraft?
    @Published var pendingDeletion: HostEntry?
    @Published var presentedError: ServerPresentedError?
    @Published var successMessage: String?
    @Published var showsRaw = false
    @Published var showsBackups = false
    @Published var backups: [URL] = []
    @Published var isSaving = false
    private let service = HostsService()

    var entries: [HostEntry] {
        document.entries.filter { entry in
            let matchesFilter = filter == .all || (filter == .enabled ? entry.enabled : !entry.enabled)
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesFilter && (query.isEmpty || entry.address.localizedCaseInsensitiveContains(query) || entry.hostnameText.localizedCaseInsensitiveContains(query) || entry.comment.localizedCaseInsensitiveContains(query))
        }
    }

    func load() {
        do { document = try service.load() }
        catch { presentedError = ServerPresentedError(error) }
    }

    func newEntry() { editor = HostEditorDraft() }
    func edit(_ entry: HostEntry) { editor = HostEditorDraft(entry: entry, address: entry.address, hostnames: entry.hostnameText, comment: entry.comment) }

    func saveEditor(_ draft: HostEditorDraft) {
        var changed = document
        let hostnames = draft.hostnames.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        do {
            if let entry = draft.entry { try service.update(entry, address: draft.address.trimmingCharacters(in: .whitespaces), hostnames: hostnames, comment: draft.comment, in: &changed) }
            else { try service.add(address: draft.address.trimmingCharacters(in: .whitespaces), hostnames: hostnames, comment: draft.comment, to: &changed) }
            editor = nil; apply(changed)
        } catch { presentedError = ServerPresentedError(error) }
    }

    func toggle(_ entry: HostEntry) {
        var changed = document
        do { try service.setEnabled(!entry.enabled, for: entry, in: &changed); apply(changed) }
        catch { presentedError = ServerPresentedError(error) }
    }

    func deleteConfirmed() {
        guard let entry = pendingDeletion else { return }; pendingDeletion = nil
        var changed = document
        do { try service.delete(entry, from: &changed); apply(changed) }
        catch { presentedError = ServerPresentedError(error) }
    }

    func loadBackups() {
        do { backups = try service.backups(); showsBackups = true }
        catch { presentedError = ServerPresentedError(error) }
    }

    func restore(_ backup: URL) {
        isSaving = true
        let service = self.service
        Task {
            do { try await Task.detached { try service.restore(backup) }.value; document = try service.load(); showsBackups = false; successMessage = "Hosts 备份已恢复。" }
            catch { presentedError = ServerPresentedError(error) }
            isSaving = false
        }
    }

    func flushDNS() {
        let service = self.service
        Task { let success = await Task.detached { service.flushDNS() }.value; successMessage = success ? "DNS 缓存已刷新。" : "DNS 缓存刷新失败，可以稍后重试。" }
    }

    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }

    private func apply(_ changed: HostsDocument) {
        isSaving = true
        let service = self.service
        Task {
            do {
                try await Task.detached { try service.save(changed) }.value
                document = try service.load(); successMessage = "Hosts 已保存。"
            } catch { presentedError = ServerPresentedError(error) }
            isSaving = false
        }
    }
}
