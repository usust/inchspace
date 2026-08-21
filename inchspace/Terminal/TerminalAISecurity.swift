import Foundation

enum TerminalAISecretRedactor {
    nonisolated static func redact(_ input: String) -> String {
        var value = input
        let patterns = [
            #"(?im)\b([A-Z][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD))\s*=\s*([^\s]+)"#,
            #"(?im)\b(password|passwd|token|secret|api[_-]?key)\s*[:=]\s*([^\s]+)"#,
            #"(?im)(Authorization\s*:\s*Bearer\s+)([^\s]+)"#,
            #"(?s)(-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----).*?(-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..., in: value)
            if pattern.contains("PRIVATE KEY") {
                value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1\n****\n$2")
            } else {
                value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1=****")
            }
        }
        return value
    }
}

enum TerminalAICommandPolicy {
    nonisolated private static let safeNames: Set<String> = [
        "pwd", "ls", "whoami", "uname", "which", "whereis", "cat", "head", "tail",
        "grep", "find", "ps", "env", "printenv",
    ]

    nonisolated static func isSafe(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !containsShellControlOperator(trimmed) else { return false }
        let tokens = tokenize(trimmed)
        guard let executable = tokens.first?.split(separator: "/").last.map(String.init) else { return false }
        if safeNames.contains(executable) { return true }
        guard executable == "git", tokens.count >= 2 else { return false }
        return ["status", "diff", "log", "show", "branch", "remote"].contains(tokens[1])
    }

    nonisolated static func isHighRisk(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let patterns = [
            #"(^|[;&|]\s*)(sudo\s+)?rm\b"#, #"\b(mkfs|shutdown|reboot|pkill|eval)\b"#,
            #"\bdd\s+.*\bof="#, #"\bdiskutil\s+erase"#, #"\b(chmod|chown)\s+-r\b"#,
            #"\bkill\s+-9\b"#, #"\bgit\s+(reset\s+--hard|clean\s+-[^\s]*f)\b"#,
            #"\b(drop\s+(database|table)|delete\s+from)\b"#, #"\b(curl|wget)\b[^\n|]*\|\s*(sh|bash|zsh)\b"#,
        ]
        return patterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }

    nonisolated private static func containsShellControlOperator(_ command: String) -> Bool {
        var quote: Character?
        var escaped = false
        let characters = Array(command)
        for (index, character) in characters.enumerated() {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "'" || character == "\"" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
                continue
            }
            guard quote == nil else { continue }
            if character == ";" || character == "\n" || character == "`" { return true }
            if (character == "|" || character == "&") { return true }
            if character == "$", index + 1 < characters.count, characters[index + 1] == "(" { return true }
            if character == ">" || character == "<" { return true }
        }
        return quote != nil
    }

    nonisolated private static func tokenize(_ command: String) -> [String] {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped { token.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if character == "'" || character == "\"" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if character.isWhitespace, quote == nil {
                if !token.isEmpty { result.append(token); token = "" }
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty { result.append(token) }
        return result
    }
}
