import SwiftUI

struct TerminalSettingsSection: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var preferences: TerminalPreferences

    init(manager: TerminalManager) {
        self.manager = manager
        self.preferences = manager.preferences
    }

    var body: some View {
        Section("终端") {
            LabeledContent {
                Picker("默认 Shell", selection: $preferences.shellOverride) {
                    Text("系统默认（\(URL(fileURLWithPath: preferences.resolvedShell).lastPathComponent)）").tag("")
                    ForEach(availableShells, id: \.self) { shell in
                        Text(shell).tag(shell)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } label: {
                SettingsPreferenceLabel(
                    title: "默认 Shell",
                    description: "本地终端优先使用当前 macOS 用户的登录 Shell",
                    systemImage: "terminal"
                )
            }

            LabeledContent {
                Picker("启动目录", selection: $preferences.startupDirectory) {
                    ForEach(TerminalStartupDirectory.allCases) { directory in
                        Text(directory.title).tag(directory)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } label: {
                SettingsPreferenceLabel(
                    title: "启动目录",
                    description: "选择新建本地终端时使用的工作目录",
                    systemImage: "folder"
                )
            }

            if preferences.startupDirectory == .custom {
                TextField("~/Projects", text: $preferences.customDirectory)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(isOn: $preferences.cleanShellStartup) {
                SettingsPreferenceLabel(
                    title: "干净启动新会话",
                    description: "zsh/bash 不载入旧配置输出与历史文件；每个 Tab 使用独立 PTY",
                    systemImage: "sparkles"
                )
            }

            LabeledContent {
                Picker("Prompt", selection: $preferences.promptStyle) {
                    ForEach(TerminalPromptStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } label: {
                SettingsPreferenceLabel(
                    title: "Shell Prompt",
                    description: "新会话生效，默认隐藏完整主机名",
                    systemImage: "chevron.right"
                )
            }

            if preferences.promptStyle == .custom {
                TextField("❯ ", text: $preferences.customPrompt)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent {
                Picker("字体", selection: $preferences.fontFamily) {
                    Text("SF Mono").tag("SF Mono")
                    Text("Menlo").tag("Menlo")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } label: {
                SettingsPreferenceLabel(
                    title: "字体",
                    description: "优先使用 SF Mono，缺失时自动回退到系统等宽字体",
                    systemImage: "textformat"
                )
            }

            LabeledContent {
                HStack(spacing: 8) {
                    Text("\(Int(preferences.fontSize)) pt").foregroundStyle(.secondary)
                    Stepper("字号", value: $preferences.fontSize, in: 12...18, step: 1).labelsHidden()
                }
            } label: {
                SettingsPreferenceLabel(
                    title: "字体大小",
                    description: "支持 12–18 pt，默认 14 pt",
                    systemImage: "textformat.size"
                )
            }


            LabeledContent {
                HStack(spacing: 8) {
                    Text(String(format: "%.2f×", preferences.lineHeight)).foregroundStyle(.secondary)
                    Stepper("行高", value: $preferences.lineHeight, in: 1.0...1.5, step: 0.05).labelsHidden()
                }
            } label: {
                SettingsPreferenceLabel(
                    title: "行高",
                    description: "调整 Cell 垂直间距，不影响中文宽字符对齐",
                    systemImage: "arrow.up.and.down.text.horizontal"
                )
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Picker("光标", selection: $preferences.cursorShape) {
                        ForEach(TerminalCursorShape.allCases) { shape in Text(shape.title).tag(shape) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Toggle("闪烁", isOn: $preferences.cursorBlinks)
                        .toggleStyle(.switch)
                }
            } label: {
                SettingsPreferenceLabel(
                    title: "光标",
                    description: "光标由 Terminal Cell Grid 定位",
                    systemImage: "cursorarrow.rays"
                )
            }

            LabeledContent {
                Picker("主题", selection: $preferences.theme) {
                    ForEach(TerminalThemePreference.allCases) { theme in Text(theme.title).tag(theme) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } label: {
                SettingsPreferenceLabel(
                    title: "外观",
                    description: "macOS Dark、Dracula、One Dark、Solarized 与 Catppuccin",
                    systemImage: "circle.lefthalf.filled"
                )
            }


            if preferences.theme == .custom {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    colorField("背景", text: $preferences.customBackgroundColor)
                    colorField("前景", text: $preferences.customForegroundColor)
                    colorField("光标", text: $preferences.customCursorColor)
                    colorField("选区", text: $preferences.customSelectionColor)
                }
            }

            LabeledContent {
                Picker("回滚行数", selection: $preferences.scrollbackLines) {
                    Text("1,000 行").tag(1_000)
                    Text("10,000 行").tag(10_000)
                    Text("50,000 行").tag(50_000)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } label: {
                SettingsPreferenceLabel(
                    title: "回滚缓冲区",
                    description: "每个会话独立保存历史输出",
                    systemImage: "text.line.last.and.arrowtriangle.forward"
                )
            }

            Toggle(isOn: $preferences.inheritWorkingDirectory) {
                SettingsPreferenceLabel(
                    title: "分屏继承当前目录",
                    description: "通过 OSC 7 获取目录；不会解析 Shell Prompt",
                    systemImage: "arrow.triangle.branch"
                )
            }


            Toggle(isOn: $preferences.copySelectionAutomatically) {
                SettingsPreferenceLabel(
                    title: "选择后自动复制",
                    description: "鼠标完成文本选择时写入系统剪贴板",
                    systemImage: "doc.on.doc"
                )
            }

            Toggle(isOn: $preferences.confirmBeforeClosing) {
                SettingsPreferenceLabel(
                    title: "关闭运行中终端前确认",
                    description: "避免意外结束终端中的进程",
                    systemImage: "exclamationmark.shield"
                )
            }

            Toggle(isOn: $preferences.automaticallyReconnect) {
                SettingsPreferenceLabel(
                    title: "自动重新连接远程终端",
                    description: "SSH 意外断开后等待三秒尝试重新连接",
                    systemImage: "arrow.clockwise"
                )
            }
        }
        .onChange(of: preferences.fontSize) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.fontFamily) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.lineHeight) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.cursorShape) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.cursorBlinks) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.theme) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.scrollbackLines) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.customBackgroundColor) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.customForegroundColor) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.customCursorColor) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.customSelectionColor) { _, _ in manager.applyPreferences() }
        .onChange(of: preferences.copySelectionAutomatically) { _, _ in manager.applyPreferences() }
    }

    private var availableShells: [String] {
        ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func colorField(_ title: String, text: Binding<String>) -> some View {
        GridRow {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("#RRGGBB", text: text)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
        }
    }
}
