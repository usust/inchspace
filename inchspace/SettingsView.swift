//
//  SettingsView.swift
//  inchspace
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var visibilityController: AppVisibilityController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var repository: LaunchpadRepository
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var terminalManager: TerminalManager
    @Binding var selectedCategory: SettingsTab
    @Namespace private var navigationNamespace

    private var generalSettings: some View {
        Group {
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
                        description: "选择主窗口首次创建时出现的位置",
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
        }
    }

    private var categoryPicker: some View {
        Picker("设置分类", selection: $selectedCategory) {
            ForEach(SettingsTab.allCases) { category in
                Label(category.title, systemImage: category.symbol)
                    .tag(category)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 780)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var categoryNavigation: some View {
        VStack(spacing: 6) {
            ForEach(SettingsTab.allCases) { category in
                Button {
                    withAnimation(reduceMotion ? nil : AppMotion.transition) {
                        selectedCategory = category
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: category.symbol)
                            .font(.system(size: 17, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(selectedCategory == category ? Color.accentColor : .secondary)
                            .frame(width: 24)
                        Text(category.title)
                            .font(.body.weight(selectedCategory == category ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background {
                        if selectedCategory == category {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.accentColor.opacity(0.12))
                                .matchedGeometryEffect(id: "selection", in: navigationNamespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(AppCardButtonStyle())
                .accessibilityAddTraits(selectedCategory == category ? [.isSelected] : [])
            }
        }
        .padding(10)
        .frame(width: 196)
        .settingsGlassSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置分类")
    }

    private var settingsForm: some View {
        Form {
            if selectedCategory == .general {
                generalSettings
            }
            if selectedCategory == .terminal {
                TerminalSettingsSection(manager: terminalManager)
            }
            TerminalAISettingsSection(
                settings: terminalManager.aiSettings,
                isVisible: selectedCategory == .ai
            )
            if selectedCategory == .updates {
                UpdateSettingsSection(updateManager: updateManager)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                AppFeatureTitle("设置")
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 8)

            GeometryReader { geometry in
                let isWide = geometry.size.width >= 760
                let layout = isWide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                    : AnyLayout(VStackLayout(spacing: 0))

                // Keep the form at the same structural position across size changes.
                layout {
                    Group {
                        if isWide {
                            categoryNavigation
                        } else {
                            categoryPicker
                        }
                    }
                    ZStack(alignment: .top) {
                        settingsForm
                            .opacity(selectedCategory == .backup ? 0 : 1)
                            .allowsHitTesting(selectedCategory != .backup)
                            .disabled(selectedCategory == .backup)
                            .accessibilityHidden(selectedCategory == .backup)
                        if selectedCategory == .backup {
                            ScrollView {
                                ConfigurationBackupSettingsSection(repository: repository, preferences: visibilityController.preferences)
                                    .frame(maxWidth: 760)
                                    .frame(maxWidth: .infinity)
                                    .padding(8)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("设置")
    }
}

private struct SettingsGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.appSurface(cornerRadius: 22)
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }
}

extension View {
    func settingsGlassSurface() -> some View {
        modifier(SettingsGlassSurface())
    }
}

struct SettingsPreferenceLabel: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
        }
        .help(description)
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
                    .font(.body)
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
