import Foundation

enum EnvironmentVariableType: String, Sendable {
    case normal
    case path
}

enum EnvironmentVariableStatus: Sendable, Equatable {
    case valid
    case disabled
    case readOnly
    case exportedToPath
    case missingDirectory
    case unavailable
}

struct EnvironmentVariableSource: Identifiable, Hashable, Sendable {
    let id: String
    let fileURL: URL?
    let displayName: String
    let value: String
    let line: Int?
    let isManaged: Bool
    let isProcessEnvironment: Bool
    let isEnabled: Bool
    let isExportedToPath: Bool

    nonisolated init(
        fileURL: URL?,
        displayName: String,
        value: String,
        line: Int? = nil,
        isManaged: Bool = false,
        isProcessEnvironment: Bool = false,
        isEnabled: Bool = true,
        isExportedToPath: Bool = false
    ) {
        self.fileURL = fileURL
        self.displayName = displayName
        self.value = value
        self.line = line
        self.isManaged = isManaged
        self.isProcessEnvironment = isProcessEnvironment
        self.isEnabled = isEnabled
        self.isExportedToPath = isExportedToPath
        id = "\(fileURL?.path ?? "process"):\(line ?? 0):\(value):\(isEnabled):\(isExportedToPath)"
    }
}

struct EnvironmentVariable: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let effectiveValue: String
    let sources: [EnvironmentVariableSource]
    let managedByApp: Bool
    let variableType: EnvironmentVariableType
    let status: EnvironmentVariableStatus

    var sourceSummary: String {
        let fileSources = sources.filter { !$0.isProcessEnvironment }
        if fileSources.count > 1 { return "\(fileSources.count) 个来源" }
        return fileSources.first?.displayName ?? sources.first?.displayName ?? "当前 App"
    }
}

struct EnvironmentPathEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    var path: String
    var exists: Bool

    nonisolated init(id: UUID = UUID(), path: String, exists: Bool) {
        self.id = id
        self.path = path
        self.exists = exists
    }
}

struct EnvironmentScanIssue: Identifiable, Hashable, Sendable {
    var id: URL { fileURL }
    let fileURL: URL
    let message: String
}

enum EnvironmentServiceError: LocalizedError {
    case invalidVariableName
    case unsupportedEncoding(URL)
    case invalidConfiguration(URL)
    case sourceNotFound
    case duplicatePath
    case readOnlySource
    case disabledSource
    case unsafeConfiguration(URL)

    var errorDescription: String? {
        switch self {
        case .invalidVariableName: "变量名称只能包含字母、数字和下划线，且不能以数字开头。"
        case let .unsupportedEncoding(url): "无法读取 \(url.lastPathComponent)：仅支持 UTF-8 Shell 配置文件。"
        case let .invalidConfiguration(url): "写入 \(url.lastPathComponent) 后校验失败，原文件未被修改。"
        case .sourceNotFound: "找不到该环境变量的配置来源。"
        case .duplicatePath: "这个目录已经存在于 PATH 中。"
        case .readOnlySource: "当前 App 环境仅供查看，不能修改、禁用或删除。"
        case .disabledSource: "请先启用该变量，再进行编辑。"
        case let .unsafeConfiguration(url): "拒绝修改 \(url.path)：只允许操作用户 Home 内的受支持 Shell 配置文件。"
        }
    }
}

enum EnvironmentSourceFilter: Hashable, Identifiable, Sendable {
    case all
    case process
    case file(URL)

    var id: String {
        switch self {
        case .all: "all"
        case .process: "process"
        case let .file(url): url.standardizedFileURL.path
        }
    }

    var title: String {
        switch self {
        case .all: "全部来源"
        case .process: "当前 App"
        case let .file(url): "~/\(url.lastPathComponent)"
        }
    }
}
