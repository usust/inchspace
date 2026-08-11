import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ServerDashboardView: View {
    @ObservedObject var manager: ServerManager

    @State private var scope: ServerScope = .all
    @State private var selectedServerID: UUID?
    @State private var showsEditor = false
    @State private var editingServer: Server?
    @State private var showsQuickConnect = false
    @State private var showsSSHImporter = false
    @State private var groupPrompt: DashboardGroupPrompt?
    @State private var pendingServerDeletion: Server?
    @State private var pendingGroupDeletion: ServerGroup?

    var body: some View {
        ZStack {
            DashboardBackground()

            VStack(spacing: 0) {
                toolbar

                if manager.servers.isEmpty {
                    emptyState
                } else if let selectedServer {
                    ServerDetailPanel(
                        server: selectedServer,
                        credential: manager.credential(for: selectedServer),
                        group: manager.group(for: selectedServer),
                        tags: manager.tags(for: selectedServer),
                        status: manager.statuses[selectedServer.id] ?? ServerStatus(),
                        lastConnectedAt: manager.lastConnection(for: selectedServer),
                        connect: { manager.connect(to: selectedServer) },
                        refresh: { Task { await manager.refreshStatus(for: selectedServer) } },
                        edit: { edit(selectedServer) },
                        copyConfiguration: { manager.copyConfiguration(for: selectedServer) },
                        delete: { pendingServerDeletion = selectedServer },
                        back: { withAnimation(.smooth(duration: 0.24)) { selectedServerID = nil } }
                    )
                    .id(selectedServer.id)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 30) {
                            ServerGroups(
                                groups: manager.groups,
                                servers: manager.servers,
                                selection: $scope,
                                createGroup: { groupPrompt = DashboardGroupPrompt() },
                                editGroup: { groupPrompt = DashboardGroupPrompt(group: $0) },
                                deleteGroup: { pendingGroupDeletion = $0 },
                                moveServer: manager.move
                            )

                            ServerCardGrid(
                                servers: matchingServers,
                                allGroups: manager.groups,
                                statusForServer: { manager.statuses[$0.id] ?? ServerStatus() },
                                isFavorite: manager.isFavorite,
                                select: { server in
                                    withAnimation(.smooth(duration: 0.24)) { selectedServerID = server.id }
                                },
                                connect: manager.connect,
                                toggleFavorite: manager.toggleFavorite,
                                edit: edit,
                                duplicate: manager.duplicate,
                                delete: { pendingServerDeletion = $0 },
                                move: manager.move
                            )
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 22)
                    }
                    .scrollContentBackground(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
        .sheet(isPresented: $showsEditor) {
            ServerEditorView(manager: manager, server: editingServer) { saved in
                selectedServerID = saved.id
            }
        }
        .sheet(isPresented: $showsQuickConnect) { DashboardQuickConnectView(manager: manager) }
        .sheet(item: $groupPrompt) { prompt in
            DashboardGroupEditor(prompt: prompt) { name in
                if let group = prompt.group {
                    manager.renameGroup(group, to: name)
                } else if let group = manager.createGroup(named: name) {
                    scope = .group(group.id)
                }
            }
        }
        .fileImporter(
            isPresented: $showsSSHImporter,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            manager.importSSHConfiguration(from: url)
        }
        .confirmationDialog(
            pendingServerDeletion.map { "删除“\($0.name)”？" } ?? "删除服务器？",
            isPresented: Binding(
                get: { pendingServerDeletion != nil },
                set: { if !$0 { pendingServerDeletion = nil } }
            )
        ) {
            Button("删除服务器", role: .destructive) {
                if let server = pendingServerDeletion {
                    manager.delete(server)
                    if selectedServerID == server.id { selectedServerID = nil }
                }
                pendingServerDeletion = nil
            }
        } message: {
            Text("服务器资产、连接历史与关联密码将从本机移除。")
        }
        .confirmationDialog(
            pendingGroupDeletion.map { "删除分组“\($0.name)”？" } ?? "删除分组？",
            isPresented: Binding(
                get: { pendingGroupDeletion != nil },
                set: { if !$0 { pendingGroupDeletion = nil } }
            )
        ) {
            Button("删除分组", role: .destructive) {
                if let group = pendingGroupDeletion {
                    manager.deleteGroup(group)
                    if scope == .group(group.id) { scope = .all }
                }
                pendingGroupDeletion = nil
            }
        } message: {
            Text("分组中的服务器会保留，并移动到“未分组”。")
        }
        .alert(item: $manager.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("好")))
        }
        .task { await manager.bootstrap() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(selectedServer == nil ? "服务器" : "服务器详情")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Spacer(minLength: 16)

            Button("快速连接", systemImage: "bolt.fill") { showsQuickConnect = true }
                .buttonStyle(DashboardToolbarButtonStyle())

            Button {
                editingServer = nil
                showsEditor = true
            } label: {
                Label("添加服务器", systemImage: "plus.circle.fill")
            }
            .buttonStyle(DashboardToolbarButtonStyle(tinted: true))

            Menu {
                Toggle("定时检测（每 5 分钟）", isOn: $manager.periodicChecksEnabled)
                Button("立即检测全部", systemImage: "arrow.clockwise") {
                    Task { await manager.refreshAllStatus() }
                }
                Divider()
                Button("从 SSH 配置导入…", systemImage: "square.and.arrow.down") {
                    showsSSHImporter = true
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(DashboardToolbarButtonStyle(iconOnly: true))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
        .background(.ultraThinMaterial.opacity(0.52))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 44, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 112, height: 112)
                .background(Color.accentColor.opacity(0.09), in: Circle())
            Text("添加你的第一台服务器")
                .font(.system(size: 23, weight: .semibold, design: .rounded))
            Text("集中管理 SSH 主机、连接状态和快捷操作。")
                .font(.callout).foregroundStyle(.secondary)
            Button("添加服务器", systemImage: "plus.circle.fill") {
                editingServer = nil
                showsEditor = true
            }
            .buttonStyle(.borderedProminent)
            Button("从 SSH 配置导入…", systemImage: "square.and.arrow.down") {
                showsSSHImporter = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedServer: Server? {
        manager.servers.first { $0.id == selectedServerID }
    }

    private var matchingServers: [Server] {
        return manager.servers.filter { server in
            switch scope {
            case .all: true
            case .favorites: manager.isFavorite(server)
            case let .group(id): server.groupID == id
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func edit(_ server: Server) {
        editingServer = server
        showsEditor = true
    }
}

enum ServerScope: Hashable {
    case all
    case favorites
    case group(UUID)
}

struct ServerGroups: View {
    let groups: [ServerGroup]
    let servers: [Server]
    @Binding var selection: ServerScope
    let createGroup: () -> Void
    let editGroup: (ServerGroup) -> Void
    let deleteGroup: (ServerGroup) -> Void
    let moveServer: (Server, UUID?) -> Void

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 270), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "分组",
                actionTitle: "新建分组",
                action: createGroup
            )

            GlassEffectContainer(spacing: 14) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    scopeButton(
                        "全部主机",
                        symbol: "square.grid.2x2",
                        scope: .all,
                        color: .accentColor
                    )
                    scopeButton(
                        "收藏",
                        symbol: "star.fill",
                        scope: .favorites,
                        color: .yellow
                    )

                    ForEach(groups.sorted { $0.order < $1.order }) { group in
                        scopeButton(
                            group.name,
                            symbol: "folder.fill",
                            scope: .group(group.id),
                            color: groupColor(group.id)
                        )
                        .contextMenu {
                            Button("重命名", systemImage: "pencil") { editGroup(group) }
                            Button("删除分组", systemImage: "trash", role: .destructive) { deleteGroup(group) }
                        }
                    }
                }
            }
        }
    }

    private func scopeButton(
        _ title: String,
        symbol: String,
        scope: ServerScope,
        color: Color
    ) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { selection = scope }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selection == scope ? color : .secondary)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(selection == scope ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                Text(title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .glassEffect(
                selection == scope
                    ? .regular.tint(Color.accentColor.opacity(0.18)).interactive()
                    : .regular.interactive(),
                in: .rect(cornerRadius: 15)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        selection == scope ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.08),
                        lineWidth: selection == scope ? 1 : 0.6
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(selection == scope ? "已选择" : "")
        .dropDestination(for: String.self) { values, _ in
            guard case let .group(groupID) = scope,
                  let value = values.first,
                  let serverID = UUID(uuidString: value),
                  let server = servers.first(where: { $0.id == serverID }) else { return false }
            moveServer(server, groupID)
            return true
        }
    }

    private func groupColor(_ id: UUID) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .cyan, .pink]
        return colors[Int(id.hashValue.magnitude % UInt(colors.count))]
    }
}

