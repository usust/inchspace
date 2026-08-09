import Foundation

protocol RunnerServiceManaging: Sendable {
    func services() async throws -> [RunnerService]
    func start(_ service: RunnerService) async throws
    func stop(_ service: RunnerService) async throws
    func restart(_ service: RunnerService) async throws
    func logs(for service: RunnerService) async throws -> String
}

struct LocalRunnerServiceManager: RunnerServiceManaging {
    private var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    func services() async throws -> [RunnerService] {
        let allServices = try await discoverableServices()
        return allServices.filter { $0.kind == .homebrew || !$0.identifier.hasPrefix("com.apple.") }
    }

    func services(including managed: [RunnerManagedService]) async throws -> ([RunnerService], [RunnerService]) {
        let available = try await discoverableServices()
        // Homebrew services are already a small, user-installed set. launchd can contain
        // hundreds of jobs, so only show launchd entries the user explicitly manages.
        var visible = available.filter { $0.kind == .homebrew }
        for reference in managed {
            if let detected = available.first(where: {
                $0.identifier == reference.identifier && $0.kind == reference.kind && $0.isSystemService == reference.isSystemService
            }) {
                if !visible.contains(where: { $0.id == detected.id }) { visible.append(detected) }
            } else {
                let status = try? await status(for: reference)
                visible.append(status ?? RunnerService(
                    identifier: reference.identifier,
                    displayName: reference.displayName,
                    kind: reference.kind,
                    state: .unknown,
                    isSystemService: reference.isSystemService
                ))
            }
        }
        return (
            visible.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            available
        )
    }

