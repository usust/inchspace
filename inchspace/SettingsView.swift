//
//  SettingsView.swift
//  inchspace
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var syncManager: ICloudSyncManager
    let onSyncConfigurationChanged: () -> Void
    @State private var isChoosingFolder = false
    @State private var isConfirmingFolderRemoval = false
    @State private var configurationError: String?

    var body: some View {
        Form {
            Section("iCloud 与数据") {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 6) {
                            if syncManager.status == .syncing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: statusSymbol)
                            }
                            Text(statusTitle)
                        }
                        .foregroundStyle(statusColor)
                        if let date = syncManager.lastSuccessfulSync {
                            Text("最后同步：\(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("iCloud Drive")
                                .fontWeight(.medium)
                            Text("将程序、目录、网站及工作台布局同步到您选择的 iCloud Drive 文件夹。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "icloud")
                            .foregroundStyle(.tint)
                    }
                }

                Toggle("使用 iCloud 同步", isOn: Binding(
                    get: { syncManager.isEnabled },
                    set: { enabled in
                        syncManager.setEnabled(enabled)
                        if enabled { onSyncConfigurationChanged() }
                    }
                ))
                .disabled(!syncManager.isConfigured)

                LabeledContent("同步文件夹") {
                    if let folderName = syncManager.selectedFolderName {
                        HStack(spacing: 8) {
                            Text(folderName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Menu {
                                Button("更改同步文件夹…") {
                                    isChoosingFolder = true
                                }
                                Button("在 Finder 中显示") {
                                    revealFolderInFinder()
                                }
                                Divider()
                                Button("停止使用此文件夹…", role: .destructive) {
                                    isConfirmingFolderRemoval = true
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .help("管理同步文件夹")
                            .accessibilityLabel("管理同步文件夹")
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("未选择")
                                .foregroundStyle(.secondary)
                            Button("选择…") {
                                isChoosingFolder = true
                            }
                        }
                    }
                }

                if case let .error(message) = syncManager.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("设置")
        .task { await syncManager.refreshAccountStatus() }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                try syncManager.configureFolder(url)
                configurationError = nil
                onSyncConfigurationChanged()
            } catch {
                configurationError = error.localizedDescription
            }
        }
        .alert("无法使用同步文件夹", isPresented: Binding(
            get: { configurationError != nil },
            set: { if !$0 { configurationError = nil } }
        )) {
            Button("好") { configurationError = nil }
        } message: {
            Text(configurationError ?? "未知错误")
        }
        .confirmationDialog(
            "停止使用此同步文件夹？",
            isPresented: $isConfirmingFolderRemoval
        ) {
            Button("停止使用", role: .destructive) {
                syncManager.removeFolder()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("停止后，应用将不再使用“\(syncManager.selectedFolderName ?? "此文件夹")”作为同步位置。本机数据不会被删除。")
        }
    }

    private var statusTitle: String {
        switch syncManager.status {
        case .notConfigured: "未选择同步文件夹"
        case .disabled: "同步已关闭"
        case .unavailable: "iCloud 不可用"
        case .syncing: "正在同步…"
        case .synced: "已同步"
        case .error: "同步失败"
        }
    }

    private func revealFolderInFinder() {
        do {
            try syncManager.revealFolderInFinder()
        } catch {
            configurationError = error.localizedDescription
        }
    }

    private var statusSymbol: String {
        switch syncManager.status {
        case .notConfigured: "folder.badge.questionmark"
        case .disabled: "icloud.slash"
        case .unavailable: "exclamationmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.icloud"
        case .error: "exclamationmark.icloud"
        }
    }

    private var statusColor: Color {
        switch syncManager.status {
        case .notConfigured: .secondary
        case .synced: .green
        case .error: Color(nsColor: .systemRed)
        case .unavailable: .orange
        case .disabled: .secondary
        case .syncing: .primary
        }
    }
}