struct ServerCardGrid: View {
    let servers: [Server]
    let allGroups: [ServerGroup]
    let statusForServer: (Server) -> ServerStatus
    let isFavorite: (Server) -> Bool
    let select: (Server) -> Void
    let connect: (Server) -> Void
    let toggleFavorite: (Server) -> Void
    let edit: (Server) -> Void
    let duplicate: (Server) -> Void
    let delete: (Server) -> Void
    let move: (Server, UUID?) -> Void

    @State private var revealedServerID: UUID?

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 270), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "主机")

            if servers.isEmpty {
                ContentUnavailableView(
                    "没有匹配的主机",
                    systemImage: "magnifyingglass",
                    description: Text("尝试调整搜索内容或选择其他分组。")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(servers) { server in
                        ServerCard(
                            server: server,
                            status: statusForServer(server),
                            favorite: isFavorite(server),
                            actionsRevealed: Binding(
                                get: { revealedServerID == server.id },
                                set: { revealedServerID = $0 ? server.id : nil }
                            ),
                            select: { select(server) },
                            toggleFavorite: { toggleFavorite(server) }
                        )
                        .contextMenu {
                            Button("打开终端", systemImage: "terminal") { connect(server) }
                            Button(isFavorite(server) ? "取消收藏" : "收藏", systemImage: isFavorite(server) ? "star.slash" : "star") {
                                toggleFavorite(server)
                            }
                            Divider()
                            Menu("移动到分组", systemImage: "folder") {
                                Button("未分组") { move(server, nil) }
                                ForEach(allGroups.sorted { $0.order < $1.order }) { group in
                                    Button(group.name) { move(server, group.id) }
                                }
                            }
                            Button("编辑", systemImage: "pencil") { edit(server) }
                            Button("复制服务器", systemImage: "plus.square.on.square") { duplicate(server) }
                            Divider()
                            Button("删除", systemImage: "trash", role: .destructive) { delete(server) }
                        }
                        .draggable(server.id.uuidString)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }

    }
}

