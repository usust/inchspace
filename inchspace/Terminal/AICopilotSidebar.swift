import AppKit
import SwiftUI

struct AICopilotSidebar: View {
    @ObservedObject var controller: TerminalAICopilotController
    @ObservedObject var conversation: TerminalAIConversation
    @ObservedObject var settings: TerminalAISettings
    let session: TerminalSession
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(controller: TerminalAICopilotController, session: TerminalSession) {
        self.controller = controller
        self.session = session
        let conversation = controller.conversation(for: session.id)
        self.conversation = conversation
        self.settings = controller.settings
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            conversationContent
            Divider().opacity(0.45)
            composer
        }
        .frame(minWidth: 320, idealWidth: settings.sidebarWidth, maxWidth: 520)
        .background(.regularMaterial)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            guard width >= 320, width <= 520, abs(settings.sidebarWidth - width) > 1 else { return }
            settings.sidebarWidth = width
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("AI Copilot", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            if controller.permission(for: session.id) != .askEveryTime {
                Menu {
                    permissionPicker
                } label: {
                    Label(controller.permission(for: session.id) == .autoApproveSession ? "Auto Run" : "Auto", systemImage: "bolt.fill")
                        .font(.caption.weight(.medium))
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("命令授权模式")
            }
            Button { conversation.newChat() } label: { Image(systemName: "plus") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("新对话")
                .accessibilityLabel("新对话")
            Button {
                controller.isSidebarVisible = false
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("关闭 AI Copilot")
                .accessibilityLabel("关闭 AI Copilot")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var conversationContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if conversation.messages.isEmpty { emptyState }
                    ForEach(conversation.messages) { message in
                        AIMessageView(message: message, controller: controller, conversation: conversation, session: session)
                            .id(message.id)
                    }
                    if let error = conversation.errorMessage {
                        errorView(error)
                    }
                }
                .padding(16)
            }
            .onChange(of: conversation.messages.last?.content) { _, _ in
                if let id = conversation.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Terminal Assistant").font(.headline)
                Text("询问当前终端、解释错误或生成命令")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                suggestion("解释最近的错误")
                suggestion("检查当前环境")
                suggestion("帮我生成命令")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private func suggestion(_ title: String) -> some View {
        Button(title) { draft = title; submit() }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !settings.hasAPIKey {
                Button("打开 AI 设置") {
                    NotificationCenter.default.post(name: .inchspaceOpenSettings, object: nil)
                }
                .buttonStyle(.glass)
            } else {
                Button("重试") {
                    Task { await controller.retry(sessionID: session.id) }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                contextChip
                if let selection = conversation.attachedSelection {
                    Label("选择内容 · \(max(1, selection.split(separator: "\n").count)) 行", systemImage: "text.quote")
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                        .overlay(alignment: .trailing) {
                            Button { conversation.attachedSelection = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).offset(x: 7)
                                .accessibilityLabel("移除选择内容")
                        }
                        .padding(.trailing, 7)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask AI…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .return else { return .ignored }
                        if press.modifiers.contains(.shift) { draft.append("\n") }
                        else { submit() }
                        return .handled
                    }
                    .accessibilityLabel("询问 AI")
                if conversation.isStreaming || conversation.commandStates.values.contains(.running) {
                    Button { controller.stop(sessionID: session.id) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                        .keyboardShortcut(.escape, modifiers: [])
                        .help("停止生成")
                } else {
                    Button { submit() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("发送")
                }
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
        .padding(12)
    }

    private var contextChip: some View {
        Button { settings.terminalContextEnabled.toggle() } label: {
            Label(session.kind.isRemote ? remoteLabel : "Terminal", systemImage: session.kind.symbol)
                .font(.caption)
                .foregroundStyle(settings.terminalContextEnabled ? .primary : .secondary)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .help(settings.terminalContextEnabled ? "Terminal Context 已开启" : "Terminal Context 已关闭")
    }

    private var remoteLabel: String {
        if case .ssh(_, let endpoint) = session.kind { return "SSH · \(endpoint)" }
        return "SSH"
    }

    @ViewBuilder private var permissionPicker: some View {
        ForEach(TerminalAICommandPermission.allCases) { mode in
            Button {
                controller.setPermission(mode, sessionID: session.id)
            } label: {
                if controller.permission(for: session.id) == mode { Label(mode.title, systemImage: "checkmark") }
                else { Text(mode.title) }
            }
        }
    }

    private func submit() {
        let question = draft
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await controller.send(question, sessionID: session.id) }
    }
}

private struct AIMessageView: View {
    let message: TerminalAIMessage
    @ObservedObject var controller: TerminalAICopilotController
    @ObservedObject var conversation: TerminalAIConversation
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role == .user ? "You" : "AI")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if message.role == .user {
                Text(message.content).textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if message.content.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                ForEach(TerminalAIMarkdownBlock.parse(message.content)) { block in
                    switch block {
                    case .markdown(_, let text): markdown(text)
                    case .command(_, let command): AICommandCard(command: command, sessionID: session.id, controller: controller, conversation: conversation)
                    case .code(_, let language, let code): codeBlock(language: language, code: code)
                    }
                }
            }
            if message.isInterrupted {
                Label("Response interrupted", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markdown(_ value: String) -> some View {
        let attributed = (try? AttributedString(markdown: value)) ?? AttributedString(value)
        return Text(attributed).font(.callout).textSelection(.enabled)
    }

    private func codeBlock(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !language.isEmpty { Text(language.uppercased()).font(.caption2).foregroundStyle(.secondary) }
            Text(code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AICommandCard: View {
    let command: String
    let sessionID: UUID
    @ObservedObject var controller: TerminalAICopilotController
    @ObservedObject var conversation: TerminalAIConversation

    private var state: TerminalAICommandState { conversation.commandStates[command] ?? .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Terminal Command", systemImage: "terminal")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                status
            }
            Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if state == .awaitingApproval {
                VStack(alignment: .leading, spacing: 8) {
                    Label(TerminalAICommandPolicy.isHighRisk(command) ? "这是高风险命令，请确认后运行" : "AI 请求运行此命令", systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(TerminalAICommandPolicy.isHighRisk(command) ? .orange : .secondary)
                    HStack {
                        Button("取消") { controller.cancelRun(command, sessionID: sessionID) }
                        Spacer()
                        Button("运行命令") { controller.runApproved(command, sessionID: sessionID) }
                            .buttonStyle(.glassProminent)
                    }
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 10) {
                    Button("复制", systemImage: "doc.on.doc") { copy() }
                    Button("插入", systemImage: "arrow.turn.down.right") { controller.insert(command, sessionID: sessionID) }
                    Spacer()
                    Button("运行", systemImage: "play.fill") { controller.requestRun(command, sessionID: sessionID) }
                        .disabled(state == .running)
                }
                .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.35))
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .idle, .awaitingApproval: EmptyView()
        case .running: Label("Running…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        case .finished(let code): Label("Exit \(code)", systemImage: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill").font(.caption).foregroundStyle(code == 0 ? .green : .red)
        case .failed(let message): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).help(message)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
