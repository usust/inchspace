import Combine
import Foundation

@MainActor
final class PythonEnvironmentStore: ObservableObject {
    @Published private(set) var environments: [PythonEnvironment] = []
    @Published var errorMessage: String?
    private let fileURL: URL
    private var loadFailed = false

    init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? base.appendingPathComponent("vip.lylab.inchspace", isDirectory: true)
            .appendingPathComponent("python-environments.json")
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        do {
            let loaded = try JSONDecoder().decode([PythonEnvironment].self, from: Data(contentsOf: self.fileURL))
            guard Set(loaded.map(\.id)).count == loaded.count,
                  Set(loaded.map { Self.resolvedPath($0.path) }).count == loaded.count else {
                throw PythonEnvironmentError.persistence("环境记录包含重复标识或目录。")
            }
            environments = loaded
        } catch {
            loadFailed = true
            errorMessage = "无法读取 Python 环境记录；为保护原文件，已禁止保存：\(error.localizedDescription)"
        }
    }

    func save(_ environment: PythonEnvironment) throws {
        try perform {
            guard !environment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PythonEnvironmentError.invalid("请输入环境名称。")
            }
            try PythonEnvironmentService.validate(environment)
            let path = Self.resolvedPath(environment.path)
            guard !environments.contains(where: { $0.id != environment.id && Self.resolvedPath($0.path) == path }) else {
                throw PythonEnvironmentError.persistence("该 Python 环境目录已存在，请编辑已有记录。")
            }
            var updated = environments
            if let index = updated.firstIndex(where: { $0.id == environment.id }) { updated[index] = environment }
            else { updated.append(environment) }
            try persist(updated)
            environments = updated
        }
    }

    /// Removes only the saved record, never the environment directory or its contents.
    func remove(_ environment: PythonEnvironment) throws {
        try perform {
            let updated = environments.filter { $0.id != environment.id }
            try persist(updated)
            environments = updated
        }
    }

    private func perform(_ operation: () throws -> Void) throws {
        do {
            guard !loadFailed else { throw PythonEnvironmentError.persistence("原 Python 环境记录无法读取，请先备份并修复该文件后重新打开。") }
            try operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func persist(_ environments: [PythonEnvironment]) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(environments).write(to: fileURL, options: .atomic)
        } catch { throw PythonEnvironmentError.persistence("无法保存 Python 环境记录：\(error.localizedDescription)") }
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
