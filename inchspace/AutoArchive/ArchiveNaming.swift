import Foundation

/// Every file name is passed through here before it is written, whether the model proposed it or a merge needed a
/// free name: noise is removed, separators and dates are made uniform, the template's field order is restored and
/// the original's identifiers are kept. The model's name is a suggestion; this is what decides.
nonisolated enum ArchiveNameNormalizer {
    enum Field: Int, CaseIterable, Comparable, Sendable {
        case subject, type, date, number, version

        var title: String {
            switch self {
            case .subject: "主题"
            case .type: "类型"
            case .date: "日期"
            case .number: "编号"
            case .version: "版本"
            }
        }

        static func < (lhs: Field, rhs: Field) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The name to write and, when the proposal could not be used, the proposal kept for review.
    struct Resolution: Equatable, Sendable {
        var name: String
        var suggestion: String?
    }

    /// The name a file gets in a folder with `pattern`: the proposal corrected to the convention, else the original
    /// name cleaned up, else the original name untouched. A proposal that cannot be corrected is returned as the
    /// suggestion.
    static func resolve(_ proposed: String?, original: String, pattern: ArchiveNamingPattern, rule: ArchiveNamingRule) -> Resolution {
        let originalURL = URL(fileURLWithPath: "/" + original)
        func accepted(_ candidate: String?) -> String? {
            guard let candidate, let name = normalize(candidate, original: original, pattern: pattern, rule: rule) else { return nil }
            return (try? ArchiveAINamePolicy.validate(name, original: originalURL)) == nil ? nil : name
        }
        if let proposed, proposed != original, let name = accepted(proposed) { return Resolution(name: name, suggestion: nil) }
        let suggestion = proposed.flatMap { $0 == original ? nil : $0 }
        if let name = accepted(original) { return Resolution(name: name, suggestion: suggestion) }
        return Resolution(name: original, suggestion: suggestion)
    }

    /// The proposal rewritten to the convention, with the original's extension and identifiers; nil when nothing
    /// usable is left.
    static func normalize(_ proposed: String, original: String, pattern: ArchiveNamingPattern, rule: ArchiveNamingRule) -> String? {
        let ext = (original as NSString).pathExtension
        var stem = proposed.precomposedStringWithCanonicalMapping
        let proposedExt = (stem as NSString).pathExtension
        // A wrong extension is dropped and the original one restored; `Setup 1.2` keeps its `.2`, which is no extension.
        if proposedExt.caseInsensitiveCompare(ext) == .orderedSame && !ext.isEmpty {
            stem = (stem as NSString).deletingPathExtension
        } else if !proposedExt.isEmpty, proposedExt.count <= 5, proposedExt.contains(where: \.isLetter) {
            stem = (stem as NSString).deletingPathExtension
        }
        stem = String(stem.unicodeScalars.map { scalar -> Character in
            scalar.value < 0x20 || scalar.value == 0x7f || "/:\\".unicodeScalars.contains(scalar) ? " " : Character(scalar)
        })
        var result = normalizeStem(stem, pattern: pattern, rule: rule)
        let missing = identifiers(in: (original as NSString).deletingPathExtension).filter { !contains($0, in: result) }
        if !missing.isEmpty {
            let joiner = pattern.kind == .artistTitle ? " " : ArchiveNamingRule.fieldSeparator
            result = normalizeStem(([result] + missing).filter { !$0.isEmpty }.joined(separator: joiner), pattern: pattern, rule: rule)
        }
        while result.hasPrefix(".") || result.hasPrefix("~") { result.removeFirst() }
        guard !result.isEmpty else { return nil }
        var name = ext.isEmpty ? result : result + "." + ext
        while name.utf8.count > 240, !result.isEmpty {
            result.removeLast()
            name = ext.isEmpty ? result : result + "." + ext
        }
        return name
    }

    /// True when the name already follows the folder's pattern: normalizing it changes nothing.
    static func conforms(_ name: String, pattern: ArchiveNamingPattern, rule: ArchiveNamingRule) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        guard !stem.isEmpty else { return true }
        return normalizeStem(stem, pattern: pattern, rule: rule) == stem
    }

    /// A free name for a file whose name is taken: the template's number field, never `name (2).ext`.
    static func distinguish(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(ArchiveFileSystem.nameKey(name)) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for number in 2...999 {
            let candidate = stem + ArchiveNamingRule.fieldSeparator + String(number) + (ext.isEmpty ? "" : "." + ext)
            if !taken.contains(ArchiveFileSystem.nameKey(candidate)) { return candidate }
        }
        return stem + ArchiveNamingRule.fieldSeparator + String(UUID().uuidString.prefix(8)) + (ext.isEmpty ? "" : "." + ext)
    }

    // MARK: Pieces

    /// Full-width brackets, spaces and separators replaced by their ASCII forms.
    static func fold(_ text: String) -> String {
        let pairs: [(String, String)] = [("（", "("), ("）", ")"), ("【", "["), ("】", "]"), ("［", "["), ("］", "]"),
                                         ("　", " "), ("＿", "_"), ("－", "-"), ("—", "-"), ("–", "-")]
        return pairs.reduce(text.precomposedStringWithCanonicalMapping) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// Dates written any common way (`20261019`, `2026.10.19`, `2026年10月19日`) as `2026-10-19`, set apart by spaces.
    static func normalizeDates(_ text: String) -> String {
        var result = text
        let patterns = [
            "(?<![0-9])((?:19|20)[0-9]{2})年([0-9]{1,2})月([0-9]{1,2})日?(?![0-9])",
            "(?<![0-9])((?:19|20)[0-9]{2})([-._/])([0-9]{1,2})\\2([0-9]{1,2})(?![0-9])",
            "(?<![0-9])((?:19|20)[0-9]{2})(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])(?![0-9])",
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let source = result as NSString
            var output = ""
            var cursor = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)) {
                let groups = (1..<match.numberOfRanges).map { source.substring(with: match.range(at: $0)) }
                let (year, month, day) = index == 1 ? (groups[0], groups[2], groups[3]) : (groups[0], groups[1], groups[2])
                guard let m = Int(month), let d = Int(day), (1...12).contains(m), (1...31).contains(d) else { continue }
                output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                output += " " + String(format: "%@-%02d-%02d", year, m, d) + " "
                cursor = match.range.location + match.range.length
            }
            output += source.substring(from: cursor)
            result = output
        }
        return result
    }

    /// Downloader suffixes, copy markers and "final" versions removed; blanks and separators collapsed.
    static func stripNoise(_ text: String) -> String {
        var result = fold(text)
        let noise = [
            "(?i)^copy of\\s+",
            "\\s*[(\\[]\\s*[0-9]{1,3}\\s*[)\\]]",
            "\\s*-?\\s*副本\\s*[0-9]*",
            "(?i)\\s*-?\\s*(?<![A-Za-z])copy(?:\\s*[0-9]{1,3})?(?![A-Za-z0-9])",
            "(?i)(?<![A-Za-z])final(?:[-_ ]?version)?(?![A-Za-z])",
            "(?:最终版|最终稿|终稿|终版|定稿)\\s*[0-9]*",
        ]
        for pattern in noise {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "[(\\[]\\s*[)\\]]", with: " ", options: .regularExpression)
        return collapse(result)
    }

    /// Runs of blanks become one space, runs of underscores (with blanks around) one underscore, runs of hyphens one
    /// hyphen; separators and stray punctuation at either end are dropped.
    static func collapse(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "[\\s]*_[\\s_]*", with: "_", options: .regularExpression)
        result = result.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        result = result.replacingOccurrences(of: "_-+_", with: "_", options: .regularExpression)
        return result.trimmingCharacters(in: edgePunctuation)
    }

    private static let edgePunctuation = CharacterSet(charactersIn: " _-.,;:·~!@#$%^&*+=|'\"`，。、；：！？")

    /// Number-bearing identifiers that must survive any rename (dates, invoice numbers, versions), without the noise
    /// that only looks like one (`(1)`, `copy 2`). Dates are given in `YYYY-MM-DD`, however the original wrote them.
    static func identifiers(in stem: String) -> [String] {
        let text = normalizeDates(stripNoise(stem))
        let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*")
        let source = text as NSString
        var result: [String] = []
        for match in regex?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? [] {
            let token = source.substring(with: match.range)
            if token.contains(where: \.isNumber), !result.contains(token) { result.append(token) }
        }
        return result
    }

    /// Whether `identifier` appears in `stem` as a whole token, with dates compared in their normalized form.
    static func contains(_ identifier: String, in stem: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: identifier) + "(?![A-Za-z0-9])"
        return normalizeDates(fold(stem)).range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Template

    private struct Parsed {
        var texts: [[String]] = []
        var dates: [String] = []
        var numbers: [String] = []
        var versions: [String] = []
    }

    private static func isDate(_ token: String) -> Bool {
        token.range(of: "^(19|20)[0-9]{2}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    }

    private static func isVersion(_ token: String) -> Bool {
        token.range(of: "^([vV][0-9]+(\\.[0-9]+)*|[0-9]+(\\.[0-9]+){1,3})$", options: .regularExpression) != nil
    }

    private static func isNumber(_ token: String) -> Bool {
        token.range(of: "^([0-9]+|[A-Z]{1,6}-?[0-9]+(-[0-9]+)*|[0-9]+(-[0-9]+)+)$", options: .regularExpression) != nil
    }

    private static func parse(_ stem: String) -> Parsed {
        var parsed = Parsed()
        for segment in stem.split(separator: "_", omittingEmptySubsequences: true) {
            var words: [String] = []
            for raw in segment.split(whereSeparator: \.isWhitespace) {
                // Only the ends are trimmed; the dots of `1.2` and the hyphens of `INV-0042` stay.
                let chunk = String(raw).trimmingCharacters(in: edgePunctuation)
                guard !chunk.isEmpty, chunk.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                if isDate(chunk) { if !parsed.dates.contains(chunk) { parsed.dates.append(chunk) } }
                else if isVersion(chunk) { if !parsed.versions.contains(chunk) { parsed.versions.append(chunk) } }
                else if isNumber(chunk) { if !parsed.numbers.contains(chunk) { parsed.numbers.append(chunk) } }
                else {
                    words += chunk.split(separator: "-").map { String($0).trimmingCharacters(in: edgePunctuation) }.filter { !$0.isEmpty }
                }
            }
            if !words.isEmpty { parsed.texts.append(words) }
        }
        return parsed
    }

    /// The fields a stem carries under the template, for deriving a folder's common pattern.
    static func fields(of stem: String, rule: ArchiveNamingRule) -> [Field] {
        let parsed = parse(normalizeDates(stripNoise(stem)))
        var fields: [Field] = []
        if !parsed.texts.isEmpty { fields.append(.subject) }
        if parsed.texts.count > 1 { fields.append(.type) }
        if !parsed.dates.isEmpty { fields.append(.date) }
        if !parsed.numbers.isEmpty { fields.append(.number) }
        if !parsed.versions.isEmpty { fields.append(.version) }
        return fields
    }

    static func normalizeStem(_ stem: String, pattern: ArchiveNamingPattern, rule: ArchiveNamingRule) -> String {
        let cleaned = collapse(normalizeDates(stripNoise(stem)))
        switch pattern.kind {
        case .artistTitle:
            let parts = cleaned.replacingOccurrences(of: "_", with: " ")
                .components(separatedBy: " - ")
                .map { collapse($0) }
                .filter { !$0.isEmpty }
            return parts.joined(separator: " - ")
        case .template:
            let parsed = parse(cleaned)
            let texts = parsed.texts.map { $0.joined(separator: rule.wordSeparator.rawValue) }
            return (texts + parsed.dates + parsed.numbers + parsed.versions).joined(separator: ArchiveNamingRule.fieldSeparator)
        }
    }
}

/// Folder names are checked and cleaned here, and a name that means a dictionary category becomes that category's
/// canonical name, so `Music`, `歌曲` and `music` all end up as `音乐`.
nonisolated enum ArchiveFolderNaming {
    enum Problem: Equatable, Sendable {
        /// Not a plain single folder name.
        case invalid
        /// Starts with a prefix that carries no meaning (`A__`, `01_`).
        case prefix
        /// A placeholder (`新建文件夹`, `temp`, `其他`).
        case placeholder
        /// Only a date or a number.
        case dateOrNumber
        /// Means a category, but is not its canonical name.
        case synonym(canonical: String)

        var description: String {
            switch self {
            case .invalid: "不是有效的单层文件夹名"
            case .prefix: "带有无语义前缀"
            case .placeholder: "是占位名称"
            case .dateOrNumber: "只有日期或数字"
            case .synonym(let canonical): "应使用类别规范名「\(canonical)」"
            }
        }
    }

    static let placeholders: Set<String> = [
        "新建文件夹", "新文件夹", "未命名文件夹", "未命名", "无标题", "文件夹", "临时", "临时文件", "其他", "其它", "杂项", "杂物",
        "untitled folder", "untitled", "new folder", "folder", "temp", "tmp", "misc", "miscellaneous", "other", "others", "stuff", "random",
    ].reduce(into: Set<String>()) { $0.insert(ArchiveFileSystem.nameKey($1)) }

    private static let prefixPattern = "^(?:[A-Za-z]{1,2}_{2,}|[0-9]{1,3}[ ._-]+|[ _.~-]+)"

    static func problems(_ name: String, convention: ArchiveConvention) -> [Problem] {
        guard ArchiveDirectoryFileSystem.isValidComponent(name) else { return [.invalid] }
        var problems: [Problem] = []
        if name.range(of: prefixPattern, options: .regularExpression) != nil,
           name.replacingOccurrences(of: prefixPattern, with: "", options: .regularExpression).contains(where: \.isLetter) {
            problems.append(.prefix)
        }
        let bare = name.replacingOccurrences(of: "\\s*[(（]?[0-9]{1,3}[)）]?$", with: "", options: .regularExpression)
        if placeholders.contains(ArchiveFileSystem.nameKey(bare)) || placeholders.contains(ArchiveFileSystem.nameKey(name)) {
            problems.append(.placeholder)
        }
        if name.range(of: "^[0-9 ._\\-年月日]+$", options: .regularExpression) != nil { problems.append(.dateOrNumber) }
        if let category = convention.category(forFolderName: name),
           ArchiveFileSystem.nameKey(name) != ArchiveFileSystem.nameKey(convention.canonicalName(category.id)) {
            problems.append(.synonym(canonical: convention.canonicalName(category.id)))
        }
        return problems
    }

    static func isAcceptable(_ name: String, convention: ArchiveConvention) -> Bool { problems(name, convention: convention).isEmpty }

    /// The name cleaned to the convention: canonical when it means a category, otherwise without its meaningless
    /// prefix and extra blanks. Nil when no acceptable name is left (a placeholder, a bare date).
    static func normalize(_ name: String, convention: ArchiveConvention) -> String? {
        var result = ArchiveNameNormalizer.fold(name).trimmingCharacters(in: .whitespacesAndNewlines)
        result = String(result.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || "/:\\".unicodeScalars.contains(scalar) ? " " : Character(scalar)
        })
        if let category = convention.category(forFolderName: result) { return convention.canonicalName(category.id) }
        for _ in 0..<2 where result.range(of: prefixPattern, options: .regularExpression) != nil {
            result = result.replacingOccurrences(of: prefixPattern, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-.~"))
        if let category = convention.category(forFolderName: result) { return convention.canonicalName(category.id) }
        return isAcceptable(result, convention: convention) ? result : nil
    }
}
