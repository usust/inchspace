import Foundation
import Network

nonisolated struct HostsParser: Sendable {
    static let disabledMarker = "# inchspace:disabled "
    private static let protectedPairs: Set<String> = [
        "127.0.0.1 localhost", "::1 localhost", "255.255.255.255 broadcasthost"
    ]

    func parse(_ source: String) -> HostsDocument {
        let endsWithNewline = source.hasSuffix("\n")
        var rawLines = source.components(separatedBy: "\n")
        if endsWithNewline { rawLines.removeLast() }
        let lines = rawLines.enumerated().map { index, raw -> HostsLine in
            let id = UUID()
            return HostsLine(id: id, raw: raw, entry: parseEntry(raw, id: id, index: index))
        }
        return HostsDocument(lines: lines, endsWithNewline: endsWithNewline)
    }

    func validate(address: String, hostnames: [String]) throws {
        guard IPv4Address(address) != nil || IPv6Address(address) != nil else { throw HostsError.invalidAddress }
        guard !hostnames.isEmpty else { throw HostsError.invalidHostname("") }
        for hostname in hostnames {
            guard hostname.count <= 253, !hostname.hasPrefix("."), !hostname.hasSuffix("."),
                  hostname.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                      !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                  }) else { throw HostsError.invalidHostname(hostname) }
        }
    }

    func line(address: String, hostnames: [String], comment: String, enabled: Bool) -> String {
        let host = ([address] + hostnames).joined(separator: "\t")
        let suffix = comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " # \(comment.trimmingCharacters(in: .whitespacesAndNewlines))"
        return (enabled ? "" : Self.disabledMarker) + host + suffix
    }

    private func parseEntry(_ raw: String, id: UUID, index: Int) -> HostEntry? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let enabled: Bool
        let content: String
        if trimmed.hasPrefix(Self.disabledMarker) {
            enabled = false; content = String(trimmed.dropFirst(Self.disabledMarker.count))
        } else {
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            enabled = true; content = trimmed
        }
        let split = content.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let fields = split[0].split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, IPv4Address(fields[0]) != nil || IPv6Address(fields[0]) != nil else { return nil }
        let comment = split.count == 2 ? String(split[1]).trimmingCharacters(in: .whitespaces) : ""
        let hostnames = Array(fields.dropFirst())
        let system = hostnames.contains { Self.protectedPairs.contains("\(fields[0]) \($0)") }
        return HostEntry(id: id, address: fields[0], hostnames: hostnames, comment: comment, enabled: enabled, isSystem: system, lineIndex: index)
    }
}
