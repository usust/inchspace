import AppKit
import SwiftUI

struct AICopilotSidebar: View {
    @ObservedObject var controller: TerminalAICopilotController
    @ObservedObject var conversation: TerminalAIConversation
    @ObservedObject var settings: TerminalAISettings
    let session: TerminalSession
    @State private var draft = ""
    @State private var followsLatest = true
    @State private var isUserScrolling = false
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(controller: TerminalAICopilotController, session: TerminalSession) {
        self.controller = controller
        self.session = session
        self.conversation = controller.conversation(for: session.id)
        self.settings = controller.settings
    }

    private var isBusy: Bool {
        conversation.isStreaming || conversation.commandStates.values.contains(.running)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            conversationContent
            composer
        }
        .frame(minWidth: 320, idealWidth: settings.sidebarWidth, maxWidth: 520)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { Rectangle().fill(.regularMaterial) }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            guard width >= 320, width <= 520, abs(settings.sidebarWidth - width) > 1 else { return }
            settings.sidebarWidth = width
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIconTile(symbol: "sparkles", size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI 助手").font(.headline)
                    Text(conversation.isStreaming ? "正在整理回答…" : "与你一起处理终端任务")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    conversation.newChat()
                    followsLatest = true
                    composerFocused = true
                } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("新对话")
                    .accessibilityLabel("新对话")
                Button {
                    controller.isSidebarVisible = false
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("关闭 AI 助手")
                    .accessibilityLabel("关闭 AI 助手")
            }
            HStack(spacing: 8) {
                Label(session.kind.isRemote ? remoteLabel : "本地终端", systemImage: session.kind.symbol)
                    .lineLimit(1).truncationMode(.middle)
                    .help(session.kind.isRemote ? remoteLabel : "当前本地终端会话")
                Spacer(minLength: 0)
                Menu { permissionPicker } label: {
                    Label(controller.permission(for: session.id).title, systemImage: "checkmark.shield")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("命令授权模式")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var conversationContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if conversation.messages.isEmpty { emptyState }
                    ForEach(conversation.messages) { message in
                        AIMessageView(message: message, controller: controller, conversation: conversation, session: session)
                            .id(message.id)
                    }
                    if let error = conversation.errorMessage { errorView(error) }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .padding(.bottom, followsLatest ? 0 : 40)
            }
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 64
            } action: { _, atBottom in
                if isUserScrolling { followsLatest = atBottom }
            }
            .onChange(of: conversation.messages.last?.content) { _, _ in
                if followsLatest { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.messages.count) { _, _ in
                if conversation.messages.last?.role == .user { followsLatest = true }
                if followsLatest { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !followsLatest {
                    Button("回到最新消息", systemImage: "arrow.down") {
                        followsLatest = true
                        withAnimation(reduceMotion ? nil : AppMotion.feedback) {
                            proxy.scrollTo("conversation-bottom", anchor: .bottom)
                        }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .padding(.bottom, 8)
                }
            }
            .onAppear { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("下一步，一起完成")
                    .font(.system(size: 22, weight: .semibold))
                Text("解释输出、排查错误，或把你的想法变成命令。运行前，你可以先审阅。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                suggestion("解释最近的错误", detail: "理解输出，找到排查方向", symbol: "text.magnifyingglass")
                suggestion("检查当前环境", detail: "确认路径、版本与依赖", symbol: "slider.horizontal.3")
                suggestion("帮我生成命令", detail: "描述目标，审阅后再运行", symbol: "terminal")
            }
        }
        .padding(.vertical, 16)
    }

    private func suggestion(_ title: String, detail: String, symbol: String) -> some View {
        Button {
            draft = title
            composerFocused = true
        } label: {
            HStack(spacing: 10) {
                AppIconTile(symbol: symbol, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface()
        }
        .buttonStyle(AppCardButtonStyle())
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("需要处理后再继续", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("打开 AI 设置") {
                    NotificationCenter.default.post(name: .inchspaceOpenSettings, object: nil, userInfo: ["tab": SettingsTab.ai.rawValue])
                }
                if !settings.model.isEmpty {
                    Button("重试") { Task { await controller.retry(sessionID: session.id) } }
                        .disabled(isBusy)
                }
            }
            .buttonStyle(.glass).controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface()
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                contextChip
                if let selection = conversation.attachedSelection {
                    HStack(spacing: 6) {
                        Label("已附加选区 · \(max(1, selection.split(separator: "\n").count)) 行", systemImage: "text.quote")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button { conversation.attachedSelection = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("移除选择内容")
                    }
                    .font(.caption)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            TextField("描述你想完成的事…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(2...6)
                .focused($composerFocused)
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return else { return .ignored }
                    if press.modifiers.contains(.shift) { draft.append("\n") }
                    else { submit() }
                    return .handled
                }
                .accessibilityLabel("询问 AI")
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.model.isEmpty ? "尚未选择模型" : settings.model)
                        .lineLimit(1).truncationMode(.middle)
                        .help(settings.model.isEmpty ? "在 AI 设置中选择模型" : settings.model)
                    Text("↵ 发送 · ⇧↵ 换行").foregroundStyle(.tertiary)
                }
                .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isBusy {
                    Button { controller.stop(sessionID: session.id) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                        .keyboardShortcut(.escape, modifiers: [])
                        .help("停止生成或运行")
                        .accessibilityLabel("停止生成或运行")
                } else {
                    Button { submit() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("发送")
                        .accessibilityLabel("发送消息")
                }
            }
        }
        .padding(14)
        .appSurface()
        .overlay {
            RoundedRectangle(cornerRadius: AppLayout.cardRadius)
                .strokeBorder(Color.accentColor.opacity(composerFocused ? 0.6 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : AppMotion.feedback, value: composerFocused)
        .animation(reduceMotion ? nil : AppMotion.transition, value: conversation.attachedSelection != nil)
        .padding(12)
    }

    private var contextChip: some View {
        Button { settings.terminalContextEnabled.toggle() } label: {
            Label(settings.terminalContextEnabled ? "终端上下文已开启" : "终端上下文已关闭",
                  systemImage: settings.terminalContextEnabled ? "terminal.fill" : "terminal")
                .font(.caption)
                .foregroundStyle(settings.terminalContextEnabled ? Color.accentColor : .secondary)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityValue(settings.terminalContextEnabled ? "已开启" : "已关闭")
        .help("开启后，发送消息时会附带当前终端的上下文")
    }

    private var remoteLabel: String {
        if case .ssh(_, let endpoint) = session.kind { return "SSH · \(endpoint)" }
        return "SSH"
    }

    @ViewBuilder private var permissionPicker: some View {
        ForEach(TerminalAICommandPermission.allCases) { mode in
            Button { controller.setPermission(mode, sessionID: session.id) } label: {
                if controller.permission(for: session.id) == mode { Label(mode.title, systemImage: "checkmark") }
                else { Text(mode.title) }
            }
        }
    }

    private func submit() {
        let question = draft
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isBusy else { return }
        draft = ""
        followsLatest = true
        Task { await controller.send(question, sessionID: session.id) }
    }
}

private struct AIMessageView: View {
    let message: TerminalAIMessage
    @ObservedObject var controller: TerminalAICopilotController
    @ObservedObject var conversation: TerminalAIConversation
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message.role == .user ? "你" : "AI 助手", systemImage: message.role == .user ? "person.crop.circle" : "sparkles")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if message.role == .user {
                Text(message.content).font(.callout).textSelection(.enabled)
            } else if message.content.isEmpty {
                HStack(spacing: 8) {
                    if conversation.isStreaming && conversation.messages.last?.id == message.id && !message.isInterrupted {
                        ProgressView().controlSize(.small)
                        Text("正在思考…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(message.isInterrupted ? "已停止生成" : "未收到回答")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
                Label("回答已中断", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface()
        .overlay(alignment: .leading) {
            if message.role == .user {
                Capsule().fill(Color.accentColor.opacity(0.65))
                    .frame(width: 3, height: 22).padding(.leading, 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private func markdown(_ value: String) -> some View {
        let attributed = (try? AttributedString(markdown: value)) ?? AttributedString(value)
        return Text(attributed).font(.callout).lineSpacing(3).textSelection(.enabled)
    }

    private func codeBlock(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !language.isEmpty { Text(language).font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
                Text(code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AICommandCard: View {
    let command: String
    let sessionID: UUID
    @ObservedObject var controller: TerminalAICopilotController
    @ObservedObject var conversation: TerminalAIConversation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    private var state: TerminalAICommandState { conversation.commandStates[command] ?? .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("终端命令", systemImage: "terminal")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                status
            }
            Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if state == .awaitingApproval {
                VStack(alignment: .leading, spacing: 10) {
                    Label(TerminalAICommandPolicy.isHighRisk(command) ? "这是高风险命令，请确认后运行" : "AI 请求运行此命令", systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(TerminalAICommandPolicy.isHighRisk(command) ? .orange : .secondary)
                    HStack {
                        Button("取消") { controller.cancelRun(command, sessionID: sessionID) }
                        Spacer()
                        Button("运行命令") { controller.runApproved(command, sessionID: sessionID) }
                            .buttonStyle(.glassProminent)
                    }
                }
                .transition(.opacity)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        secondaryActions
                        Spacer(minLength: 4)
                        runButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) { secondaryActions }
                        runButton
                    }
                }
            }
            if case .failed(let message) = state {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .controlSize(.small)
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5))
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : AppMotion.transition, value: state)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }

    private var secondaryActions: some View {
        Group {
            Button(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc") { copy() }
            Button("插入", systemImage: "arrow.turn.down.right") { controller.insert(command, sessionID: sessionID) }
        }
        .buttonStyle(.bordered)
    }

    private var runButton: some View {
        Button("运行", systemImage: "play.fill") { controller.requestRun(command, sessionID: sessionID) }
            .buttonStyle(.glass)
            .disabled(state == .running)
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .idle: EmptyView()
        case .awaitingApproval: Label("待确认", systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
        case .running: Label("运行中", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        case .finished(let code): Label("退出码 \(code)", systemImage: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill").font(.caption).foregroundStyle(code == 0 ? .green : .red)
        case .failed: Label("未完成", systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(command, forType: .string)
    }
}
