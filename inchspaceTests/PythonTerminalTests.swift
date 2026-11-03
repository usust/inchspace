import XCTest
@testable import inchspace

@MainActor
final class PythonTerminalTests: XCTestCase {
    func testBootstrapActivatesZshAndBashAndPreservesDeactivate() async throws {
        let (root, environment) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        for shell in ["/bin/zsh", "/bin/bash"] {
            let output = root.appendingPathComponent(URL(fileURLWithPath: shell).lastPathComponent + ".txt")
            let quote = PythonEnvironmentService.shellQuote
            let command = "{ printf '%s\\n' \"$VIRTUAL_ENV\"; pwd; command -v python; deactivate; printf 'DEACTIVATED:%s\\n' \"${VIRTUAL_ENV-unset}\"; } > \(quote(output.path)); exit"
            let bootstrap = try PythonTerminalBootstrap.prepare(
                environment: environment, shell: shell,
                processEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], scriptCommand: command
            )
            defer { bootstrap.remove() }
            let status = try await runBootstrap(bootstrap)
            XCTAssertEqual(status, 0)
            let result = try String(contentsOf: output, encoding: .utf8)
            XCTAssertTrue(result.contains(environment.path), result)
            XCTAssertTrue(result.contains(environment.pythonPath), result)
            XCTAssertTrue(result.contains("DEACTIVATED:unset"), result)
        }
    }

    func testPythonPTYRunsScriptOnlyInFirstPaneAndKeepsEnvironmentInSplit() async throws {
        let (root, environment) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("script with ' quote.py")
        let marker = root.appendingPathComponent("runs.txt")
        try "import pathlib, sys\np = pathlib.Path(sys.argv[1])\np.write_text(p.read_text() + 'run\\n' if p.exists() else 'run\\n')\nprint('PYTHON_SCRIPT_OK')\n"
            .write(to: script, atomically: true, encoding: .utf8)
        let suite = "PythonTerminalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TerminalPreferences(defaults: defaults)
        preferences.shellOverride = "/bin/zsh"
        let manager = TerminalTestSupport.makeManager(preferences: preferences, testCase: self)
        let command = try PythonScriptCommand.make(environment: environment, scriptPath: script.path, arguments: [marker.path])
        let session = try manager.openPythonSession(environment, scriptCommand: command)
        defer { session.terminate() }
        session.startIfNeeded()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "run\n")
        manager.split(.horizontal)
        session.activePane.startIfNeeded()
        var buffer = ""
        for _ in 0..<100 {
            buffer = String(decoding: session.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
                .replacingOccurrences(of: "\0", with: "")
            if buffer.contains("已激活") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(buffer.contains("已激活"), buffer)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "run\n", "分屏不应重复运行脚本")
        XCTAssertEqual(session.panes.count, 2)
    }

    func testSelfCleaningStartupAcceptsEnvironmentAlias() async throws {
        let (root, original) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: original.path))
        var environment = original
        environment.path = alias.path + "/"
        let marker = root.appendingPathComponent("activated")
        let bootstrap = try PythonTerminalBootstrap.prepare(
            environment: environment, shell: "/bin/zsh",
            processEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
            scriptCommand: "/usr/bin/touch \(PythonEnvironmentService.shellQuote(marker.path)); exit",
            removesItself: true
        )
        defer { bootstrap.remove() }
        let status = try await runBootstrap(bootstrap)
        XCTAssertEqual(status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bootstrap.directory.path))
    }

    func testFailedActivationDoesNotRunScript() async throws {
        let (root, environment) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let activation = URL(fileURLWithPath: environment.path).appendingPathComponent("bin/activate")
        try "return 1\n".write(to: activation, atomically: true, encoding: .utf8)
        let marker = root.appendingPathComponent("must-not-exist")
        let bootstrap = try PythonTerminalBootstrap.prepare(
            environment: environment, shell: "/bin/zsh",
            processEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
            scriptCommand: "/usr/bin/touch \(PythonEnvironmentService.shellQuote(marker.path)); exit"
        )
        defer { bootstrap.remove() }
        let status = try await runBootstrap(bootstrap)
        XCTAssertNotEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testScriptArgumentsAreQuotedAndControlCharactersRejected() async throws {
        let (root, environment) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("main.py")
        try "pass\n".write(to: script, atomically: true, encoding: .utf8)
        let command = try PythonScriptCommand.make(environment: environment, scriptPath: script.path, arguments: ["a b", "$(touch /tmp/not-run)", "a'b"])
        XCTAssertTrue(command.contains("'a b'"))
        XCTAssertTrue(command.contains("'$(touch /tmp/not-run)'"))
        XCTAssertTrue(command.contains("'a'\\''b'"))
        XCTAssertThrowsError(try PythonScriptCommand.make(environment: environment, scriptPath: script.path, arguments: ["a\nb"]))
    }

    private func makeEnvironment() async throws -> (URL, PythonEnvironment) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("需要本机 Python 3") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inchspace-python-terminal-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let environment = try await PythonEnvironmentService.create(
                name: "测试环境", at: root.appendingPathComponent("env with ' quote").path,
                interpreter: "/usr/bin/python3", workingDirectory: root.path, terminalTarget: .builtIn
            )
            return (root, environment)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func runBootstrap(_ bootstrap: PythonTerminalBootstrap) async throws -> Int32 {
        let shell = bootstrap.shell
        let arguments = bootstrap.arguments
        let environment = bootstrap.environment
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            if process.isRunning { process.terminate(); throw PythonEnvironmentError.process("测试 Shell 未按时退出") }
            return process.terminationStatus
        }.value
    }
}
