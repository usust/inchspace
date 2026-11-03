import XCTest
@testable import inchspace

@MainActor
final class PythonEnvironmentServiceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inchspace-python-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(in root: URL, name: String = ".venv") throws -> PythonEnvironment {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("home = /usr/bin\n".utf8).write(to: directory.appendingPathComponent("pyvenv.cfg"))
        try Data("# fixture only\n".utf8).write(to: directory.appendingPathComponent("bin/activate"))
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: directory.appendingPathComponent("bin/python"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("bin/python").path)
        return PythonEnvironment(name: name, path: directory.path, workingDirectory: root.path)
    }

    func testQuotingAndActivation() throws {
        XCTAssertEqual(PythonEnvironmentService.shellQuote("a'b $()"), "'a'\\''b $()'")
        XCTAssertEqual(PythonEnvironmentService.shellQuote(""), "''")
        let root = try temporaryDirectory()
        let environment = try fixture(in: root, name: "a'b $()")
        XCTAssertEqual(try PythonEnvironmentService.activationCommand(for: environment), "source \(PythonEnvironmentService.shellQuote(environment.path + "/bin/activate"))")
        XCTAssertThrowsError(try PythonEnvironmentService.activationCommand(for: environment, shell: "/bin/fish"))
        var invalid = environment
        invalid.workingDirectory += "\n"
        XCTAssertThrowsError(try PythonEnvironmentService.activationCommand(for: invalid))
    }

    func testActivationCommandPreservesCurrentDirectory() throws {
        let root = try temporaryDirectory()
        let environment = try fixture(in: root, name: "a'b $()")
        let currentDirectory = root.appendingPathComponent("current directory")
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: false)
        for shell in ["/bin/zsh", "/bin/bash"] {
            let command = try PythonEnvironmentService.activationCommand(for: environment, shell: shell)
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-f", "-c", "\(command) && /bin/pwd -P"]
            process.currentDirectoryURL = currentDirectory
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let reportedPath = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // /var and /private/var can name the same directory on macOS.
            let reported = try FileManager.default.attributesOfItem(atPath: reportedPath)
            let expected = try FileManager.default.attributesOfItem(atPath: currentDirectory.path)
            XCTAssertEqual(reported[.systemNumber] as? NSNumber, expected[.systemNumber] as? NSNumber)
            XCTAssertEqual(reported[.systemFileNumber] as? NSNumber, expected[.systemFileNumber] as? NSNumber)
        }
    }

    func testStructuralValidationNeverRunsInterpreter() throws {
        let root = try temporaryDirectory()
        let environment = try fixture(in: root)
        XCTAssertNoThrow(try PythonEnvironmentService.validate(environment))
        try FileManager.default.removeItem(atPath: environment.path + "/pyvenv.cfg")
        XCTAssertThrowsError(try PythonEnvironmentService.validate(environment))
        var relative = environment
        relative.path = "relative/.venv"
        XCTAssertThrowsError(try PythonEnvironmentService.validate(relative))
    }

    func testMissingExecutableActivateAndWorkingDirectory() throws {
        let root = try temporaryDirectory()
        let environment = try fixture(in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: environment.pythonPath)
        XCTAssertThrowsError(try PythonEnvironmentService.validate(environment))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: environment.pythonPath)
        var missing = environment
        missing.workingDirectory = root.appendingPathComponent("missing").path
        XCTAssertThrowsError(try PythonEnvironmentService.validate(missing))
        try FileManager.default.removeItem(atPath: environment.path + "/bin/activate")
        XCTAssertThrowsError(try PythonEnvironmentService.validate(environment))
    }

    func testStoreRoundTripUpsertDuplicatesAndRecordOnlyRemoval() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("records.json")
        let store = PythonEnvironmentStore(fileURL: file)
        var environment = try fixture(in: root)
        try store.save(environment)
        environment.name = "Renamed"
        try store.save(environment)
        XCTAssertEqual(PythonEnvironmentStore(fileURL: file).environments, [environment])
        var duplicate = environment
        duplicate.id = UUID()
        duplicate.path += "/../.venv"
        XCTAssertThrowsError(try store.save(duplicate))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: environment.path)
        duplicate.path = alias.path
        XCTAssertThrowsError(try store.save(duplicate))
        try store.remove(environment)
        XCTAssertTrue(PythonEnvironmentStore(fileURL: file).environments.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.pythonPath))
    }

    func testCorruptStoreIsNotOverwritten() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("records.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: file)
        let store = PythonEnvironmentStore(fileURL: file)
        XCTAssertNotNil(store.errorMessage)
        let environment = try fixture(in: root)
        XCTAssertThrowsError(try store.save(environment))
        XCTAssertThrowsError(try store.remove(environment))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testDiscoverySkipsHiddenExcludedSymlinkAndDeepDirectories() async throws {
        let root = try temporaryDirectory()
        let visible = try fixture(in: root)
        _ = try fixture(in: root, name: ".hidden/env")
        _ = try fixture(in: root, name: "node_modules/env")
        _ = try fixture(in: root, name: "a/b/c/d/e/f/env")
        let outside = try temporaryDirectory()
        _ = try fixture(in: outside)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked").path, withDestinationPath: outside.path)
        let discovered = try await PythonEnvironmentService.discover(in: root)
        XCTAssertEqual(discovered.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }, [URL(fileURLWithPath: visible.path).resolvingSymlinksInPath().path])
    }

    func testDiscoveryUsesProjectDirectoryAndNameForNestedVenv() async throws {
        let root = try temporaryDirectory()
        let environment = try fixture(in: root, name: "analysis/.venv")
        let discovered = try await PythonEnvironmentService.discover(in: root)
        let result = try XCTUnwrap(discovered.first)
        XCTAssertEqual(result.name, "analysis")
        XCTAssertEqual(URL(fileURLWithPath: result.workingDirectory).resolvingSymlinksInPath(),
                       URL(fileURLWithPath: environment.path).deletingLastPathComponent().resolvingSymlinksInPath())
    }

    func testRealVenvCreationInspectionAndPackagesWithoutPip() async throws {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let interpreter = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("没有可用的系统 Python。")
        }
        let root = try temporaryDirectory()
        let path = root.appendingPathComponent("real environment").path
        let environment = try await PythonEnvironmentService.create(name: "Real", at: path, interpreter: interpreter, workingDirectory: root.path, terminalTarget: .system)
        XCTAssertEqual(environment.terminalTarget, .system)
        let inspection = try await PythonEnvironmentService.inspect(environment)
        XCTAssertFalse(inspection.version.isEmpty)
        // Distribution metadata remains usable after pip itself is absent.
        let site = URL(fileURLWithPath: path).appendingPathComponent("lib")
        let versions = try FileManager.default.contentsOfDirectory(at: site, includingPropertiesForKeys: nil)
        if let version = versions.first(where: { $0.lastPathComponent.hasPrefix("python") }) {
            let packages = version.appendingPathComponent("site-packages")
            for entry in try FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil) where entry.lastPathComponent == "pip" || entry.lastPathComponent.hasPrefix("pip-") {
                try FileManager.default.removeItem(at: entry)
            }
            let metadata = packages.appendingPathComponent("inchspace_fixture-1.2.dist-info")
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            try Data("Metadata-Version: 2.1\nName: inchspace-fixture\nVersion: 1.2\n".utf8).write(to: metadata.appendingPathComponent("METADATA"))
            let installed = try await PythonEnvironmentService.installedPackages(environment)
            XCTAssertTrue(installed.contains(where: { $0.name == "inchspace-fixture" && $0.version == "1.2" }))
        } else { XCTFail("venv 缺少 Python 库目录。") }
        do {
            _ = try await PythonEnvironmentService.create(name: "Duplicate", at: path, interpreter: interpreter, workingDirectory: root.path, terminalTarget: .builtIn)
            XCTFail("不应覆盖已有目录。")
        } catch { XCTAssertTrue(FileManager.default.fileExists(atPath: environment.pythonPath)) }
    }

    func testProcessOutputLimitAndCancellation() async throws {
        let root = try temporaryDirectory()
        let environment = try fixture(in: root)
        try Data("#!/bin/sh\nwhile :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; printf 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy' >&2; done\n".utf8).write(to: URL(fileURLWithPath: environment.pythonPath))
        let task = Task { try await PythonEnvironmentService.inspect(environment) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("应取消进程。") }
        catch is CancellationError { }
        catch { XCTFail("应返回 CancellationError：\(error)") }
        do { _ = try await PythonEnvironmentService.inspect(environment); XCTFail("应限制输出。") }
        catch { XCTAssertTrue(error.localizedDescription.contains("2 MB")) }
    }
}
