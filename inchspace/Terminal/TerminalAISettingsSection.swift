import SwiftUI

struct TerminalAISettingsSection: View {
    @ObservedObject var settings: TerminalAISettings
    @State private var editor: ProviderEditorRequest?
    @State private var providerMessage: ModelMessage?

    var isVisible = true

    var body: some View {
        Group {
            if isVisible {
                providerSettings
                safetySettings
            }
        }
        .sheet(item: $editor) { request in
            TerminalAIProviderEditor(settings: settings, provider: request.provider, isNew: request.isNew)
        }
    }

    private var providerSettings: some View {
        Section("AI 服务") {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("选择 AI 提供商").font(.headline)
                        Spacer(minLength: 12)
                        addProviderButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("选择 AI 提供商").font(.headline)
                        addProviderButton
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(settings.providerProfiles) { provider in
                        providerCard(provider)
                    }
                }

                if let providerMessage {
                    Label(providerMessage.text, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var addProviderButton: some View {
        Button {
            providerMessage = nil
            editor = ProviderEditorRequest(
                provider: TerminalAIProviderProfile(
                    name: "",
                    configuration: TerminalAIConfiguration(service: .custom, baseURL: "")
                ),
                isNew: true
            )
        } label: {
            Label("新增提供商", systemImage: "plus")
        }
        .accessibilityIdentifier("ai.addProvider")
    }

    private func providerCard(_ provider: TerminalAIProviderProfile) -> some View {
        let service = provider.configuration.service
        let isSelected = settings.activeProviderID == provider.id
        let isConfigured = (try? provider.configuration.validated()) != nil
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                do {
                    try settings.activateProvider(id: provider.id)
                    providerMessage = nil
                } catch {
                    providerMessage = ModelMessage(text: error.localizedDescription, style: .error)
                }
            } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: service.cardSymbol)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .frame(width: 34, height: 34)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        Spacer(minLength: 8)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.name)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(service.cardDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("启用 \(provider.name)")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityIdentifier("ai.provider.\(provider.id)")

            HStack {
                Text(isConfigured ? (isSelected ? "已启用" : "可启用") : "未配置")
                    .font(.caption)
                    .foregroundStyle(isSelected && isConfigured ? Color.accentColor : Color.secondary)
                Spacer(minLength: 8)
                Button("详情") {
                    providerMessage = nil
                    editor = ProviderEditorRequest(provider: provider, isNew: false)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("\(provider.name) 详情")
                .accessibilityIdentifier("ai.providerDetails.\(provider.id)")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 1.5 : 1)
                .allowsHitTesting(false)
        }
    }

    private var safetySettings: some View {
        Section("上下文与安全") {
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
}

private struct ProviderEditorRequest: Identifiable {
    let provider: TerminalAIProviderProfile
    let isNew: Bool
    var id: String { provider.id }
}

private struct TerminalAIProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: TerminalAISettings
    private let providerID: String
    private let isNew: Bool
    @State private var name: String
    @State private var draft: TerminalAIConfiguration
    @State private var apiKeyDraft = ""
    @State private var hasSavedKey = false
    @State private var models: [String] = []
    @State private var isFetchingModels = false
    @State private var modelMessage: ModelMessage?
    @State private var modelFetchTask: Task<Void, Never>?

    init(settings: TerminalAISettings, provider: TerminalAIProviderProfile, isNew: Bool) {
        self.settings = settings
        self.providerID = provider.id
        self.isNew = isNew
        _name = State(initialValue: provider.name)
        _draft = State(initialValue: provider.configuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: draft.service.cardSymbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? "新增提供商" : "提供商详情")
                        .font(.title2.weight(.semibold))
                    Text(isNew ? "添加独立的 AI 服务配置" : name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("名称", systemImage: "tag")
                            .font(.system(.subheadline, weight: .medium))
                        TextField("提供商名称", text: $name, prompt: Text("例如：工作用 AI"))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ai.providerName")
                    }

                    if isNew {
                        Picker("服务类型", selection: $draft.service) {
                            ForEach(TerminalAIService.allCases) { service in
                                Text(service.title).tag(service)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Label("Base URL", systemImage: "globe")
                            .font(.system(.subheadline, weight: .medium))
                        TextField("Base URL", text: $draft.baseURL, prompt: Text("https://api.example.com/v1"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                            .accessibilityLabel("\(name) Base URL")
                        Text("填写 API 根地址及路径（如 /v1），不包含 /models 或 /chat/completions。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    apiKeyField
                    modelField

                    if let modelMessage {
                        Label(modelMessage.text, systemImage: modelMessage.style == .success ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(modelMessage.style == .success ? Color.green : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isFetchingModels)
            }

            Divider()

            HStack {
                Text("保存后将启用此提供商")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "添加并启用" : "保存配置", action: saveConfiguration)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isFetchingModels || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (try? draft.validated()) == nil)
            }
            .padding(20)
        }
        .frame(width: 620, height: 650)
        .onAppear(perform: resetEndpointState)
        .onChange(of: draft.service) { oldService, service in
            if name.isEmpty || name == oldService.cardTitle { name = service.cardTitle }
            draft.baseURL = service.defaultBaseURL
            draft.model = ""
            resetEndpointState()
        }
        .onChange(of: draft.baseURL) { _, _ in resetEndpointState() }
        .onDisappear { modelFetchTask?.cancel() }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("API Key", systemImage: "key")
                    .font(.system(.subheadline, weight: .medium))
                Spacer()
                if hasSavedKey {
                    if apiKeyDraft.isEmpty {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button("移除", action: removeKey)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            SecureField("API Key", text: $apiKeyDraft, prompt: Text(hasSavedKey ? "输入新 Key 可替换" : "API Key（本地服务可留空）"))
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(name) API Key")
            Text("按服务地址保存在本机 macOS 钥匙串，同一地址共用密钥。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("模型", systemImage: "cpu")
                .font(.system(.subheadline, weight: .medium))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    modelPicker
                    fetchModelsButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    modelPicker
                    fetchModelsButton
                }
            }
            TextField("模型 ID", text: $draft.model, prompt: Text("也可手动填写模型 ID"))
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .accessibilityLabel("模型 ID")
            Text("从当前服务获取后选择；不支持模型列表时可手动填写 ID。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelPicker: some View {
        Picker("模型", selection: $draft.model) {
            Text("请选择模型").tag("")
            if !draft.model.isEmpty && !models.contains(draft.model) {
                Text(draft.model).tag(draft.model)
            }
            ForEach(models, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 160, idealWidth: 220, maxWidth: .infinity)
    }

    private var fetchModelsButton: some View {
        Button {
            modelFetchTask = Task { await fetchModels() }
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
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isFetchingModels || (try? TerminalAIConfiguration.normalizedBaseURL(draft.baseURL)) == nil)
    }

    private func resetEndpointState() {
        apiKeyDraft = ""
        models = []
        modelMessage = nil
        hasSavedKey = (try? settings.apiKey(for: draft.baseURL))?.isEmpty == false
    }

    private func saveConfiguration() {
        guard !isFetchingModels else { return }
        do {
            try settings.saveProvider(
                TerminalAIProviderProfile(id: providerID, name: name, configuration: draft),
                apiKeyDraft: apiKeyDraft
            )
            dismiss()
        } catch {
            modelMessage = ModelMessage(text: error.localizedDescription, style: .error)
        }
    }

    private func removeKey() {
        do {
            try settings.removeAPIKey(for: draft.baseURL)
            apiKeyDraft = ""
            hasSavedKey = false
            modelMessage = ModelMessage(text: "已移除当前服务地址的 API Key。", style: .success)
        } catch {
            modelMessage = ModelMessage(text: error.localizedDescription, style: .error)
        }
    }

    @MainActor
    private func fetchModels() async {
        guard !isFetchingModels else { return }
        modelMessage = nil
        isFetchingModels = true
        defer { isFetchingModels = false }

        do {
            let enteredKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = try enteredKey.isEmpty ? settings.apiKey(for: draft.baseURL) : enteredKey
            let fetchedModels = try await TerminalAIModelService().fetchModels(baseURL: draft.baseURL, apiKey: key)
            try Task.checkCancellation()
            models = fetchedModels
            modelMessage = fetchedModels.isEmpty
                ? ModelMessage(text: "当前服务没有返回可用模型，可手动填写模型 ID。", style: .error)
                : ModelMessage(text: "已获取 \(fetchedModels.count) 个模型，请选择模型后保存。", style: .success)
        } catch {
            guard !Task.isCancelled else { return }
            modelMessage = ModelMessage(text: error.localizedDescription, style: .error)
        }
    }
}

private extension TerminalAIService {
    var cardTitle: String { self == .custom ? "自定义" : title }

    var cardDescription: String {
        switch self {
        case .deepSeek: "DeepSeek 官方服务"
        case .openAI: "OpenAI 官方服务"
        case .siliconFlow: "多模型 API 服务"
        case .openRouter: "统一模型接入服务"
        case .ollama: "本地模型服务"
        case .custom: "OpenAI 兼容服务"
        }
    }

    var cardSymbol: String {
        switch self {
        case .deepSeek: "sparkles"
        case .openAI: "cpu"
        case .siliconFlow: "square.stack.3d.up"
        case .openRouter: "arrow.triangle.branch"
        case .ollama: "desktopcomputer"
        case .custom: "server.rack"
        }
    }
}

private struct ModelMessage {
    enum Style { case success, error }
    let text: String
    let style: Style
}
