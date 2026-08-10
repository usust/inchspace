//
//  AppRepairModels.swift
//  inchspace
//

import Foundation

enum AppRepairFindingKind: String, Sendable {
    case success
    case warning
    case failure
    case information

    var symbolName: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.circle.fill"
        case .information: "info.circle.fill"
        }
    }
}

struct AppRepairFinding: Identifiable, Sendable {
    let id: String
    let kind: AppRepairFindingKind
    let title: String
    let detail: String?
}

struct AppRepairReport: Sendable {
    let url: URL
    let displayName: String
    let bundleIdentifier: String?
    let version: String?
    let architectures: [String]
    let hasQuarantine: Bool
    let signatureAccepted: Bool
    let gatekeeperAccepted: Bool
    let structureIsValid: Bool
    let findings: [AppRepairFinding]

    var needsRepair: Bool { hasQuarantine }

    var summary: String {
        if !structureIsValid { return "应用结构可能不完整" }
        if hasQuarantine { return "发现可修复的下载隔离属性" }
        if gatekeeperAccepted { return "未发现常见的打开限制" }
        return "未发现隔离属性，但安全验证仍需注意"
    }
}

enum AppRepairError: LocalizedError {
    case invalidApplication
    case accessDenied
    case authorizationCancelled
    case administratorAuthorizationFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidApplication:
            "请选择一个有效的 macOS 应用（.app）。"
        case .accessDenied:
            "没有修改这个应用的权限。请确认应用未位于只读磁盘中，并重新选择。"
        case .authorizationCancelled:
            "已取消管理员授权，未能完成修复。应用内容没有被修改。"
        case let .administratorAuthorizationFailed(message):
            "管理员授权后仍未能完成修复：\(message)"
        case let .commandFailed(message):
            "修复未能完成：\(message)"
        }
    }
}
