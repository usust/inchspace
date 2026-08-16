import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let output: String
}

nonisolated final class CancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) { lock.withLock { self.process = process } }
    func cancel() { lock.withLock { process?.interrupt(); process?.terminate() } }
}

enum OpenSSHProcess {
    /// Values passed through `-o` are parsed again using ssh_config syntax.
    /// Quote them here so paths containing spaces remain a single value.
    static func configurationOption(_ keyword: String, value: String) -> String {
        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(keyword)=\"\(escapedValue)\""
    }

    static func run(
        executable: String,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String]? = nil,
        cancellation: CancellableProcess? = nil
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let inputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            if input != nil { process.standardInput = inputPipe }
            cancellation?.set(process)
            try process.run()
            if let input {
                try inputPipe.fileHandleForWriting.write(contentsOf: input)
                try inputPipe.fileHandleForWriting.close()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try Task.checkCancellation()
            return ProcessResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
