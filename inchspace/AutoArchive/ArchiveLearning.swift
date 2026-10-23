import Foundation
import NaturalLanguage
import PDFKit

nonisolated enum ArchiveLearning {
    static func tokens(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        var words = Set<String>()
        // Keep the original transparent matching behavior and add native Chinese segmentation.
        if let regex = try? NSRegularExpression(pattern: "[a-z0-9]{3,}|[\\u4e00-\\u9fff]{2,}") {
            let range = NSRange(lower.startIndex..., in: lower)
            for match in regex.matches(in: lower, range: range) {
                if let range = Range(match.range, in: lower) { words.insert(String(lower[range])) }
            }
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = lower
        tokenizer.enumerateTokens(in: lower.startIndex..<lower.endIndex) { range, _ in
            let token = String(lower[range])
            if token.count >= 2, token.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
                words.insert(token)
            }
            return true
        }
        return words
    }

    /// Enough text to tell what a document is about; the model only sees a few dozen keywords anyway, and
    /// parsing a long PDF page by page is where a scan spends most of its time.
    static let textPrefixLimit = 6_000
    static let pdfPageLimit = 8

    static let readableExtensions: Set<String> = ["txt", "md", "csv", "rst", "json", "log", "pdf", "docx"]

    static func extract(_ file: ArchiveEvidence, maxBytes: Int) throws -> ArchiveEvidence {
        // Only the name says anything about a song, a video or an installer: never read their bytes.
        guard readableExtensions.contains(file.url.pathExtension.lowercased()) else {
            return ArchiveEvidence(url: file.url, fingerprint: file.fingerprint,
                                   words: tokens(file.url.deletingPathExtension().lastPathComponent).sorted(),
                                   extractionNote: "此格式仅使用文件名匹配。")
        }
        let (fingerprint, data) = try ArchiveFileSystem.read(file.url, maxBytes: maxBytes)
        guard fingerprint == file.fingerprint else { throw ArchiveError("文件已变化，请重新扫描。") }
        var text = ""
        var note: String?
        switch file.url.pathExtension.lowercased() {
        case "txt", "md", "csv", "rst", "json", "log":
            if let decoded = String(data: data, encoding: .utf8) { text = String(decoded.prefix(textPrefixLimit)) }
            else { note = "非 UTF-8 文本，仅使用文件名匹配。" }
        case "pdf":
            if let document = PDFDocument(data: data), !document.isEncrypted {
                for index in 0..<min(document.pageCount, pdfPageLimit) {
                    text += String((document.page(at: index)?.string ?? "").prefix(textPrefixLimit - text.count)) + " "
                    if text.count >= textPrefixLimit { break }
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { note = "未找到 PDF 文本，不进行 OCR。" }
            } else { note = "PDF 已加密或无法读取，仅使用文件名匹配。" }
        case "docx":
            do { text = String(try ArchiveWordExtractor.text(from: data).prefix(textPrefixLimit)) }
            catch { note = "\(error.localizedDescription) 仅使用文件名匹配。" }
        default:
            note = "此格式仅使用文件名匹配。"
        }
        guard ArchiveFileSystem.matches(file.url, file.fingerprint, maxBytes: maxBytes) else {
            throw ArchiveError("提取过程中，文件发生变化。")
        }
        return ArchiveEvidence(url: file.url, fingerprint: fingerprint,
                               words: tokens(file.url.deletingPathExtension().lastPathComponent + " " + text).sorted(),
                               extractionNote: note)
    }

    static func sample(_ files: [ArchiveEvidence], limit: Int) -> [ArchiveEvidence] {
        var strata = Dictionary(grouping: files) { file in
            let year = Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: TimeInterval(file.fingerprint.modifiedSeconds)))
            return file.url.deletingLastPathComponent().path + "|" + file.url.pathExtension.lowercased() + "|\(year)"
        }
        for key in Array(strata.keys) {
            strata[key]?.sort {
                if $0.fingerprint.modifiedSeconds != $1.fingerprint.modifiedSeconds {
                    return $0.fingerprint.modifiedSeconds > $1.fingerprint.modifiedSeconds
                }
                return $0.url.path < $1.url.path
            }
        }
        let keys = strata.keys.sorted()
        var selected: [ArchiveEvidence] = []
        var round = 0
        while selected.count < limit {
            var added = false
            for key in keys {
                if let records = strata[key], round < records.count {
                    selected.append(records[round])
                    added = true
                    if selected.count == limit { break }
                }
            }
            if !added { break }
            round += 1
        }
        return selected
    }

    static func rules(from samples: [ArchiveEvidence], previous: [ArchiveRule]) -> ([ArchiveRule], [ArchiveEvidence]) {
        var training: [ArchiveEvidence] = []
        var heldOut: [ArchiveEvidence] = []
        // Hold out within each category and always retain at least two training examples.
        let categories = Dictionary(grouping: samples) { $0.url.deletingLastPathComponent() }
        for directory in categories.keys.sorted(by: { $0.path < $1.path }) {
            let records = categories[directory] ?? []
            for (index, record) in records.enumerated() {
                if records.count >= 3 && index % 5 == 4 {
                    heldOut.append(record)
                } else {
                    training.append(record)
                }
            }
        }
        let groups = Dictionary(grouping: training) { $0.url.deletingLastPathComponent() }
        let rules = groups.map { directory, evidence in
            var counts: [String: Int] = [:]
            var extensions: [String: Int] = [:]
            for file in evidence {
                for word in Set(file.words) { counts[word, default: 0] += 1 }
                extensions[file.url.pathExtension.lowercased(), default: 0] += 1
            }
            let keywords = counts.filter { $0.value >= 2 }.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.prefix(40).map(\.key)
            return ArchiveRule(directory: directory, aliases: tokens(directory.lastPathComponent).sorted(),
                               keywords: keywords, extensions: extensions, evidence: evidence,
                               confirmed: previous.contains { $0.directory == directory && $0.confirmed && $0.evidence == evidence })
        }.sorted { $0.directory.path < $1.directory.path }
        return (rules, heldOut)
    }

    static func rank(_ rules: [ArchiveRule], words: Set<String>) -> [(rule: ArchiveRule, score: Int)] {
        rules.compactMap { rule in
            let score = words.intersection(rule.aliases).count * 4 + words.intersection(rule.keywords).count
            return score > 0 ? (rule, score) : nil
        }.sorted {
            $0.score == $1.score ? $0.rule.id < $1.rule.id : $0.score > $1.score
        }
    }
}
