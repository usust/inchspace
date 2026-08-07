//
//  LaunchpadIconProvider.swift
//  inchspace
//
//  程序、目录和网站图标的统一异步入口。NSCache 避免滚动和分页时重复解码。
//

import AppKit
import Foundation

@MainActor
final class LaunchpadIconProvider {
    static let shared = LaunchpadIconProvider()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 320
        cache.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(for item: LaunchItem) async -> NSImage {
        let key = item.iconCacheKey as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image: NSImage
        switch item.target {
        case let .application(bundleIdentifier, path):
            if let url = try? LaunchpadOpenService.resolveApplicationURL(
                bundleIdentifier: bundleIdentifier,
                path: path,
                bookmarkData: item.bookmarkData
            ) {
                image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                image = fallbackImage(named: "app.dashed", description: "程序")
            }

        case let .directory(path):
            let url = (try? item.bookmarkData.map(SecurityScopedBookmarkService.resolve)) ?? nil
            image = NSWorkspace.shared.icon(forFile: (url ?? URL(fileURLWithPath: path)).path)

        case let .website(rawURL):
            image = await websiteImage(iconReference: item.iconReference, rawURL: rawURL)
                ?? fallbackImage(named: "globe", description: "网站")
        }

        image.size = NSSize(width: 128, height: 128)
        cache.setObject(image, forKey: key, cost: 128 * 128 * 4)
        return image
    }

    func invalidate(_ item: LaunchItem) {
        cache.removeObject(forKey: item.iconCacheKey as NSString)
    }

    private func websiteImage(iconReference: String?, rawURL: String) async -> NSImage? {
        let iconURL: URL?
        if let iconReference, let explicitURL = URL(string: iconReference) {
            iconURL = explicitURL
        } else if let websiteURL = LaunchpadOpenService.normalizedWebsiteURL(from: rawURL),
                  var components = URLComponents(url: websiteURL, resolvingAgainstBaseURL: false) {
            components.path = "/favicon.ico"
            components.query = nil
            components.fragment = nil
            iconURL = components.url
        } else {
            iconURL = nil
        }

        guard let iconURL else { return nil }
        do {
            var request = URLRequest(url: iconURL)
            request.timeoutInterval = 5
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await URLSession.shared.data(for: request)
            guard data.count <= 4 * 1_024 * 1_024,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { return nil }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    private func fallbackImage(named symbolName: String, description: String) -> NSImage {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
            ?? NSImage(size: NSSize(width: 64, height: 64))
    }
}

extension LaunchItem {
    var iconCacheKey: String {
        "\(target.deduplicationKey)|\(iconReference ?? "")"
    }
}
