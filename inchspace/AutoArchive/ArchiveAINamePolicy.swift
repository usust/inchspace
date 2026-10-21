import Foundation

/// Model-generated names are suggestions, never paths or instructions.
nonisolated enum ArchiveAINamePolicy {
    static func identifiers(in name: String) -> [String] {
        let stem = (name as NSString).deletingPathExtension
        // Preserve original number-bearing identifiers as complete tokens (dates, invoice IDs, versions).
        let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*")
        let ranges = regex?.matches(in: stem, range: NSRange(stem.startIndex..., in: stem)) ?? []
        return ranges.compactMap { match in
            guard let range = Range(match.range, in: stem) else { return nil }
            let token = String(stem[range])
            return token.contains(where: { $0.isNumber }) ? token : nil
        }
    }

    static func validate(_ proposedName: String?, original: URL) throws -> String {
        // Nil is reserved for existing programmatic/legacy requests; the model response schema requires a name.
        let name = proposedName ?? original.lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasPrefix("~"),
              name.utf8.count <= 240, name == name.precomposedStringWithCanonicalMapping,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.hasSuffix("."),
              !name.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f || "/:\\".unicodeScalars.contains($0)
              }) else { throw ArchiveError("AI 文件名无效：必须是普通单个文件名，不能包含路径或隐藏前缀。") }
        guard (name as NSString).pathExtension == original.pathExtension else {
            throw ArchiveError("AI 改名必须保留原扩展名（包括大小写），不能改变文件格式。")
        }
        let stem = (name as NSString).deletingPathExtension
        let retained = identifiers(in: original.lastPathComponent).allSatisfy { identifier in
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: identifier) + "(?![A-Za-z0-9])"
            return stem.range(of: pattern, options: .regularExpression) != nil
        }
        guard retained else {
            throw ArchiveError("AI 改名丢失了原有日期、编号或版本，请重新规划。")
        }
        return name
    }
}
