import AppKit

/// Uses normal application termination so document save prompts remain under the app's control.
@MainActor
struct AppLanguageRestartService {
    struct RunningApplication {
        let terminate: () -> Bool
        let isTerminated: () -> Bool
    }

    var runningApplications: (URL) throws -> [RunningApplication] = { url in
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == canonicalURL
        }
        guard running.allSatisfy({ $0.activationPolicy == .regular }) else {
            throw RestartError.backgroundService
        }
        return running.map { application in
            RunningApplication(terminate: { application.terminate() }, isTerminated: { application.isTerminated })
        }
    }
    var openApplication: (URL) async throws -> Void = { url in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    var pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) }
    var maximumWaits = 100

    static func unavailableReason(for app: LanguageApplication) -> String? {
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return "请从菜单退出 inchspace 后重新打开。"
        }
        let path = app.url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/System/Library/") && !path.hasPrefix("/System/Library/CoreServices/Applications/") {
            return "系统后台组件不支持在此重启。"
        }
        return nil
    }

    func restart(_ app: LanguageApplication) async throws {
        if let reason = Self.unavailableReason(for: app) { throw RestartError.unavailable(reason) }
        let running = try runningApplications(app.url)
        for application in running where !application.isTerminated() {
            guard application.terminate() else { throw RestartError.quitDeclined }
        }
        var waits = 0
        while !running.allSatisfy({ $0.isTerminated() }) {
            guard waits < maximumWaits else { throw RestartError.quitTimedOut }
            try Task.checkCancellation()
            try await pause()
            waits += 1
        }
        try Task.checkCancellation()
        try await openApplication(app.url)
    }
}

enum RestartError: LocalizedError {
    case backgroundService, quitDeclined, quitTimedOut, unavailable(String)

    var errorDescription: String? {
        switch self {
        case .backgroundService: "此应用正在后台运行，不支持在此重启。语言设置已保留。"
        case .quitDeclined: "应用未能退出。请处理未保存的内容后，再点击重启应用。"
        case .quitTimedOut: "应用仍未退出。请完成其保存对话框或自行退出，然后重试。"
        case .unavailable(let reason): reason
        }
    }
}
