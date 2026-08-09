//
//  AppRepairViewModel.swift
//  inchspace
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppRepairViewModel: ObservableObject {
    enum Phase: Equatable {
        case empty
        case inspecting
        case ready
        case repairing
        case repaired
    }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var report: AppRepairReport?
    @Published var presentedError: PresentedError?
    private var bookmarkData: Data?
    private let service = AppRepairService()

    func selectApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择需要修复的应用"
        panel.prompt = "检测"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.inspect(url)
        }
    }

    func inspect(_ url: URL) {
        guard phase != .inspecting, phase != .repairing else { return }
        guard url.pathExtension.lowercased() == "app" else {
            present(AppRepairError.invalidApplication)
            return
        }

        phase = .inspecting
        report = nil
        do {
            bookmarkData = try SecurityScopedBookmarkService.makeWritableBookmark(for: url)
        } catch {
            phase = .empty
            present(error)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let service = self.service
            do {
                let inspected = try await performWithSecurityScopedAccess(to: url) { scopedURL in
                    try service.inspect(scopedURL)
                }
                report = inspected
                phase = .ready
            } catch {
                phase = .empty
                present(error)
            }
        }
    }

    func repair() {
        guard let report, phase == .ready else { return }
        phase = .repairing
        Task { [weak self] in
            guard let self else { return }
            let service = self.service
            do {
                let repaired = try await performWithSecurityScopedAccess(to: report.url) { scopedURL in
                    try service.repair(scopedURL)
                }
                self.report = repaired
                phase = .repaired
            } catch {
                phase = .ready
                present(error)
            }
        }
    }

    func openApplication() {
        guard let url = report?.url else { return }
        Task {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.openApplication(
                        at: url,
                        configuration: NSWorkspace.OpenConfiguration()
                    ) { _, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: ()) }
                    }
                }
            } catch {
                present(error)
            }
        }
    }

    func reset() {
        report = nil
        bookmarkData = nil
        phase = .empty
    }

    private func performWithSecurityScopedAccess<T: Sendable>(
        to fallbackURL: URL,
        operation: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        let url = try bookmarkData.map(SecurityScopedBookmarkService.resolve) ?? fallbackURL
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try await Task.detached { try operation(url) }.value
    }

    private func present(_ error: Error) {
        presentedError = PresentedError(title: "无法完成操作", message: error.localizedDescription)
    }
}
