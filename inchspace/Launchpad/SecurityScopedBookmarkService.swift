//
//  SecurityScopedBookmarkService.swift
//  inchspace
//

import Foundation

enum SecurityScopedBookmarkService {
    enum BookmarkError: LocalizedError {
        case unavailable
        case stale

        var errorDescription: String? {
            switch self {
            case .unavailable: "无法恢复该位置的访问权限，请重新选择。"
            case .stale: "该位置的授权已失效，请重新选择。"
            }
        }
    }

    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        )
    }

    static func makeWritableBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        )
    }

    /// A code-signing-independent location reference used as a fallback by
    /// non-sandboxed builds when an app-scoped bookmark no longer matches the
    /// identity of an updated application.
    static func makeLocationBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        )
    }

    nonisolated static func resolve(_ data: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw BookmarkError.stale }
        return url
    }

    nonisolated static func resolveLocation(_ data: Data) throws -> URL {
        var isStale = false
        return try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    static func withAccess<T>(to data: Data?, fallbackURL: URL, operation: (URL) throws -> T) throws -> T {
        let url = try data.map(resolve) ?? fallbackURL
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        return try operation(url)
    }
}
