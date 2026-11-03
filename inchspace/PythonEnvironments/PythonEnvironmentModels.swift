import Foundation

nonisolated enum PythonTerminalTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtIn, system
    var id: String { rawValue }
    var title: String { self == .builtIn ? "内置终端" : "系统终端" }
}

nonisolated struct PythonEnvironment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var workingDirectory: String
    var terminalTarget: PythonTerminalTarget = .builtIn
    var pythonPath: String { URL(fileURLWithPath: path).appendingPathComponent("bin/python").path }
}

nonisolated struct PythonEnvironmentInspection: Sendable {
    let version: String
    let kind: String
}

nonisolated struct PythonInstalledPackage: Decodable, Identifiable, Sendable {
    let name: String
    let version: String
    var id: String { name }
}

nonisolated enum PythonEnvironmentError: LocalizedError {
    case invalid(String)
    case process(String)
    case persistence(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .process(let message), .persistence(let message): return message
        }
    }
}
