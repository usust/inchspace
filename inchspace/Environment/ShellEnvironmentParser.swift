import Foundation

struct ParsedEnvironmentDefinition: Hashable, Sendable {
    let name: String
    let value: String
    let rawValue: String
    let assignmentLineIndex: Int
    let exportLineIndex: Int?
    let isManaged: Bool
    let isEnabled: Bool
    let isExportedToPath: Bool
}

struct ParsedShellEnvironment: Sendable {
    let definitions: [ParsedEnvironmentDefinition]
    let newline: String
    let lines: [String]
}

nonisolated enum ShellEnvironmentParser {
    static let disabledPrefix = "# [inchspace disabled] "
    static let pathStartPrefix = "# >>> inchspace PATH: "
    static let pathStartSuffix = " >>>"
    static let disabledPathPrefix = "# [inchspace disabled PATH] "
    static func parse(
        _ content: String,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        managedStartMarker: String = EnvironmentVariableService.managedStartMarker,
        managedEndMarker: String = EnvironmentVariableService.managedEndMarker
    ) -> ParsedShellEnvironment {
        let newline = content.contains("\r\n") ? "\r\n" : "\n"
        let lines = content.components(separatedBy: newline)
        var definitions: [ParsedEnvironmentDefinition] = []
        var pending: [String: (rawValue: String, line: Int, managed: Bool)] = [:]
        var values = inheritedEnvironment
        var insideManagedBlock = false
        var pathExportNames = Set<String>()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(pathStartPrefix), trimmed.hasSuffix(pathStartSuffix) {
                let start = trimmed.index(trimmed.startIndex, offsetBy: pathStartPrefix.count)
                let end = trimmed.index(trimmed.endIndex, offsetBy: -pathStartSuffix.count)
                let name = String(trimmed[start..<end])
                if EnvironmentVariableService.isValidVariableName(name) { pathExportNames.insert(name) }
            } else if trimmed.hasPrefix(disabledPathPrefix) {
                let name = String(trimmed.dropFirst(disabledPathPrefix.count)).trimmingCharacters(in: .whitespaces)
                if EnvironmentVariableService.isValidVariableName(name) { pathExportNames.insert(name) }
            }
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == managedStartMarker {
                insideManagedBlock = true
                continue
            }
            if trimmed == managedEndMarker {
                insideManagedBlock = false
                continue
            }
            if trimmed.hasPrefix(disabledPrefix) {
                let original = String(trimmed.dropFirst(disabledPrefix.count))
                if let assignment = assignment(in: original) {
                    definitions.append(ParsedEnvironmentDefinition(
                        name: assignment.name,
                        value: decode(assignment.rawValue, environment: values),
                        rawValue: assignment.rawValue,
                        assignmentLineIndex: index,
                        exportLineIndex: nil,
                        isManaged: insideManagedBlock,
                        isEnabled: false,
                        isExportedToPath: pathExportNames.contains(assignment.name)
                    ))
                }
                continue
            }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if let assignment = assignment(in: line) {
                let value = decode(assignment.rawValue, environment: values)
                values[assignment.name] = value
                if assignment.exported {
                    definitions.append(ParsedEnvironmentDefinition(
                        name: assignment.name,
                        value: value,
                        rawValue: assignment.rawValue,
                        assignmentLineIndex: index,
                        exportLineIndex: nil,
                        isManaged: insideManagedBlock,
                        isEnabled: true,
                        isExportedToPath: pathExportNames.contains(assignment.name)
                    ))
                } else {
                    pending[assignment.name] = (assignment.rawValue, index, insideManagedBlock)
                }
                continue
            }

            if let names = standaloneExportNames(in: line) {
                for name in names {
                    guard let assignment = pending[name] else { continue }
                    definitions.append(ParsedEnvironmentDefinition(
                        name: name,
                        value: decode(assignment.rawValue, environment: values),
                        rawValue: assignment.rawValue,
                        assignmentLineIndex: assignment.line,
                        exportLineIndex: index,
                        isManaged: assignment.managed || insideManagedBlock,
                        isEnabled: true,
                        isExportedToPath: pathExportNames.contains(name)
                    ))
                }
            }
        }
        return ParsedShellEnvironment(definitions: definitions, newline: newline, lines: lines)
    }

    static func escapeValue(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func assignment(in line: String) -> (name: String, rawValue: String, exported: Bool)? {
        var code = removingComment(from: line).trimmingCharacters(in: .whitespaces)
        var exported = false
        if code.hasPrefix("export ") || code.hasPrefix("export\t") {
            exported = true
            code = String(code.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        guard let equals = code.firstIndex(of: "=") else { return nil }
        let name = String(code[..<equals]).trimmingCharacters(in: .whitespaces)
        guard EnvironmentVariableService.isValidVariableName(name) else { return nil }
        let rawValue = String(code[code.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        return (name, rawValue, exported)
    }

    private static func standaloneExportNames(in line: String) -> [String]? {
        let code = removingComment(from: line).trimmingCharacters(in: .whitespaces)
        guard code.hasPrefix("export ") || code.hasPrefix("export\t"), !code.contains("=") else { return nil }
        return code.dropFirst(6).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            .filter(EnvironmentVariableService.isValidVariableName)
    }

    private static func removingComment(from line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote == nil ? character : quote)
            } else if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func decode(_ rawValue: String, environment: [String: String]) -> String {
        let input = rawValue.trimmingCharacters(in: .whitespaces)
        var value = ""
        var index = input.startIndex
        var quote: Character?
        while index < input.endIndex {
            let character = input[index]
            if character == "'", quote != "\"" {
                quote = quote == "'" ? nil : "'"
                index = input.index(after: index)
                continue
            }
            if character == "\"", quote != "'" {
                quote = quote == "\"" ? nil : "\""
                index = input.index(after: index)
                continue
            }
            if character == "\\", quote != "'" {
                let next = input.index(after: index)
                if next < input.endIndex { value.append(input[next]); index = input.index(after: next) }
                else { value.append(character); index = next }
                continue
            }
            if character == "$", quote != "'" {
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == "{" {
                    let nameStart = input.index(after: next)
                    if let close = input[nameStart...].firstIndex(of: "}") {
                        value += environment[String(input[nameStart..<close])] ?? ""
                        index = input.index(after: close)
                        continue
                    }
                }
                var end = next
                while end < input.endIndex,
                      input[end].isLetter || input[end].isNumber || input[end] == "_" {
                    end = input.index(after: end)
                }
                if end > next {
                    value += environment[String(input[next..<end])] ?? ""
                    index = end
                    continue
                }
            }
            value.append(character)
            index = input.index(after: index)
        }
        if value == "~" { return environment["HOME"] ?? NSHomeDirectory() }
        if value.hasPrefix("~/") {
            return (environment["HOME"] ?? NSHomeDirectory()) + String(value.dropFirst())
        }
        return value
    }
}