    func discoverableServices() async throws -> [RunnerService] {
        var result = try await launchdServices(includeAppleServices: true)
        if let brewPath {
            let command = try await RunnerCommandExecutor.run(executable: brewPath, arguments: ["services", "list", "--json"])
            if command.exitCode == 0,
               let data = command.output.data(using: .utf8),
               let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                result.append(contentsOf: values.compactMap { item in
                    guard let name = item["name"] as? String else { return nil }
                    let status = (item["status"] as? String ?? "").lowercased()
                    return RunnerService(
                        identifier: name,
                        displayName: name.replacingOccurrences(of: "@", with: " "),
                        kind: .homebrew,
                        state: status.contains("started") ? .running : (status.contains("error") ? .failed : .stopped),
                        detail: item["file"] as? String
                    )
                })
            }
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func start(_ service: RunnerService) async throws { try await perform("start", service) }
    func stop(_ service: RunnerService) async throws { try await perform("stop", service) }
    func restart(_ service: RunnerService) async throws { try await perform("restart", service) }

    func logs(for service: RunnerService) async throws -> String {
        guard service.kind == .homebrew, let brewPath else { return "此服务的日志由 macOS 统一日志管理。" }
        let result = try await RunnerCommandExecutor.run(executable: brewPath, arguments: ["services", "info", service.identifier])
        return result.output + result.error
    }

    private func perform(_ action: String, _ service: RunnerService) async throws {
        let result: RunnerCommandResult
        switch service.kind {
        case .homebrew:
            guard let brewPath else { throw RunnerError.processFailed("未找到 Homebrew。") }
            result = try await RunnerCommandExecutor.run(executable: brewPath, arguments: ["services", action, service.identifier])
        case .launchd:
            try await performLaunchd(action, service: service)
            return
        case .systemd:
            throw RunnerError.processFailed("本机无法操作服务器服务。")
        }
        guard result.exitCode == 0 else { throw RunnerError.processFailed(result.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func performLaunchd(_ action: String, service: RunnerService) async throws {
        let domain = service.isSystemService ? "system" : "gui/\(getuid())"
        let target = "\(domain)/\(service.identifier)"
        switch action {
        case "start":
            try await requireLaunchctlSuccess(["enable", target])
            try await requireLaunchctlSuccess(["kickstart", target])
        case "stop":
            // Disable first so KeepAlive services do not immediately relaunch after termination.
            try await requireLaunchctlSuccess(["disable", target])
            _ = try await RunnerCommandExecutor.run(
                executable: "/bin/launchctl",
                arguments: ["kill", "SIGTERM", target]
            )
        case "restart":
            try await requireLaunchctlSuccess(["kickstart", "-k", target])
        default:
            throw RunnerError.processFailed("不支持的服务操作。")
        }
    }

    private func requireLaunchctlSuccess(_ arguments: [String]) async throws {
        let result = try await RunnerCommandExecutor.run(executable: "/bin/launchctl", arguments: arguments)
        guard result.exitCode == 0 else {
            throw RunnerError.processFailed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func launchdServices(includeAppleServices: Bool) async throws -> [RunnerService] {
        // On current macOS versions `launchctl list` can return an empty stream to a
        // sandboxed app, while printing the GUI domain still exposes its service table.
        let domainResult = try await RunnerCommandExecutor.run(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())"]
        )
        if domainResult.exitCode == 0 {
            let services = Self.parseLaunchdDomain(domainResult.output, includeAppleServices: includeAppleServices)
            if !services.isEmpty { return services }
        }

        let legacyResult = try await RunnerCommandExecutor.run(executable: "/bin/launchctl", arguments: ["list"])
        guard legacyResult.exitCode == 0 else { return [] }
        return Self.parseLaunchdDomain(legacyResult.output, includeAppleServices: includeAppleServices)
    }

    nonisolated static func parseLaunchdDomain(
        _ output: String,
        includeAppleServices: Bool
    ) -> [RunnerService] {
        var seen = Set<String>()
        return output.split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: \Character.isWhitespace)
            // Service table rows are: PID, last exit status (or '-'), label.
            // Other launchctl print sections have a different column shape.
            guard columns.count == 3, let rawPID = Int(columns[0]) else { return nil }
            let label = String(columns[2]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !label.isEmpty,
                  (includeAppleServices || !label.hasPrefix("com.apple.")),
                  seen.insert(label).inserted else { return nil }
            let pid = rawPID > 0 ? rawPID : nil
            return RunnerService(
                identifier: label,
                displayName: label.split(separator: ".").last.map(String.init) ?? label,
                kind: .launchd,
                state: pid == nil ? .stopped : .running,
                detail: pid.map { "PID \($0)" }
            )
        }
    }

    private func status(for reference: RunnerManagedService) async throws -> RunnerService {
        guard reference.kind == .launchd else {
            return RunnerService(
                identifier: reference.identifier,
                displayName: reference.displayName,
                kind: reference.kind,
                state: .unknown,
                isSystemService: reference.isSystemService
            )
        }
        let domain = reference.isSystemService ? "system" : "gui/\(getuid())"
        let result = try await RunnerCommandExecutor.run(
            executable: "/bin/launchctl",
            arguments: ["print", "\(domain)/\(reference.identifier)"]
        )
        let state: RunnerServiceState
        if result.exitCode != 0 { state = .stopped }
        else if result.output.contains("state = running") { state = .running }
        else { state = .stopped }
        return RunnerService(
            identifier: reference.identifier,
            displayName: reference.displayName,
            kind: .launchd,
            state: state,
            isSystemService: reference.isSystemService
        )
    }
}

struct SystemdRunnerServiceManager: RunnerServiceManaging {
    let server: RunnerServer

    func services() async throws -> [RunnerService] {
        let result = try await execute(["list-units", "--type=service", "--all", "--no-legend", "--no-pager", "--plain"])
        guard result.exitCode == 0 else { throw RunnerError.processFailed(result.error) }
        return result.output.split(separator: "\n").compactMap { line in
            let columns = line.split(maxSplits: 4, whereSeparator: \Character.isWhitespace)
            guard columns.count >= 4 else { return nil }
            let identifier = String(columns[0])
            let active = String(columns[2])
            let sub = String(columns[3])
            return RunnerService(
                identifier: identifier,
                displayName: identifier.replacingOccurrences(of: ".service", with: ""),
                kind: .systemd,
                state: active == "active" ? .running : (sub == "failed" ? .failed : .stopped),
                detail: columns.count > 4 ? String(columns[4]) : nil
            )
        }
    }

    func start(_ service: RunnerService) async throws { try await perform("start", service) }
    func stop(_ service: RunnerService) async throws { try await perform("stop", service) }
    func restart(_ service: RunnerService) async throws { try await perform("restart", service) }

    func logs(for service: RunnerService) async throws -> String {
        let result = try await ssh(["journalctl", "-u", service.identifier, "-n", "250", "--no-pager", "--output=short-iso"])
        guard result.exitCode == 0 else { throw RunnerError.processFailed(result.error) }
        return result.output
    }

    private func perform(_ action: String, _ service: RunnerService) async throws {
        let result = try await execute([action, service.identifier])
        guard result.exitCode == 0 else { throw RunnerError.processFailed(result.error) }
    }

    private func execute(_ arguments: [String]) async throws -> RunnerCommandResult {
        try await ssh(["systemctl"] + arguments)
    }

    private func ssh(_ remoteArguments: [String]) async throws -> RunnerCommandResult {
        let keyURL = try server.keyBookmark.map(SecurityScopedBookmarkService.resolve)
            ?? URL(fileURLWithPath: server.keyPath)
        let didStart = keyURL.startAccessingSecurityScopedResource()
        defer { if didStart { keyURL.stopAccessingSecurityScopedResource() } }
        let supportDirectory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("vip.lylab.inchspace", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let knownHostsPath = supportDirectory.appendingPathComponent("runner-known-hosts").path
        let args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "UseKeychain=yes",
            "-o", "AddKeysToAgent=yes",
            "-p", String(server.port),
            "-i", keyURL.path,
            "\(server.username)@\(server.host)"
        ] + remoteArguments
        return try await RunnerCommandExecutor.run(executable: "/usr/bin/ssh", arguments: args)
    }
}
