import Foundation

/// Model-generated names are suggestions, never paths or instructions.
nonisolated enum ArchiveAINamePolicy {
    /// Number-bearing identifiers of the original name (dates, invoice IDs, versions) that a rename must keep.
    /// Noise that only looks like one (`(1)`, `copy 2`) is not among them, and dates are in `YYYY-MM-DD` form.
    static func identifiers(in name: String) -> [String] {
        ArchiveNameNormalizer.identifiers(in: (name as NSString).deletingPathExtension)
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
        let retained = identifiers(in: original.lastPathComponent).allSatisfy { ArchiveNameNormalizer.contains($0, in: stem) }
        guard retained else {
            throw ArchiveError("AI 改名丢失了原有日期、编号或版本，请重新规划。")
        }
        return name
    }
}
