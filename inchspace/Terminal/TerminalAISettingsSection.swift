import SwiftUI

struct TerminalAISettingsSection: View {
    @ObservedObject var settings: TerminalAISettings
    @State private var apiKeyDraft = ""
    @State private var models: [String] = []
    @State private var isFetchingModels = false
    @State private var modelMessage: ModelMessage?

    var body: some View {
        Section("DeepSeek") {
            LabeledContent {
                Text("api.deepseek.com")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            } label: {
                SettingsPreferenceLabel(
                    title: "DeepSeek API",
                    description: "服务地址由 InchSpace 管理，无需手动配置",
                    systemImage: "sparkles"
                )
            }

            LabeledContent {
                HStack(spacing: 8) {
                    SecureField(settings.hasAPIKey ? "输入新 Key 可替换" : "输入 DeepSeek API Key", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                        .onSubmit(saveKey)

                    if settings.hasAPIKey && apiKeyDraft.isEmpty {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if settings.hasAPIKey {
                        Button("移除") {
                            settings.setAPIKey("")
                            settings.model = ""
                            models = []
                            modelMessage = nil
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } label: {
                SettingsPreferenceLabel(
                    title: "API Key",
                    description: "仅保存在本机 macOS 钥匙串，不写入偏好或项目文件",
                    systemImage: "key"
                )
            }

            LabeledContent {
                HStack(spacing: 8) {
                    Picker("模型", selection: $settings.model) {
                        Text("请选择模型").tag("")
                        if !settings.model.isEmpty && !models.contains(settings.model) {
                            Text(settings.model).tag(settings.model)
                        }
                        ForEach(models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)

                    Button {
                        Task { await fetchModels() }
                    } label: {
                        if isFetchingModels {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("获取中…")
                            }
                        } else {
                            Label("获取模型", systemImage: "arrow.clockwise")
                        }
                    }
                    .frame(minWidth: 92)
                    .disabled(isFetchingModels || (!settings.hasAPIKey && apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            } label: {
                SettingsPreferenceLabel(
                    title: "模型",
                    description: "使用 API Key 从 DeepSeek 实时查询后选择，不使用内置列表",
                    systemImage: "cpu"
                )
            }

            if let message = settings.keychainError {
                statusLabel(message, style: .error)
            } else if let modelMessage {
                statusLabel(modelMessage.text, style: modelMessage.style)
            }
        }

        Section("AI 上下文与安全") {
            Toggle(isOn: $settings.terminalContextEnabled) {
                SettingsPreferenceLabel(
                    title: "终端上下文",
                    description: "提交问题时附带当前 Session 元数据；终端输出始终视为不可信数据",
                    systemImage: "terminal"
                )
            }

            Toggle(isOn: $settings.recentOutputEnabled) {
                SettingsPreferenceLabel(
                    title: "最近输出",
                    description: "最多附带最近 200 行 / 20,000 字符，不上传完整 Scrollback",
                    systemImage: "text.line.last.and.arrowtriangle.forward"
                )
            }
            .disabled(!settings.terminalContextEnabled)

            Toggle(isOn: $settings.secretRedactionEnabled) {
                SettingsPreferenceLabel(
                    title: "敏感信息遮盖",
                    description: "发送前过滤 API Key、Token、密码、Authorization 与私钥",
                    systemImage: "eye.slash"
                )
            }

            LabeledContent {
                Picker("命令授权", selection: $settings.permission) {
                    ForEach(TerminalAICommandPermission.allCases.filter { $0 != .autoApproveSession }) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } label: {
                SettingsPreferenceLabel(
                    title: "命令执行",
                    description: "安全模式只放行解析后的只读单命令；复合与高风险命令需要确认",
                    systemImage: "exclamationmark.shield"
                )
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ text: String, style: ModelMessage.Style) -> some View {
        Label(text, systemImage: style == .success ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(style == .success ? Color.green : Color.orange)
    }

    private func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        settings.setAPIKey(key)
        if settings.keychainError == nil { apiKeyDraft = "" }
    }

    @MainActor
    private func fetchModels() async {
        modelMessage = nil

        if !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saveKey()
        }
        guard settings.keychainError == nil else { return }

        do {
            let key = try settings.apiKey()
            guard !key.isEmpty else {
                modelMessage = ModelMessage(text: "请先输入 DeepSeek API Key。", style: .error)
                return
            }

            isFetchingModels = true
            defer { isFetchingModels = false }
            let fetchedModels = try await DeepSeekModelService().fetchModels(apiKey: key)
            models = fetchedModels
            if !settings.model.isEmpty && !fetchedModels.contains(settings.model) {
                settings.model = ""
            }
            modelMessage = fetchedModels.isEmpty
                ? ModelMessage(text: "DeepSeek 当前没有返回可用模型。", style: .error)
                : ModelMessage(text: "已获取 \(fetchedModels.count) 个模型，请从列表中选择。", style: .success)
        } catch {
            modelMessage = ModelMessage(text: error.localizedDescription, style: .error)
        }
    }
}

private struct ModelMessage {
    enum Style { case success, error }
    let text: String
    let style: Style
}