private func sectionHeader(
    title: String,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(title)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
        Spacer()
        if let actionTitle, let action {
            Button(actionTitle, systemImage: "plus", action: action)
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }
}

struct ServerCard: View {
    let server: Server
    let status: ServerStatus
    let favorite: Bool
    @Binding var actionsRevealed: Bool
    let select: () -> Void
    let toggleFavorite: () -> Void

    @State private var hovering = false
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeStartOffset: CGFloat = 0
    @State private var swipeTravel: CGFloat = 0
    @State private var swipeInProgress = false

    private let actionWidth: CGFloat = 52

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                toggleFavorite()
                closeActions()
            } label: {
                ZStack {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 16))
                        .foregroundStyle(favorite ? Color.yellow : Color.secondary)
                }
                .frame(width: 36, height: 36)
                .glassEffect(
                    .regular.tint(favorite ? Color.yellow.opacity(0.16) : nil).interactive(),
                    in: .circle
                )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help(favorite ? "取消收藏" : "收藏")

            cardContent
                .offset(x: swipeOffset)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(
                    hovering ? Color.accentColor.opacity(0.34) : Color.white.opacity(0.14),
                    lineWidth: hovering ? 1 : 0.7
                )
        }
        .shadow(color: .black.opacity(hovering ? 0.16 : 0.07), radius: hovering ? 20 : 14, y: hovering ? 12 : 7)
        .animation(.snappy(duration: 0.2), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onHover { hovering = $0 }
        .background {
            TrackpadHorizontalSwipeObserver(handle: handleTrackpadSwipe)
        }
        .onAppear { swipeOffset = actionsRevealed ? -actionWidth : 0 }
        .onChange(of: actionsRevealed) { _, revealed in
            guard !swipeInProgress else { return }
            withAnimation(.snappy(duration: 0.24, extraBounce: 0.08)) {
                swipeOffset = revealed ? -actionWidth : 0
            }
        }
    }

    private var cardContent: some View {
        HStack(alignment: .center, spacing: 12) {
            ServerSystemIcon(
                system: status.detectedSystem ?? .unknown,
                color: isOnline ? Color.accentColor : Color.secondary
            )
            .frame(width: 34, height: 34)
            .background(
                isOnline ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(server.name).font(.headline).lineLimit(1)
                Text(server.host)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            if hovering {
                LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture {
            if actionsRevealed {
                closeActions()
            } else {
                select()
            }
        }
    }

    private func handleTrackpadSwipe(deltaX: CGFloat, phase: NSEvent.Phase) {
        if phase.contains(.began) || !swipeInProgress {
            swipeInProgress = true
            swipeStartOffset = actionsRevealed ? -actionWidth : 0
            swipeTravel = 0
        }

        if phase.contains(.changed) || phase.contains(.began) {
            swipeTravel += abs(deltaX)
            let direction: CGFloat = actionsRevealed ? 1 : -1
            swipeOffset = min(0, max(-actionWidth, swipeStartOffset + direction * swipeTravel))
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            swipeInProgress = false
            let reveal = swipeOffset < -actionWidth * 0.45
            actionsRevealed = reveal
            withAnimation(.snappy(duration: 0.26, extraBounce: 0.1)) {
                swipeOffset = reveal ? -actionWidth : 0
            }
        }
    }

    private func closeActions() {
        actionsRevealed = false
        withAnimation(.snappy(duration: 0.22, extraBounce: 0.06)) {
            swipeOffset = 0
        }
    }

    private var isOnline: Bool {
        status.availability == .online
    }
}

private struct TrackpadHorizontalSwipeObserver: NSViewRepresentable {
    let handle: (CGFloat, NSEvent.Phase) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.observedView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        weak var observedView: NSView?
        var handle: (CGFloat, NSEvent.Phase) -> Void
        private var monitor: Any?

        init(handle: @escaping (CGFloat, NSEvent.Phase) -> Void) {
            self.handle = handle
        }

        func startMonitoring() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.hasPreciseScrollingDeltas,
                      let view = observedView,
                      event.window === view.window else { return event }

                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }

                let finishesGesture = event.phase.contains(.ended) || event.phase.contains(.cancelled)
                let isHorizontalSwipe = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                    && abs(event.scrollingDeltaX) > 0.1
                guard finishesGesture || isHorizontalSwipe else { return event }

                handle(event.scrollingDeltaX, event.phase)
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stopMonitoring() }
    }
}

