//
//  SettingsView.swift
//  inchspace
//

import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var visibilityController: AppVisibilityController
    @ObservedObject var syncManager: ICloudSyncManager
    @ObservedObject var updateManager: UpdateManager
    let onSyncConfigurationChanged: () -> Void
    @State private var isChoosingFolder = false
    @State private var isConfirmingFolderRemoval = false
    @State private var configurationError: String?

    var body: some View {
        Form {
            Section("窗口与驻留") {
                Toggle(isOn: Binding(
                    get: { visibilityController.preferences.hidesAfterOpen },
                    set: visibilityController.setHidesAfterOpen
                )) {
                    SettingsPreferenceLabel(
                        title: "打开项目后自动隐藏窗口",
                        description: "启动应用、目录或网站后自动隐藏本程序窗口",
                        systemImage: "rectangle.portrait.and.arrow.forward"
                    )
                }

                Toggle(isOn: Binding(
                    get: { visibilityController.preferences.showsDockIcon },
                    set: visibilityController.setShowsDockIcon
                )) {
                    SettingsPreferenceLabel(
                        title: "显示 Dock 图标",
                        description: "关闭后，本程序将在后台运行，通过快捷键唤起",
                        systemImage: "dock.rectangle"
                    )
                }

                Toggle(isOn: Binding(
                    get: { visibilityController.preferences.showsMenuBarIcon },
                    set: visibilityController.setShowsMenuBarIcon
                )) {
                    SettingsPreferenceLabel(
                        title: "显示菜单栏图标",
                        description: "通过菜单栏快速访问程序",
                        systemImage: "menubar.rectangle"
                    )
                }

                LabeledContent {
                    Picker("窗口位置", selection: Binding(
                        get: { visibilityController.preferences.position },
                        set: visibilityController.setWindowPosition
                    )) {
                        ForEach(WindowPositionPreference.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } label: {
                    SettingsPreferenceLabel(
                        title: "窗口位置",
                        description: "选择每次唤起时主窗口出现的位置",
                        systemImage: "macwindow.on.rectangle"
                    )
                }
            }

            Section("全局快捷键") {
                LabeledContent {
                    GlobalShortcutRecorder()
                } label: {
                    SettingsPreferenceLabel(
                        title: "全局快捷键",
                        description: "在任何应用中快速显示或隐藏主窗口",
                        systemImage: "keyboard"
                    )
                }

                if let message = visibilityController.shortcutRegistrationError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

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
                            Text("将程序、目录、网站、工作台布局及通用应用偏好同步到您选择的 iCloud Drive 文件夹。")
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

            UpdateSettingsSection(updateManager: updateManager)
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

private struct SettingsPreferenceLabel: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
    }
}

private struct GlobalShortcutRecorder: View {
    @EnvironmentObject private var visibilityController: AppVisibilityController
    @State private var isRecording = false
    @State private var eventMonitor: Any?
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Text(visibilityController.preferences.shortcut.displayName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10))
                    }

                Button(isRecording ? "请按新的快捷键组合" : "修改快捷键") {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if isRecording {
                Text("按 Esc 取消；快捷键需包含 Command、Option、Control 或 Shift")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        validationMessage = nil
        isRecording = true
        visibilityController.beginShortcutRecording()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return nil }
            if event.keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async { stopRecording() }
                return nil
            }
            guard let shortcut = AppGlobalShortcut.from(event) else {
                DispatchQueue.main.async {
                    validationMessage = "请同时按下至少一个修饰键"
                }
                return nil
            }
            DispatchQueue.main.async {
                if visibilityController.setGlobalShortcut(shortcut) {
                    validationMessage = nil
                    stopRecording()
                } else {
                    validationMessage = "该快捷键可能已被系统或其他应用占用"
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
        visibilityController.endShortcutRecording()
    }
}
