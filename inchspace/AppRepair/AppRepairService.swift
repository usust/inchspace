//
//  AppRepairService.swift
//  inchspace
//
//  使用系统自带工具进行只读诊断，并仅在用户确认后移除下载隔离属性。

import Foundation

struct AppRepairService: Sendable {
    nonisolated func inspect(_ url: URL) throws -> AppRepairReport {
        guard url.pathExtension.lowercased() == "app" else {
            throw AppRepairError.invalidApplication
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw AppRepairError.invalidApplication }

        let contentsURL = url.appending(path: "Contents", directoryHint: .isDirectory)
        let infoURL = contentsURL.appending(path: "Info.plist", directoryHint: .notDirectory)
        let info = NSDictionary(contentsOf: infoURL) as? [String: Any]
        let executableName = info?["CFBundleExecutable"] as? String
        let executableURL = executableName.map {
            contentsURL.appending(path: "MacOS", directoryHint: .isDirectory)
                .appending(path: $0, directoryHint: .notDirectory)
        }
        let structureIsValid = info != nil && executableURL.map {
            FileManager.default.isExecutableFile(atPath: $0.path)
        } == true

        let quarantine = run("/usr/bin/xattr", ["-r", "-p", "com.apple.quarantine", url.path])
        let signature = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", url.path])
        let gatekeeper = run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", url.path])
        let architectures = executableURL.map { architectureNames(for: $0) } ?? []

        let hasQuarantine = quarantine.exitCode == 0
        let signatureAccepted = signature.exitCode == 0
        let gatekeeperAccepted = gatekeeper.exitCode == 0
        let displayName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)

        var findings: [AppRepairFinding] = []
        findings.append(.init(
            id: "structure",
            kind: structureIsValid ? .success : .failure,
            title: structureIsValid ? "应用结构正常" : "应用结构不完整",
            detail: structureIsValid ? nil : "缺少 Info.plist 或可执行文件，重新下载通常比修复更安全。"
        ))
        findings.append(.init(
            id: "architecture",
            kind: architectures.isEmpty ? .warning : .success,
            title: architectureTitle(architectures),
            detail: architectures.isEmpty ? "无法识别主程序的处理器架构。" : architectures.joined(separator: " · ")
        ))
        findings.append(.init(
            id: "quarantine",
            kind: hasQuarantine ? .warning : .success,
            title: hasQuarantine ? "包含下载隔离属性" : "未发现下载隔离属性",
            detail: hasQuarantine ? "这可能触发“无法验证开发者”或“已损坏”的提示。" : nil
        ))
        findings.append(.init(
            id: "signature",
            kind: signatureAccepted ? .success : .warning,
            title: signatureAccepted ? "代码签名有效" : "代码签名未通过验证",
            detail: signatureAccepted ? nil : conciseOutput(signature.output, fallback: "应用可能未签名，或安装内容曾被修改。")
        ))
        findings.append(.init(
            id: "integrity",
            kind: structureIsValid && signatureAccepted ? .success : .warning,
            title: structureIsValid && signatureAccepted ? "未发现明显损坏风险" : "应用完整性需要留意",
            detail: structureIsValid && signatureAccepted
                ? nil
                : "结构或签名验证异常不一定代表恶意软件；若来源不可信，建议重新下载。"
        ))
        findings.append(.init(
            id: "gatekeeper",
            kind: gatekeeperAccepted ? .success : .warning,
            title: gatekeeperAccepted ? "已通过 Gatekeeper 验证" : "未通过 Gatekeeper 验证",
            detail: gatekeeperAccepted ? nil : conciseOutput(gatekeeper.output, fallback: "移除隔离属性后将再次验证。")
        ))

        return AppRepairReport(
            url: url,
            displayName: displayName,
            bundleIdentifier: info?["CFBundleIdentifier"] as? String,
            version: version,
            architectures: architectures,
            hasQuarantine: hasQuarantine,
            signatureAccepted: signatureAccepted,
            gatekeeperAccepted: gatekeeperAccepted,
            structureIsValid: structureIsValid,
            findings: findings
        )
    }

    nonisolated func repair(_ url: URL) throws -> AppRepairReport {
        let removal = run("/usr/bin/xattr", ["-r", "-d", "com.apple.quarantine", url.path])
        // xattr 返回 1 也可能只是没有该属性；复检结果才是最终依据。
        if removal.exitCode != 0 {
            let check = run("/usr/bin/xattr", ["-r", "-p", "com.apple.quarantine", url.path])
            if check.exitCode == 0 {
                let message = conciseOutput(removal.output, fallback: "无法移除下载隔离属性。")
                if message.localizedCaseInsensitiveContains("permission") || message.contains("不允许") {
                    throw AppRepairError.accessDenied
                }
                throw AppRepairError.commandFailed(message)
            }
        }

        refreshLaunchServices(for: url)
        let report = try inspect(url)
        guard !report.hasQuarantine else {
            throw AppRepairError.commandFailed("仍检测到下载隔离属性，请检查应用所在位置的写入权限。")
        }
        return report
    }

    nonisolated private func refreshLaunchServices(for url: URL) {
        let candidates = [
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        _ = run(executable, ["-f", url.path])
    }

    nonisolated private func architectureNames(for executableURL: URL) -> [String] {
        let result = run("/usr/bin/lipo", ["-archs", executableURL.path])
        guard result.exitCode == 0 else { return [] }
        return result.output.split(whereSeparator: \Character.isWhitespace).map { architectureDisplayName(String($0)) }
    }

    nonisolated private func architectureDisplayName(_ name: String) -> String {
        switch name {
        case "arm64", "arm64e": "Apple Silicon"
        case "x86_64": "Intel"
        default: name
        }
    }

    nonisolated private func architectureTitle(_ architectures: [String]) -> String {
        let unique = Set(architectures)
        if unique.contains("Apple Silicon") && unique.contains("Intel") { return "通用架构，兼容 Apple Silicon 与 Intel" }
        if unique.contains("Apple Silicon") { return "Apple Silicon 原生支持" }
        if unique.contains("Intel") { return "Intel 应用（Apple Silicon 上需要 Rosetta）" }
        return "架构信息未知"
    }

    nonisolated private func conciseOutput(_ output: String, fallback: String) -> String {
        let line = output
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        return line ?? fallback
    }

    nonisolated private func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(exitCode: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        } catch {
            return CommandResult(exitCode: -1, output: error.localizedDescription)
        }
    }
}

private struct CommandResult {
    let exitCode: Int32
    let output: String
}