struct ServerSystemIcon: View {
    let system: ServerSystemIdentity
    let color: Color

    var body: some View {
        Group {
            if let assetName = system.assetName {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color)
                    .padding(9)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 18, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(system.title)
    }

    private var fallbackSymbol: String {
        switch system {
        case .macOS: "apple.logo"
        case .windows: "square.grid.2x2.fill"
        default: "desktopcomputer"
        }
    }
}

private struct DashboardQuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ServerManager
    @State private var host = ""
    @State private var user = NSUserName()
    @State private var port = 22
    @State private var authentication: ServerAuthentication = .agent
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("快速连接", systemImage: "bolt.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Text("直接连接临时主机，不必先创建服务器资产。")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 13) {
                quickField("IP 地址或域名") { TextField("192.168.1.100", text: $host) }
                HStack(spacing: 12) {
                    quickField("用户名") { TextField("root", text: $user) }
                    quickField("端口") { TextField("22", value: $port, format: .number).frame(width: 90) }
                }
                Picker("认证方式", selection: $authentication) {
                    ForEach(ServerAuthentication.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(16)
            .serverGlassCard(cornerRadius: 16)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("连接", action: connect)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(.regularMaterial)
    }

    private func quickField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connect() {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanUser.isEmpty, (1...65535).contains(port) else {
            errorMessage = "请输入有效的地址、用户名和端口。"
            return
        }
        let server = Server(name: cleanHost, host: cleanHost, user: cleanUser, port: port, credentialID: UUID())
        manager.connect(to: server)
        dismiss()
    }
}

private struct DashboardGroupPrompt: Identifiable {
    let id = UUID()
    var group: ServerGroup?
}

private struct DashboardGroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: DashboardGroupPrompt
    let onSave: (String) -> Void
    @State private var name: String

    init(prompt: DashboardGroupPrompt, onSave: @escaping (String) -> Void) {
        self.prompt = prompt
        self.onSave = onSave
        _name = State(initialValue: prompt.group?.name ?? "新分组")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.group == nil ? "新建分组" : "重命名分组").font(.title2.weight(.bold))
            Text("分组用于按环境或用途组织服务器。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("分组名称", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("存储", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(.regularMaterial)
    }

    private func save() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSave(value)
        dismiss()
    }
}

private struct DashboardBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.accentColor.opacity(0.08), Color.clear, Color.cyan.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.accentColor.opacity(0.045))
                .frame(width: 520, height: 520)
                .blur(radius: 90)
                .offset(x: 260, y: -240)
        }
        .ignoresSafeArea()
    }
}

private struct DashboardToolbarButtonStyle: ButtonStyle {
    var tinted = false
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(tinted ? Color.white : Color.primary)
            .padding(.horizontal, iconOnly ? 9 : 12)
            .frame(height: 36)
            .background(
                tinted ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 0.9) : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.055),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(tinted ? 0.2 : 0.13), lineWidth: 0.7)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}
