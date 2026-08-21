import Combine
import SwiftUI

struct TerminalView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var serverManager: ServerManager
    @ObservedObject private var copilot: TerminalAICopilotController
    @State private var pendingClose: TerminalSession?

    init(manager: TerminalManager, serverManager: ServerManager) {
        self.manager = manager
        self.serverManager = serverManager
        self.copilot = manager.aiCopilot
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                HSplitView {
                    VStack(spacing: 0) {
                        if !manager.sessions.isEmpty {
                            TerminalTabBar(manager: manager, requestClose: requestClose)
                        }
                        Group {
                            if let session = manager.selectedSession {
                                terminalWorkspace(primary: session)
                            } else {
                                emptyState
                            }
                        }
                    }
                    .frame(minWidth: 360)

                    if copilot.isSidebarVisible, let session = manager.selectedSession {
                        AICopilotSidebar(controller: copilot, session: session)
                            .id(session.id)
                    }
                }
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    if width < 720, copilot.isSidebarVisible {
                        copilot.isSidebarVisible = false
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { manager.applyPreferences() }
        .onReceive(manager.preferences.objectWillChange) { _ in
            DispatchQueue.main.async { manager.applyPreferences() }
        }
        .alert("此终端中仍有进程正在运行。", isPresented: Binding(
            get: { pendingClose != nil },
            set: { if !$0 { pendingClose = nil } }
        )) {
            Button("取消", role: .cancel) { pendingClose = nil }
            Button("关闭终端", role: .destructive) {
                if let pendingClose { manager.close(pendingClose) }
                pendingClose = nil
            }
        } message: {
            Text("关闭后，该终端中的前台进程也会结束。")
        }
        .background(shortcutButtons)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AppLayout.featureHeaderSpacing) {
            AppFeatureTitle("终端", subtitle: "本机与远程 Shell")
            Spacer(minLength: 24)

            HStack(spacing: 8) {
                Button {
                    copilot.isSidebarVisible.toggle()
                } label: {
                    toolbarSymbol("sparkles")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("打开或关闭 AI Copilot（⌘⇧A）")
                .disabled(manager.selectedSession == nil)
                .accessibilityLabel("AI Copilot")

                Button {
                    manager.selectedSession?.showSearch()
                } label: {
                    toolbarSymbol("magnifyingglass")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("搜索终端历史（⌘F）")
                .disabled(manager.selectedSession == nil)

                Menu {
                    Button("左右分屏", systemImage: "rectangle.split.2x1") { manager.split(.vertical) }
                    Button("上下分屏", systemImage: "rectangle.split.1x2") { manager.split(.horizontal) }
                    if let session = manager.selectedSession, session.panes.count > 1 {
                        Divider()
                        Button("关闭当前 Pane", systemImage: "xmark.rectangle") { closeActivePane() }
                    }
                } label: {
                    toolbarSymbol("rectangle.split.2x1")
                } primaryAction: {
                    manager.split(.vertical)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("左右分屏；展开可选择上下分屏")
                .disabled(manager.selectedSession == nil)

                newTerminalMenu
            }
            .controlSize(.regular)
        }
        .appFeatureHeaderBackground(opacity: 0.62)
        .background(TerminalWindowDragRegion())
    }

    private func toolbarSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .frame(width: 18, height: 18)
    }

    private var newTerminalMenu: some View {
        Menu {
            Button("新建本地终端", systemImage: "laptopcomputer") {
                manager.openLocalSession()
            }
            if !recentServers.isEmpty {
                Divider()
                Section("最近连接") {
                    ForEach(recentServers) { server in
                        Button(server.name, systemImage: "server.rack") { open(server) }
                    }
                }
            }
            if !serverManager.servers.isEmpty {
                Divider()
                Section("选择服务器") {
                    ForEach(serverManager.servers) { server in
                        Button(server.name, systemImage: "server.rack") { open(server) }
                    }
                }
            }
        } label: {
            Label("新建终端", systemImage: "plus")
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .help("新建终端（⌘T）")
    }

    private func terminalWorkspace(primary session: TerminalSession) -> some View {
        TerminalWorkspaceView(session: session, closeActivePane: closeActivePane)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 42, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 6) {
                Text("终端").font(.title2.weight(.semibold))
                Text("运行本地命令或连接远程服务器")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("新建本地终端", systemImage: "plus") {
                manager.openLocalSession()
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)

            if !recentServers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近连接")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(recentServers.prefix(3)) { server in
                        Button { open(server) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "server.rack").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name).font(.subheadline.weight(.medium))
                                    Text(server.host).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .frame(width: 280, height: 48)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recentServers: [Server] {
        var seen = Set<UUID>()
        return serverManager.history
            .sorted { $0.connectedAt > $1.connectedAt }
            .compactMap { history -> Server? in
                guard seen.insert(history.serverID).inserted else { return nil }
                return serverManager.servers.first { $0.id == history.serverID }
            }
    }

    private func open(_ server: Server) {
        serverManager.connect(to: server)
    }

    private func requestClose(_ session: TerminalSession) {
        if manager.preferences.confirmBeforeClosing && session.isRunning {
            pendingClose = session
        } else {
            manager.close(session)
        }
    }

    private func closeActivePane() {
        guard let session = manager.selectedSession else { return }
        if session.panes.count > 1 {
            _ = session.closePane(session.activePaneID)
        } else {
            requestClose(session)
        }
    }

    private var shortcutButtons: some View {
        Group {
            Button("") { manager.openLocalSession() }.keyboardShortcut("t", modifiers: .command)
            Button("") {
                closeActivePane()
            }.keyboardShortcut("w", modifiers: .command)
            Button("") { manager.split(.vertical) }.keyboardShortcut("d", modifiers: .command)
            Button("") { manager.split(.horizontal) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("") { manager.selectedSession?.clearScrollback() }.keyboardShortcut("k", modifiers: .command)
            Button("") { manager.selectedSession?.showSearch() }.keyboardShortcut("f", modifiers: .command)
            Button("") { manager.selectedSession?.increaseFontSize() }.keyboardShortcut("+", modifiers: .command)
            Button("") { manager.selectedSession?.decreaseFontSize() }.keyboardShortcut("-", modifiers: .command)
            Button("") { manager.selectedSession?.resetFontSize() }.keyboardShortcut("0", modifiers: .command)
            Button("") {
                copilot.isSidebarVisible.toggle()
            }.keyboardShortcut("a", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

private struct TerminalWorkspaceView: View {
    @ObservedObject var session: TerminalSession
    let closeActivePane: () -> Void

    var body: some View {
        if let maximizedID = session.maximizedPaneID, let maximized = session.pane(id: maximizedID) {
            pane(maximized)
        } else {
            paneLayout(session.paneLayout)
        }
    }

    private func paneLayout(_ layout: TerminalPaneLayout) -> AnyView {
        switch layout {
        case .pane(let id):
            guard let terminalPane = session.pane(id: id) else { return AnyView(EmptyView()) }
            return AnyView(pane(terminalPane))
        case .split(.vertical, let first, let second):
            return AnyView(HSplitView {
                paneLayout(first)
                paneLayout(second)
            }
            .background(.ultraThinMaterial))
        case .split(.horizontal, let first, let second):
            return AnyView(VSplitView {
                paneLayout(first)
                paneLayout(second)
            }
            .background(.ultraThinMaterial))
        }
    }

    private func pane(_ terminalPane: TerminalPane) -> some View {
        let isActive = session.activePaneID == terminalPane.id
        return ZStack(alignment: .topTrailing) {
            TerminalCanvas(pane: terminalPane)
                .id(terminalPane.id)
                .ignoresSafeArea(.container, edges: [])
            if terminalPane.connectionState == .error || terminalPane.connectionState == .disconnected {
                disconnectedControl(terminalPane)
                    .padding(12)
            }
        }
        .frame(minWidth: 260, minHeight: 180)
        .opacity(isActive ? 1 : 0.94)
        .overlay {
            Rectangle()
                .strokeBorder(Color.accentColor.opacity(isActive && session.panes.count > 1 ? 0.22 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("新建垂直分屏", systemImage: "rectangle.split.2x1") {
                session.activate(terminalPane)
                session.split(.vertical)
            }
            Button("新建水平分屏", systemImage: "rectangle.split.1x2") {
                session.activate(terminalPane)
                session.split(.horizontal)
            }
            Divider()
            Button(session.maximizedPaneID == terminalPane.id ? "还原 Pane" : "最大化当前 Pane", systemImage: "arrow.up.left.and.arrow.down.right") {
                session.toggleMaximize(terminalPane.id)
            }
            Button("关闭当前 Pane", systemImage: "xmark.rectangle", role: .destructive) {
                session.activate(terminalPane)
                closeActivePane()
            }
        }
    }

    private func disconnectedControl(_ pane: TerminalPane) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(pane.connectionState == .error ? Color(nsColor: .systemRed) : Color.secondary)
                .frame(width: 7, height: 7)
            Text(pane.lastError ?? pane.connectionState.title)
                .font(.caption)
                .lineLimit(1)
            if session.kind.isRemote {
                Button("重新连接") { pane.reconnect() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.10)) }
    }
}
