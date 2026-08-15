//
//  WebsiteMetadataService.swift
//  inchspace
//
//  读取网页标题和页面声明的图标，供网站快捷方式自动补全。
//

import Foundation

struct WebsiteMetadata: Sendable, Equatable {
    let title: String?
    let iconURLs: [URL]
}

enum WebsiteMetadataService {
    nonisolated static func metadata(for url: URL) async -> WebsiteMetadata? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.cachePolicy = .returnCacheDataElseLoad
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard data.count <= 4 * 1_024 * 1_024,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else { return nil }

            return parse(html: html, baseURL: response.url ?? url)
        } catch {
            return nil
        }
    }

    nonisolated static func parse(html: String, baseURL: URL) -> WebsiteMetadata {
        let title = firstMatch(
            pattern: #"<title\b[^>]*>(.*?)</title\s*>"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        .map(decodeHTMLEntities)
        .map(collapseWhitespace)
        .flatMap { $0.isEmpty ? nil : $0 }

        let linkTags = matches(pattern: #"<link\b[^>]*>"#, in: html, options: [.caseInsensitive])
        let candidates = linkTags.compactMap { tag -> IconCandidate? in
            let attributes = attributes(in: tag)
            let relationships = attributes["rel"]?
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace }) ?? []
            guard relationships.contains(where: { $0 == "icon" || $0 == "apple-touch-icon" }),
                  let href = attributes["href"],
                  let resolved = URL(string: decodeHTMLEntities(href), relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(resolved.scheme?.lowercased() ?? "") else { return nil }

            let declaredSize = attributes["sizes"]?
                .lowercased()
                .split(separator: " ")
                .compactMap { size -> Int? in
                    if size == "any" { return 1_024 }
                    return size.split(separator: "x").compactMap { Int($0) }.max()
                }
                .max() ?? 0
            let typeBonus = attributes["type"]?.lowercased().contains("svg") == true ? 1_024 : 0
            let touchBonus = relationships.contains("apple-touch-icon") ? 180 : 0
            return IconCandidate(url: resolved, score: max(declaredSize, typeBonus, touchBonus))
        }

        var seen = Set<URL>()
        let iconURLs = candidates
            .sorted { $0.score > $1.score }
            .map(\.url)
            .filter { seen.insert($0).inserted }

        return WebsiteMetadata(title: title, iconURLs: iconURLs)
    }

    private struct IconCandidate {
        let url: URL
        let score: Int
    }

    nonisolated private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(tag.startIndex..., in: tag)
        var result: [String: String] = [:]
        for match in expression.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let value = (2...4).compactMap { index -> String? in
                guard match.range(at: index).location != NSNotFound,
                      let range = Range(match.range(at: index), in: tag) else { return nil }
                return String(tag[range])
            }.first ?? ""
            result[String(tag[nameRange]).lowercased()] = value
        }
        return result
    }

    nonisolated private static func firstMatch(
        pattern: String,
        in source: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    nonisolated private static func matches(
        pattern: String,
        in source: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        }
    }

    nonisolated private static func collapseWhitespace(_ source: String) -> String {
        source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    nonisolated private static func decodeHTMLEntities(_ source: String) -> String {
        var result = source
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)

        let numericPattern = #"&#(x?[0-9A-Fa-f]+);"#
        guard let expression = try? NSRegularExpression(pattern: numericPattern, options: .caseInsensitive) else {
            return result
        }
        for match in expression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let wholeRange = Range(match.range(at: 0), in: result),
                  let valueRange = Range(match.range(at: 1), in: result) else { continue }
            let rawValue = String(result[valueRange])
            let radix = rawValue.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(rawValue.dropFirst()) : rawValue
            if let value = UInt32(digits, radix: radix), let scalar = UnicodeScalar(value) {
                result.replaceSubrange(wholeRange, with: String(Character(scalar)))
            }
        }
        return result
    }
}
