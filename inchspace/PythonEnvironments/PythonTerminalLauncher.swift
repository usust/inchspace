import AppKit
import Foundation

struct PythonTerminalBootstrap {
    let directory: URL
    let shell: String
    let arguments: [String]
    let environment: [String: String]

    static func prepare(
        environment: PythonEnvironment,
        shell: String,
        processEnvironment: [String: String],
        scriptCommand: String? = nil,
        removesItself: Bool = false
    ) throws -> PythonTerminalBootstrap {
        let activation = try PythonEnvironmentService.activationCommand(for: environment, shell: shell)
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-python-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let quote = PythonEnvironmentService.shellQuote
            var variables = processEnvironment
            // Python sessions start clean so personal shell hooks cannot reactivate another environment.
            variables.removeValue(forKey: "PYTHONHOME")
            variables.removeValue(forKey: "PYTHONPATH")
            variables.removeValue(forKey: "VIRTUAL_ENV")
            variables.removeValue(forKey: "VIRTUAL_ENV_PROMPT")
            let startupFile = directory.appendingPathComponent(shellName == "zsh" ? ".zshrc" : "startup.bash")
            var startup = ""
            if shellName == "zsh" {
                if let original = processEnvironment["ZDOTDIR"] {
                    startup += "export ZDOTDIR=\(quote(original))\n"
                } else {
                    startup += "unset ZDOTDIR\n"
                }
                variables["ZDOTDIR"] = directory.path
            }
            if removesItself {
                startup += "/bin/rm -f -- \(quote(startupFile.path)) \(quote(directory.appendingPathComponent("打开环境.command").path))\n"
                startup += "/bin/rmdir -- \(quote(directory.path))\n"
            }
            startup += """
            if ! { cd -- \(quote(environment.workingDirectory)) && \(activation); }; then
                printf '\\n%s\\n' '虚拟环境激活失败，请检查环境路径和激活脚本。' >&2
                exit 1
            fi
            if ! [ "$VIRTUAL_ENV" -ef \(quote(environment.path)) ]; then
                printf '\\n%s\\n' '激活脚本指向了其他环境。环境可能被移动，请重新创建后再添加。' >&2
                exit 1
            fi
            printf '\\n%s\\n' \(quote("已激活：\(environment.name)"))
            """
            if let scriptCommand {
                startup += "\n\(scriptCommand)\n"
                startup += "printf '\\n脚本已结束，退出码：%s\\n' \"$?\"\n"
            }
            try (startup + "\n").write(to: startupFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: startupFile.path)
            let arguments = shellName == "zsh"
                ? ["-d", "-i"]
                : ["--noprofile", "--rcfile", startupFile.path, "-i"]
            return PythonTerminalBootstrap(directory: directory, shell: shell, arguments: arguments, environment: variables)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
enum PythonSystemTerminal {
    static func open(_ environment: PythonEnvironment, scriptCommand: String? = nil) async throws {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw PythonTerminalError.terminalUnavailable
        }
        var variables = AppEnvironmentStore.shared.environment()
        variables["TERM"] = "xterm-256color"
        let bootstrap = try PythonTerminalBootstrap.prepare(
            environment: environment, shell: "/bin/zsh", processEnvironment: variables,
            scriptCommand: scriptCommand, removesItself: true
        )
        let launcher = bootstrap.directory.appendingPathComponent("打开环境.command")
        do {
            let quote = PythonEnvironmentService.shellQuote
            // A .command document opens an isolated Terminal window without Apple Events automation permission.
            let script = """
            #!/bin/sh
            unset PYTHONHOME PYTHONPATH VIRTUAL_ENV VIRTUAL_ENV_PROMPT
            export ZDOTDIR=\(quote(bootstrap.directory.path))
            exec /bin/zsh -d -i
            """
            try (script + "\n").write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([launcher], withApplicationAt: terminalURL, configuration: configuration)
        } catch {
            bootstrap.remove()
            throw error
        }
    }
}

enum PythonTerminalError: LocalizedError {
    case terminalUnavailable
    case invalidScript
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .terminalUnavailable: "找不到 macOS 系统终端 Terminal.app。"
        case .invalidScript: "请选择存在且可读取的 Python 脚本。"
        case .invalidArguments: "参数不能包含制表符或其他控制字符，请每行输入一个参数。"
        }
    }
}
