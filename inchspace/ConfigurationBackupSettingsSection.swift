import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let inchspaceBackup = UTType(exportedAs: "vip.lylab.inchspace.configuration-backup", conformingTo: .json)
}

struct ConfigurationBackupSettingsSection: View {
    @ObservedObject var repository: LaunchpadRepository
    @ObservedObject var preferences: AppWindowPreferences
    @State private var isChoosingFile = false
    @State private var isBusy = false
    @State private var preview: ImportPreview?
    @State private var pendingImport: ConfigurationBackup?
    @State private var message: String?
    @State private var messageTitle = "配置备份"
    private let coordinator = ConfigurationImportCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                AppIconTile(symbol: "externaldrive.badge.timemachine", size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text("配置备份")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("保存你的启动台，轻松迁移到另一台 Mac。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在处理配置")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    exportCard.frame(minWidth: 230)
                    importCard.frame(minWidth: 230)
                }
                VStack(spacing: 16) {
                    exportCard
                    importCard
                }
            }
            .disabled(isBusy)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    recoveryLabel
                    Spacer(minLength: 12)
                    recoveryButton
                }
                VStack(alignment: .leading, spacing: 16) {
                    recoveryLabel
                    recoveryButton
                }
            }
            .padding(22)
            .settingsGlassSurface()
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.inchspaceBackup],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { readImport(url) }
            case let .failure(error):
                let cocoaError = error as NSError
                if cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError { return }
                showMessage("无法读取配置", error.localizedDescription)
            }
        }
        .sheet(item: $preview, onDismiss: {
            guard let document = pendingImport else { return }
            pendingImport = nil
            applyImport(document)
        }) { candidate in
            ConfigurationImportPreview(document: candidate.document, fileName: candidate.fileName, localLibrary: repository.library) {
                preview = nil
            } confirm: {
                pendingImport = candidate.document
                preview = nil
            }
        }
        .alert(messageTitle, isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .frame(height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("保存一份配置").font(.headline)
                Text("导出启动台与通用设置，不含实际文件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("导出配置…", action: exportConfiguration)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .settingsGlassSurface()
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .frame(height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("从备份迁入").font(.headline)
                Text("预览后替换现有配置，实际文件不受影响。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("导入配置…") { isChoosingFile = true }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .settingsGlassSurface()
    }

    private var recoveryLabel: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("恢复备份").font(.headline)
                Text("每次导入前，自动留存当前配置。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recoveryButton: some View {
        Button("在 Finder 中查看", systemImage: "folder", action: revealRecoveryDirectory)
            .controlSize(.large)
            .disabled(isBusy)
    }

    private func readImport(_ url: URL) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try ConfigurationBackup.readData(from: url)
                }.value
                let document = try ConfigurationBackup.decode(data)
                preview = ImportPreview(document: document, fileName: url.lastPathComponent)
            } catch {
                showMessage("无法读取配置", error.localizedDescription)
            }
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.inchspaceBackup]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "inchspace-\(formatter.string(from: Date())).\(ConfigurationBackup.fileExtension)"
        panel.title = "导出启动台与通用设置"
        isBusy = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                isBusy = false
                return
            }
            Task {
                defer { isBusy = false }
                do {
                    let document = try coordinator.snapshot(repository: repository, preferences: preferences)
                    let data = try document.encoded()
                    try await Task.detached(priority: .userInitiated) {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        try data.write(to: url, options: .atomic)
                    }.value
                    showMessage("配置已导出", "已保存到：\(url.path)\n包含启动台和部分通用设置，不包含实际文件、设备授权或其他模块数据。")
                } catch {
                    showMessage("导出失败", error.localizedDescription)
                }
            }
        }
    }

    private func applyImport(_ document: ConfigurationBackup) {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try coordinator.importConfiguration(document, repository: repository, preferences: preferences)
            var summary = "已导入 \(result.itemCount) 个启动台项目及通用设置。"
            if result.needsAuthorizationCount > 0 {
                summary += "\n\(result.needsAuthorizationCount) 个程序或目录入口需要检查或重新授权。打开入口时可重新选择目标。"
            }
            summary += "\n导入前的恢复备份：\(result.recoveryURL.path)"
            showMessage("配置已导入", summary)
        } catch {
            showMessage("导入失败", error.localizedDescription)
        }
    }

    private func revealRecoveryDirectory() {
        do {
            try FileManager.default.createDirectory(at: coordinator.recoveryDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([coordinator.recoveryDirectory])
        } catch {
            showMessage("无法打开恢复备份", error.localizedDescription)
        }
    }

    private func showMessage(_ title: String, _ detail: String) {
        messageTitle = title
        message = detail
    }

    private struct ImportPreview: Identifiable {
        let id = UUID()
        let document: ConfigurationBackup
        let fileName: String
    }
}

private struct ConfigurationImportPreview: View {
    let document: ConfigurationBackup
    let fileName: String
    let localLibrary: LaunchpadLibrary
    let cancel: () -> Void
    let confirm: () -> Void

    private var unverifiedItems: [LaunchItem] {
        ConfigurationImportCoordinator.preparedLibrary(document.library, local: localLibrary)
            .items.filter { !$0.isAvailable }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入配置预览").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(fileName).font(.headline).textSelection(.enabled)
                    LabeledContent("导出时间", value: document.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("来源版本", value: document.appVersion)
                    Divider()
                    ForEach(LaunchItemCategory.allCases) { category in
                        LabeledContent(category.title, value: "\(document.library.items.filter { $0.category == category }.count) 个")
                    }
                    LabeledContent("分组", value: "\(document.library.groups.count) 个")
                    LabeledContent("打开后隐藏窗口", value: document.preferences.hidesAfterOpen ? "开启" : "关闭")
                    LabeledContent("窗口位置", value: document.preferences.windowPosition.title)
                    if !unverifiedItems.isEmpty {
                        Divider()
                        Text("\(unverifiedItems.count) 个入口需要检查或重新授权")
                            .font(.headline)
                        ForEach(unverifiedItems.prefix(12)) { item in
                            Text("\(item.category.title)：\(item.name)")
                                .lineLimit(2)
                        }
                        if unverifiedItems.count > 12 {
                            Text("另有 \(unverifiedItems.count - 12) 个入口")
                        }
                        Text("预览不会访问这些目标或请求目录权限。导入后可通过打开入口重新选择目标。")
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Label("替换当前启动台，不合并", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text("备份中没有的现有启动台项目将被移除。实际应用和文件不会被删除，其他模块、Dock、菜单栏和全局快捷键不受影响。")
                    Text("程序与目录入口可能需要重新定位或授权；仅保留目标完全匹配的本机授权。不会自动打开入口或执行任何任务。")
                        .foregroundStyle(.secondary)
                    Text("确认后会先保存当前配置的恢复备份；备份失败则停止导入。")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("备份当前配置并导入", action: confirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 570)
    }
}
