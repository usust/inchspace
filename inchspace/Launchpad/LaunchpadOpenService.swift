//
//  LaunchpadOpenService.swift
//  inchspace
//

import AppKit
import Foundation

@MainActor
enum LaunchpadOpenService {
    /// 打开成功后保留目标应用身份，供窗口协调器隐藏自身后恢复前台焦点。
    struct OpenedDestination {
        let runningApplication: NSRunningApplication?
        let bundleIdentifier: String?

        func activate() {
            let application = runningApplication
                ?? bundleIdentifier.flatMap {
                    NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
                }
            application?.activate(options: [.activateAllWindows])
        }
    }

    enum OpenError: LocalizedError {
        case applicationUnavailable
        case directoryUnavailable
        case invalidWebsite
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case .applicationUnavailable: "找不到这个程序。你可以删除快捷方式后重新添加。"
            case .directoryUnavailable: "目录不存在或授权已失效，请重新选择该目录。"
            case .invalidWebsite: "网站地址无效，请检查后重试。"
            case let .openFailed(message): "无法打开：\(message)"
            }
        }
    }

    static func open(_ item: LaunchItem) async throws -> OpenedDestination {
        switch item.target {
        case let .application(bundleIdentifier, path):
            let applicationURL = try resolveApplicationURL(
                bundleIdentifier: bundleIdentifier,
                path: path,
                bookmarkData: item.bookmarkData
            )
            let didStart = applicationURL.startAccessingSecurityScopedResource()
            defer {
                if didStart { applicationURL.stopAccessingSecurityScopedResource() }
            }
            let application = try await openApplication(at: applicationURL)
            return OpenedDestination(
                runningApplication: application,
                bundleIdentifier: application.bundleIdentifier ?? bundleIdentifier
            )

        case let .directory(path):
            let fallbackURL = URL(fileURLWithPath: path, isDirectory: true)
            let didOpen = try SecurityScopedBookmarkService.withAccess(
                to: item.bookmarkData,
                fallbackURL: fallbackURL
            ) { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw OpenError.directoryUnavailable
                }
                return NSWorkspace.shared.open(url)
            }
            guard didOpen else { throw OpenError.directoryUnavailable }
            return OpenedDestination(
                runningApplication: nil,
                bundleIdentifier: "com.apple.finder"
            )

        case let .website(rawURL):
            guard let url = normalizedWebsiteURL(from: rawURL) else {
                throw OpenError.invalidWebsite
            }
            let browserURL = NSWorkspace.shared.urlForApplication(toOpen: url)
            let browserBundleIdentifier = browserURL
                .flatMap(Bundle.init(url:))?
                .bundleIdentifier
            guard NSWorkspace.shared.open(url) else {
                throw OpenError.openFailed(url.absoluteString)
            }
            return OpenedDestination(
                runningApplication: nil,
                bundleIdentifier: browserBundleIdentifier
            )
        }
    }

    static func revealInFinder(_ item: LaunchItem) throws {
        switch item.target {
        case let .application(bundleIdentifier, path):
            let fallbackURL = try resolveApplicationURL(
                bundleIdentifier: bundleIdentifier,
                path: path,
                bookmarkData: nil
            )
            try SecurityScopedBookmarkService.withAccess(to: item.bookmarkData, fallbackURL: fallbackURL) { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case let .directory(path):
            try SecurityScopedBookmarkService.withAccess(
                to: item.bookmarkData,
                fallbackURL: URL(fileURLWithPath: path, isDirectory: true)
            ) { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .website:
            return
        }
    }

    static func normalizedWebsiteURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: String
        if trimmed.range(of: "://") == nil {
            candidate = "https://\(trimmed)"
        } else {
            candidate = trimmed
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              let url = components.url else { return nil }
        return url
    }

    static func resolveApplicationURL(
        bundleIdentifier: String,
        path: String?,
        bookmarkData: Data?
    ) throws -> URL {
        if let bookmarkData,
           let bookmarkedURL = try? SecurityScopedBookmarkService.resolve(bookmarkData),
           FileManager.default.fileExists(atPath: bookmarkedURL.path) {
            return bookmarkedURL
        }
        if let path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if !bundleIdentifier.isEmpty,
           let installedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return installedURL
        }
        throw OpenError.applicationUnavailable
    }

    private static func openApplication(at url: URL) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { application, error in
                if let error {
                    continuation.resume(throwing: OpenError.openFailed(error.localizedDescription))
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing: OpenError.applicationUnavailable)
                }
            }
        }
    }
}
