import AppKit
import SwiftUI

struct ServerEditorView: View {
    enum Step: Int, CaseIterable {
        case basic
        case authentication
        case advanced

        var title: String {
            switch self {
            case .basic: "基础信息"
            case .authentication: "认证"
            case .advanced: "高级配置"
            }
        }

        var symbol: String {
            switch self {
            case .basic: "server.rack"
            case .authentication: "key.horizontal"
            case .advanced: "slider.horizontal.3"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ServerManager
    let originalServer: Server?
    let onSave: (Server) -> Void

    @State private var step: Step = .basic
    @State private var server: Server
    @State private var credential: SSHCredential
    @State private var password = ""
    @State private var tagText = ""
    @State private var errorMessage: String?

    init(manager: ServerManager, server: Server?, onSave: @escaping (Server) -> Void) {
        self.manager = manager
        originalServer = server
        self.onSave = onSave
        let credentialID = server?.credentialID ?? UUID()
        _server = State(initialValue: server ?? Server(name: "", host: "", user: "", credentialID: credentialID))
        _credential = State(initialValue: server.flatMap(manager.credential) ?? SSHCredential(id: credentialID, serverID: server?.id ?? UUID(), authentication: .sshKey))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                stepSidebar
                Divider().opacity(0.45)
                formContent
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 720, height: 570)
        .background(.regularMaterial)
        .onAppear { credential.serverID = server.id }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(originalServer == nil ? "添加服务器" : "编辑服务器").font(.title2.weight(.bold))
                Text("配置 SSH 主机资产与连接方式").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(22)
    }

    private var stepSidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Button {
                    if canMove(to: item) { withAnimation(.snappy(duration: 0.2)) { step = item } }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).frame(width: 19)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline.weight(.medium))
                            Text("步骤 \(item.rawValue + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 48)
                    .background(step == item ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(step == item ? Color.accentColor : Color.primary)
            }
            Spacer()
        }
        .padding(14)
        .frame(width: 170)
        .background(.ultraThinMaterial.opacity(0.6))
    }

    @ViewBuilder
    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch step {
                case .basic: basicForm
                case .authentication: authenticationForm
                case .advanced: advancedForm
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var basicForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            editorTitle("基础信息", detail: "用于识别和连接这台远程服务器。")
            field("名称") { TextField("例如：Ubuntu Server", text: $server.name) }
            field("服务器地址") { TextField("IP 地址或域名", text: $server.host) }
            HStack(spacing: 14) {
                field("用户名") { TextField("root", text: $server.user) }
                field("端口") { TextField("22", value: $server.port, format: .number).frame(width: 90) }
            }
            Label("系统将在首次连接检测后自动识别", systemImage: "sparkle.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var authenticationForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            editorTitle("认证方式", detail: "密码安全存入 macOS 钥匙串，私钥仅保存访问授权。")
            Picker("认证方式", selection: $credential.authentication) {
                ForEach(ServerAuthentication.allCases) { method in
                    Label(method.title, systemImage: method.symbol).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: credential.authentication) { _, _ in errorMessage = nil }

            Group {
                switch credential.authentication {
                case .sshKey:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SSH 私钥").font(.subheadline.weight(.medium))
                        HStack {
                            Image(systemName: "key.horizontal").foregroundStyle(Color.accentColor)
                            Text(credential.keyPath.isEmpty ? "尚未选择私钥" : URL(fileURLWithPath: credential.keyPath).lastPathComponent)
                                .foregroundStyle(credential.keyPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer()
                            Button("选择…", action: selectKey)
                        }
                        .padding(12)
                        .serverGlassCard(cornerRadius: 12)
                    }
                case .password:
                    field("密码") {
                        SecureField(originalServer == nil ? "服务器登录密码" : "留空以保留当前密码", text: $password)
                    }
                case .agent:
                    Label("连接时使用当前用户的 ssh-agent 和已加载密钥。", systemImage: "checkmark.shield")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(14)
                        .serverGlassCard(cornerRadius: 12)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    private var advancedForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            editorTitle("高级配置", detail: "按网络环境补充组织、连接策略与备注。")
            Picker("服务器分组", selection: $server.groupID) {
                Text("未分组").tag(UUID?.none)
                ForEach(manager.groups) { group in Text(group.name).tag(Optional(group.id)) }
            }
            Picker("跳板机", selection: $server.jumpHostID) {
                Text("不使用").tag(UUID?.none)
                ForEach(manager.servers.filter { $0.id != server.id }) { item in Text(item.name).tag(Optional(item.id)) }
            }
            HStack(spacing: 14) {
                field("连接超时（秒）") { TextField("8", value: $server.connectionTimeout, format: .number) }
                field("Keep Alive（秒）") { TextField("60", value: $server.keepAliveInterval, format: .number) }
            }
            field("标签") {
                TextField("Linux, Docker, 生产", text: $tagText)
                    .onAppear { tagText = manager.tags(for: server).map(\.name).joined(separator: ", ") }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("备注").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $server.notes)
                    .font(.body)
                    .frame(minHeight: 78)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("取消") { dismiss() }
            Spacer()
            if step.rawValue > 0 {
                Button("上一步") { withAnimation(.snappy(duration: 0.2)) { step = Step(rawValue: step.rawValue - 1)! } }
            }
            if step != .advanced {
                Button("下一步") {
                    guard validateCurrentStep() else { return }
                    withAnimation(.snappy(duration: 0.2)) { step = Step(rawValue: step.rawValue + 1)! }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(originalServer == nil ? "添加服务器" : "存储更改", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 62)
    }

    private func editorTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func canMove(to target: Step) -> Bool {
        if target.rawValue <= step.rawValue { return true }
        return validateCurrentStep()
    }

    private func validateCurrentStep() -> Bool {
        errorMessage = nil
        switch step {
        case .basic:
            guard !server.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  !server.host.trimmingCharacters(in: .whitespaces).isEmpty,
                  !server.user.trimmingCharacters(in: .whitespaces).isEmpty,
                  (1...65535).contains(server.port) else {
                errorMessage = "请填写名称、地址、用户名和有效端口。"
                return false
            }
        case .authentication:
            if credential.authentication == .sshKey && credential.keyPath.isEmpty {
                errorMessage = "请选择用于登录的 SSH 私钥。"
                return false
            }
            if credential.authentication == .password && password.isEmpty && originalServer == nil {
                errorMessage = "请输入服务器登录密码。"
                return false
            }
        case .advanced:
            guard (1...120).contains(server.connectionTimeout), (0...3600).contains(server.keepAliveInterval) else {
                errorMessage = "连接超时应为 1–120 秒，Keep Alive 应为 0–3600 秒。"
                return false
            }
        }
        return true
    }

    private func selectKey() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                credential.keyPath = url.path
                credential.keyBookmark = try SecurityScopedBookmarkService.makeBookmark(for: url)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func save() {
        guard validateAllSteps() else { return }
        server.updatedAt = Date()
        credential.serverID = server.id
        let names = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        server.tagIDs = names.compactMap { manager.tag(named: $0)?.id }
        if originalServer == nil {
            manager.add(server, credential: credential, password: password.isEmpty ? nil : password)
        } else {
            manager.update(server, credential: credential, password: password.isEmpty ? nil : password)
        }
        onSave(server)
        dismiss()
    }

    private func validateAllSteps() -> Bool {
        let current = step
        for item in Step.allCases {
            step = item
            if !validateCurrentStep() { return false }
        }
        step = current
        return true
    }
}
