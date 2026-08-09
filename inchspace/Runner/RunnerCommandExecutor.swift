import Foundation

struct RunnerCommandResult: Sendable {
    let output: String
    let error: String
    let exitCode: Int32
}

enum RunnerCommandExecutor {
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> RunnerCommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            if let environment { process.environment = environment }
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            try process.run()
            // Drain while the process is running so verbose service listings cannot fill a pipe and stall.
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            return RunnerCommandResult(
                output: process.terminationStatus == 0 ? text : "",
                error: process.terminationStatus == 0 ? "" : text,
                exitCode: process.terminationStatus
            )
        }.value
    }
}
