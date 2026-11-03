import Foundation
import Darwin

/// Only explicitly selected interpreters are executed. Discovery and validation never run Python.
nonisolated enum PythonEnvironmentService {
    static func validate(_ environment: PythonEnvironment) throws {
        try validatePath(environment.path)
        try validatePath(environment.workingDirectory)
        let root = URL(fileURLWithPath: environment.path)
        guard isDirectory(root) else { throw PythonEnvironmentError.invalid("环境目录不存在：\(environment.path)") }
        for component in ["pyvenv.cfg", "bin/activate"] {
            let url = root.appendingPathComponent(component)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
                throw PythonEnvironmentError.invalid("不是受支持的 venv 环境，缺少 \(component)。")
            }
        }
        guard FileManager.default.isExecutableFile(atPath: environment.pythonPath), !isDirectory(URL(fileURLWithPath: environment.pythonPath)) else {
            throw PythonEnvironmentError.invalid("环境的 bin/python 不存在或不可执行。")
        }
        guard isDirectory(URL(fileURLWithPath: environment.workingDirectory)) else {
            throw PythonEnvironmentError.invalid("工作目录不存在：\(environment.workingDirectory)")
        }
    }

    static func inspect(_ environment: PythonEnvironment) async throws -> PythonEnvironmentInspection {
        try validate(environment)
        let result = try await run(environment.pythonPath, arguments: ["-I", "-c", "import sys; print(sys.version.split()[0])"], timeout: 15)
        let version = String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw PythonEnvironmentError.process("Python 未返回版本信息。") }
        return PythonEnvironmentInspection(version: version, kind: "venv")
    }

    static func installedPackages(_ environment: PythonEnvironment) async throws -> [PythonInstalledPackage] {
        try validate(environment)
        // Reads distribution metadata only; never imports installed distribution modules or requires pip.
        let script = """
        import importlib.metadata, json
        packages = {}
        for d in importlib.metadata.distributions():
            name = d.metadata.get('Name')
            if name:
                packages[name] = {'name': name, 'version': d.version or ''}
        print(json.dumps(sorted(packages.values(), key=lambda p: p['name'].casefold())))
        """
        let data = try await run(environment.pythonPath, arguments: ["-I", "-c", script], timeout: 30)
        do { return try JSONDecoder().decode([PythonInstalledPackage].self, from: data) }
        catch { throw PythonEnvironmentError.process("无法解析已安装软件包列表：\(error.localizedDescription)") }
    }

    static func discover(in root: URL) async throws -> [PythonEnvironment] {
        let cancellation = PythonProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
            guard isDirectory(root) else { throw PythonEnvironmentError.invalid("扫描目录不存在。") }
            let excluded: Set<String> = ["node_modules", ".git", "Library", "__pycache__", "site-packages", "build", "dist"]
            var pending: [(URL, Int)] = [(root, 0)]
            var results: [PythonEnvironment] = []
            var visited = 0
            var scannedEntries = 0
            while let (directory, depth) = pending.popLast(), visited < 4_000, results.count < 100 {
                if cancellation.isCancelled { throw CancellationError() }
                visited += 1
                let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
                let parent = directory.deletingLastPathComponent()
                let name = [".venv", "venv", ".env", "env"].contains(directory.lastPathComponent)
                    ? parent.lastPathComponent : directory.lastPathComponent
                let environment = PythonEnvironment(name: name, path: directory.path, workingDirectory: parent.path)
                if (try? validate(environment)) != nil {
                    results.append(environment)
                    continue
                }
                guard depth < 5 else { continue }
                // Bound enumeration itself, not just the number of directories subsequently visited.
                guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants]) else { continue }
                while scannedEntries < 20_000, let child = enumerator.nextObject() as? URL {
                    if cancellation.isCancelled { throw CancellationError() }
                    scannedEntries += 1
                    let name = child.lastPathComponent
                    guard !excluded.contains(name), !name.hasPrefix(".") || name == ".venv" else { continue }
                    let info = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if info?.isDirectory == true, info?.isSymbolicLink != true, pending.count + visited < 4_000 {
                        pending.append((child, depth + 1))
                    }
                }
            }
            return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }.value
        } onCancel: { cancellation.cancel() }
    }

    static func create(name: String, at path: String, interpreter: String, workingDirectory: String, terminalTarget: PythonTerminalTarget) async throws -> PythonEnvironment {
        try validatePath(path)
        try validatePath(interpreter)
        try validatePath(workingDirectory)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PythonEnvironmentError.invalid("请输入环境名称。") }
        guard FileManager.default.isExecutableFile(atPath: interpreter), !isDirectory(URL(fileURLWithPath: interpreter)) else { throw PythonEnvironmentError.invalid("请选择绝对路径的可执行 Python 解释器。") }
        guard isDirectory(URL(fileURLWithPath: workingDirectory)) else { throw PythonEnvironmentError.invalid("工作目录不存在。") }
        try Task.checkCancellation()
        let destination = URL(fileURLWithPath: path)
        // Exclusive mkdir also rejects dangling symlinks and concurrent creators. Do not delete a failed
        // creation: Python may have written useful diagnostics/files and a user may have added files.
        guard mkdir(destination.path, mode_t(0o700)) == 0 else {
            throw PythonEnvironmentError.invalid("无法新建环境目录（不得覆盖已有路径）：\(String(cString: strerror(errno)))")
        }
        do {
            _ = try await run(interpreter, arguments: ["-I", "-m", "venv", destination.path], timeout: 120)
            let environment = PythonEnvironment(name: name, path: destination.path, workingDirectory: workingDirectory, terminalTarget: terminalTarget)
            try validate(environment)
            return environment
        } catch {
            if error is CancellationError { throw error }
            throw PythonEnvironmentError.process("创建环境失败：\(error.localizedDescription)\n已保留新建目录：\(destination.path)")
        }
    }

    static func activationCommand(for environment: PythonEnvironment, shell: String = "/bin/zsh") throws -> String {
        guard ["zsh", "bash"].contains(URL(fileURLWithPath: shell).lastPathComponent) else { throw PythonEnvironmentError.invalid("仅支持 zsh 和 bash 激活命令。") }
        try validate(environment)
        let activate = URL(fileURLWithPath: environment.path).appendingPathComponent("bin/activate").path
        return "source \(shellQuote(activate))"
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PythonEnvironmentError.invalid("路径必须是绝对路径，且不能包含换行或控制字符。")
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        let cancellation = PythonProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
                // Do not inherit PYTHONPATH, PYTHONHOME, startup hooks, or shell initialization.
                process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                defer {
                    try? stdout.fileHandleForReading.close()
                    try? stderr.fileHandleForReading.close()
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                }
                do { try process.run() }
                catch { throw PythonEnvironmentError.process("无法启动 Python：\(error.localizedDescription)") }
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                let handles = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
                for fd in handles { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                var output = [Data(), Data()]
                var ended = [false, false]
                var buffer = [UInt8](repeating: 0, count: 16_384)
                var failure: Error?
                while true {
                    // Drain both pipes on each iteration, even while the child is still running.
                    for index in 0..<2 where !ended[index] {
                        let count = Darwin.read(handles[index], &buffer, buffer.count)
                        if count > 0 {
                            if output[0].count + output[1].count + count > 2_097_152 {
                                failure = PythonEnvironmentError.process("Python 输出超过 2 MB 限制。")
                            } else { output[index].append(contentsOf: buffer.prefix(count)) }
                        } else if count == 0 { ended[index] = true }
                        else if errno != EAGAIN && errno != EINTR { ended[index] = true }
                    }
                    if cancellation.isCancelled { failure = CancellationError() }
                    if ProcessInfo.processInfo.systemUptime >= deadline { failure = PythonEnvironmentError.process("Python 执行超时（\(Int(timeout)) 秒）。") }
                    if let failure {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        throw failure
                    }
                    if !process.isRunning && ended.allSatisfy({ $0 }) { break }
                    usleep(5_000)
                }
                guard process.terminationStatus == 0 else {
                    let detail = String(decoding: output[1], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw PythonEnvironmentError.process("Python 执行失败（退出码 \(process.terminationStatus)）：\(detail.isEmpty ? "未提供错误信息" : detail)")
                }
                return output[0]
            }.value
        } onCancel: { cancellation.cancel() }
    }
}

private nonisolated final class PythonProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
