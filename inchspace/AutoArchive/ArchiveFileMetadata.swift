import CoreServices
import Foundation

/// What macOS already knows about a file without opening it: its kind, size and dates, and the Spotlight
/// attributes that often say what it is — a title or author, the site it was downloaded from, page count, image
/// size or duration. Many files the model could not place by name alone (`微信图片_….jpg`, `证明材料.zip`) are
/// clear once it sees this.
nonisolated enum ArchiveFileMetadata {
    static func describe(_ url: URL, fingerprint: ArchiveFingerprint) -> [String: String] {
        var result: [String: String] = [:]
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .creationDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        if let kind = values?.localizedTypeDescription { result["kind"] = kind }
        result["size"] = ByteCountFormatter.string(fromByteCount: fingerprint.size, countStyle: .file)
        let day = Date.FormatStyle(date: .numeric, time: .omitted).year().month(.twoDigits).day(.twoDigits)
        result["modified"] = Date(timeIntervalSince1970: TimeInterval(fingerprint.modifiedSeconds)).formatted(day)
        if let created = values?.creationDate { result["created"] = created.formatted(day) }
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return result }

        func text(_ attribute: CFString) -> String? {
            switch MDItemCopyAttribute(item, attribute) {
            case let value as String: clean(value)
            case let values as [String]: clean(values.prefix(4).joined(separator: "、"))
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }
        if let title = text(kMDItemTitle), title != url.deletingPathExtension().lastPathComponent { result["title"] = title }
        if let authors = text(kMDItemAuthors) { result["author"] = authors }
        if let album = text(kMDItemAlbum) { result["album"] = album }
        if let creator = text(kMDItemCreator) { result["app"] = creator }
        if let pages = text(kMDItemNumberOfPages) { result["pages"] = pages }
        if let subject = text(kMDItemSubject) { result["subject"] = subject }
        if let keywords = text(kMDItemKeywords) { result["tags"] = keywords }
        if let comment = text(kMDItemFinderComment) { result["comment"] = comment }
        if let width = text(kMDItemPixelWidth), let height = text(kMDItemPixelHeight) { result["pixels"] = "\(width)×\(height)" }
        if let seconds = (MDItemCopyAttribute(item, kMDItemDurationSeconds) as? NSNumber)?.doubleValue, seconds > 0 {
            result["duration"] = Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
        }
        // Only the site, never the full address: enough to tell a bank statement from a game download.
        if let sources = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] {
            let hosts = sources.compactMap { URL(string: $0)?.host }.filter { !$0.isEmpty }
            if !hosts.isEmpty { result["from"] = Array(NSOrderedSet(array: hosts)).compactMap { $0 as? String }.prefix(2).joined(separator: "、") }
        }
        return result
    }

    private static func clean(_ text: String) -> String? {
        let value = String(text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return value.isEmpty ? nil : value
    }
}
