import SwiftUI
import UniformTypeIdentifiers

struct ServerManagerView: View {
    @ObservedObject var manager: ServerManager
    @State private var selectedServerID: UUID?
    @State private var selectedGroupID: UUID?
    @State private var selectedTagID: UUID?
    @State private var searchText = ""
    @State private var showsEditor = false
    @State private var editingServer: Server?
    @State private var showsQuickConnect = false
    @State private var showsSSHImporter = false
    @State private var groupPrompt: GroupPrompt?
    @State private var pendingServerDeletion: Server?
    @State private var pendingGroupDeletion: ServerGroup?
    @Namespace private var sidebarSelection

    var body: some View {
        ServerDashboardView(manager: manager)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("服务器")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("远程资产与 SSH 连接管理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索服务器", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(width: 226, height: 36)
            .serverGlassCard(cornerRadius: 11, shadow: false)

            Button("快速连接", systemImage: "bolt.fill") { showsQuickConnect = true }
                .buttonStyle(ServerToolbarButtonStyle())

            Button {
                editingServer = nil
                showsEditor = true
            } label: {
                Label("添加服务器", systemImage: "plus.circle.fill")
            }
            .buttonStyle(ServerToolbarButtonStyle(tinted: true))

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
                Image(systemName: "gearshape")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(ServerToolbarButtonStyle(iconOnly: true))
            .help("服务器设置")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
        .background(.ultraThinMaterial.opacity(0.52))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.09))
                    .frame(width: 112, height: 112)
                    .blur(radius: 1)
                Image(systemName: "server.rack")
                    .font(.system(size: 43, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }

            Text("添加你的第一台服务器")
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .padding(.top, 22)
            Text("集中管理 SSH 主机、连接状态和快捷操作。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 7)

            Button("添加服务器", systemImage: "plus.circle.fill") {
                editingServer = nil
                showsEditor = true
            }
            .buttonStyle(ServerPrimaryButtonStyle())
            .padding(.top, 24)

            Button {
                showsSSHImporter = true
            } label: {
                VStack(spacing: 4) {
                    Label("快速导入", systemImage: "square.and.arrow.down")
                        .font(.callout.weight(.medium))
                    Text("从配置文件导入 SSH 主机")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func serverSidebar(compact: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 12 : 17) {
                    sidebarSection("浏览") {
                        sidebarFilter(
                            title: "全部服务器",
                            symbol: "server.rack",
                            count: manager.servers.count,
                            selected: selectedGroupID == nil && selectedTagID == nil
                        ) {
                            selectFilter(groupID: nil, tagID: nil)
                        }
                    }

                    if !compact {
                        sidebarSection("分组") {
                            if manager.groups.isEmpty {
                                Text("还没有分组")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 9)
                            }
                            ForEach(flattenedGroups, id: \.group.id) { item in
                                groupRow(item.group, depth: item.depth)
                            }
                            Button {
                                groupPrompt = GroupPrompt()
                            } label: {
                                Label("新建分组", systemImage: "plus")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 9)
                                    .frame(height: 27)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }

                        if !manager.tags.isEmpty {
                            sidebarSection("标签") {
                                ForEach(manager.tags) { tag in
                                    sidebarFilter(
                                        title: tag.name,
                                        symbol: "tag",
                                        count: manager.servers.filter { $0.tagIDs.contains(tag.id) }.count,
                                        selected: selectedTagID == tag.id
                                    ) {
                                        selectFilter(groupID: nil, tagID: tag.id)
                                    }
                                    .contextMenu {
                                        Button("删除标签", role: .destructive) { manager.deleteTag(tag) }
                                    }
                                }
                            }
                        }
                    }

                    sidebarSection(collectionTitle) {
                        if filteredServers.isEmpty {
                            VStack(spacing: 7) {
                                Image(systemName: "magnifyingglass")
                                Text("没有匹配的服务器")
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                        } else {
                            ForEach(filteredServers) { server in
                                serverRow(server)
                                    .contextMenu { serverContextMenu(server) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 13)
            }

            HStack {
                Text("\(filteredServers.count) 台服务器")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await manager.refreshAllStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("刷新状态")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.ultraThinMaterial.opacity(0.34))
        }
        .background(.ultraThinMaterial.opacity(0.72))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1)
        }
    }

    private func sidebarSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .lineLimit(1)
            content()
        }
    }

    private func sidebarFilter(
        title: String,
        symbol: String,
        count: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 17)
                Text(title).lineLimit(1)
                Spacer(minLength: 5)
                Text(String(count)).font(.caption2).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .matchedGeometryEffect(id: "filter", in: sidebarSelection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
    }

    private func groupRow(_ group: ServerGroup, depth: Int) -> some View {
        sidebarFilter(
            title: group.name,
            symbol: depth == 0 ? "folder.fill" : "folder",
            count: manager.servers.filter { $0.groupID == group.id }.count,
            selected: selectedGroupID == group.id
        ) {
            selectFilter(groupID: group.id, tagID: nil)
        }
        .padding(.leading, CGFloat(depth * 12))
        .contextMenu {
            Button("新建子分组") { groupPrompt = GroupPrompt(parentID: group.id) }
            Button("重命名") { groupPrompt = GroupPrompt(group: group) }
            Divider()
            Button("删除分组", role: .destructive) { pendingGroupDeletion = group }
        }
        .draggable(group.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first, let movingID = UUID(uuidString: value) else { return false }
            manager.moveGroup(movingID, before: group.id)
            return true
        }
    }

    private func serverRow(_ server: Server) -> some View {
        let selected = selectedServerID == server.id
        let status = manager.statuses[server.id] ?? ServerStatus()

        return Button {
            withAnimation(.smooth(duration: 0.24)) { selectedServerID = server.id }
        } label: {
            HStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "server.rack")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(width: 31, height: 31)
                        .background(Color.primary.opacity(selected ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 9))
                    Circle()
                        .fill(statusColor(status.availability))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(server.host)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .matchedGeometryEffect(id: "server", in: sidebarSelection)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { manager.connect(to: server) })
    }

    @ViewBuilder
    private var detailCanvas: some View {
        if let server = selectedServer {
            ServerDetailPanel(
                server: server,
                credential: manager.credential(for: server),
                group: manager.group(for: server),
                tags: manager.tags(for: server),
                status: manager.statuses[server.id] ?? ServerStatus(),
                lastConnectedAt: manager.lastConnection(for: server),
                connect: { manager.connect(to: server) },
                refresh: { Task { await manager.refreshStatus(for: server) } },
                edit: {
                    editingServer = server
                    showsEditor = true
                },
                copyConfiguration: { manager.copyConfiguration(for: server) },
                delete: { pendingServerDeletion = server }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("没有匹配的服务器").font(.headline)
                Text("尝试调整搜索、分组或标签。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("清除筛选") {
                    searchText = ""
                    selectFilter(groupID: nil, tagID: nil)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func serverContextMenu(_ server: Server) -> some View {
        Button("打开终端", systemImage: "terminal") { manager.connect(to: server) }
        Button("复制 SSH 命令", systemImage: "doc.on.doc") { manager.copySSHCommand(for: server) }
        Divider()
        Button("编辑", systemImage: "pencil") {
            editingServer = server
            showsEditor = true
        }
        Button("复制服务器", systemImage: "plus.square.on.square") { manager.duplicate(server) }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive) { pendingServerDeletion = server }
    }

    private var selectedServer: Server? { manager.servers.first { $0.id == selectedServerID } }

    private var collectionTitle: String {
        if let selectedGroupID { return manager.groups.first { $0.id == selectedGroupID }?.name ?? "服务器" }
        if let selectedTagID { return manager.tags.first { $0.id == selectedTagID }.map { "#\($0.name)" } ?? "服务器" }
        return "服务器"
    }

    private var filteredServers: [Server] {
        manager.servers.filter { server in
            let matchesGroup = selectedGroupID == nil || server.groupID == selectedGroupID
            let matchesTag = selectedTagID == nil || server.tagIDs.contains(selectedTagID!)
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchable = [server.name, server.host, server.user] + manager.tags(for: server).map(\.name)
            let matchesSearch = query.isEmpty || searchable.contains { $0.localizedCaseInsensitiveContains(query) }
            return matchesGroup && matchesTag && matchesSearch
        }
        .sorted { lhs, rhs in
            let left = manager.lastConnection(for: lhs) ?? .distantPast
            let right = manager.lastConnection(for: rhs) ?? .distantPast
            return left == right ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : left > right
        }
    }

    private var flattenedGroups: [(group: ServerGroup, depth: Int)] {
        func visit(_ parentID: UUID?, depth: Int) -> [(ServerGroup, Int)] {
            manager.groups.filter { $0.parentID == parentID }.sorted { $0.order < $1.order }.flatMap { group in
                [(group, depth)] + visit(group.id, depth: depth + 1)
            }
        }
        return visit(nil, depth: 0)
    }

    private func selectFilter(groupID: UUID?, tagID: UUID?) {
        withAnimation(.smooth(duration: 0.24)) {
            selectedGroupID = groupID
            selectedTagID = tagID
        }
        ensureSelection()
    }

    private func ensureSelection() {
        let ids = filteredServers.map(\.id)
        if selectedServerID == nil || !ids.contains(selectedServerID!) {
            selectedServerID = ids.first
        }
    }
}

struct ServerDetailPanel: View {
    let server: Server
    let credential: SSHCredential?
    let group: ServerGroup?
    let tags: [ServerTag]
    let status: ServerStatus
    let lastConnectedAt: Date?
    let connect: () -> Void
    let refresh: () -> Void
    let edit: () -> Void
    let copyConfiguration: () -> Void
    let delete: () -> Void
    var back: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], alignment: .leading, spacing: 16) {
                    informationCard
                    quickActionsCard
                    serviceStatusCard
                    resourceCard
                }

                if !server.notes.isEmpty {
                    GlassSection(title: "备注", symbol: "note.text") {
                        Text(server.notes)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button("编辑服务器", systemImage: "pencil", action: edit)
                    Button("复制 SSH 配置", systemImage: "doc.on.doc", action: copyConfiguration)
                    Spacer()
                    Button("删除服务器", systemImage: "trash", role: .destructive, action: delete)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 15) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(ServerToolbarButtonStyle(iconOnly: true))
                .help("返回服务器")
            }
            ServerSystemIcon(
                system: status.detectedSystem ?? .unknown,
                color: status.availability == .online ? Color.accentColor : Color.secondary
            )
                .frame(width: 54, height: 54)
                .background(
                    status.availability == .online
                        ? Color.accentColor.opacity(0.10)
                        : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text(server.name)
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                    ServerStatusLabel(status: status)
                }
                Text(server.endpoint)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(ServerToolbarButtonStyle(iconOnly: true))
                .help("检测连接状态")
            Button("打开终端", systemImage: "terminal", action: connect)
                .buttonStyle(ServerPrimaryButtonStyle())
            Button("文件管理", systemImage: "folder") {}
                .buttonStyle(ServerToolbarButtonStyle())
                .disabled(true)
                .help("文件管理将在后续版本中提供")
            Button("执行命令", systemImage: "chevron.left.forwardslash.chevron.right") {}
                .buttonStyle(ServerToolbarButtonStyle())
                .disabled(true)
                .help("命令执行将在后续版本中提供")
        }
    }

    private var informationCard: some View {
        GlassSection(title: "基础信息", symbol: "info.circle") {
            detailRow("IP 地址", server.host)
            detailRow("SSH 用户", server.user)
            detailRow("系统", status.detectedSystem?.title ?? "等待自动检测")
            detailRow("端口", String(server.port))
            detailRow("认证", credential?.authentication.title ?? "未配置")
            if let group { detailRow("分组", group.name) }
            if !tags.isEmpty { detailRow("标签", tags.map(\.name).joined(separator: " · ")) }
        }
    }

    private var quickActionsCard: some View {
        GlassSection(title: "快捷操作", symbol: "bolt") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 9)], spacing: 9) {
                DetailAction(title: "打开终端", symbol: "terminal", enabled: true, action: connect)
                DetailAction(title: "文件管理", symbol: "folder", enabled: false, action: {})
                DetailAction(title: "执行命令", symbol: "chevron.left.forwardslash.chevron.right", enabled: false, action: {})
                DetailAction(title: "上传文件", symbol: "arrow.up.doc", enabled: false, action: {})
                DetailAction(title: "Docker 管理", symbol: "shippingbox", enabled: false, action: {})
                DetailAction(title: "服务管理", symbol: "gearshape.2", enabled: false, action: {})
            }
        }
    }

    private var serviceStatusCard: some View {
        GlassSection(title: "服务状态", symbol: "gearshape.2") {
            serviceRow("SSH", symbol: "terminal", state: status.availability == .online ? "运行中" : status.availability.title, color: statusColor(status.availability))
            serviceRow("systemd", symbol: "gearshape", state: status.availability == .online ? "可检测" : "未检测", color: status.availability == .online ? .blue : .secondary)
            serviceRow("Docker", symbol: "shippingbox", state: "未检测", color: .secondary)
        }
    }

    private var resourceCard: some View {
        GlassSection(title: "资源占用", symbol: "chart.bar") {
            ResourceMeter(title: "CPU", symbol: "cpu", value: status.cpuPercent)
            ResourceMeter(title: "内存", symbol: "memorychip", value: status.memoryPercent)
            ResourceMeter(title: "磁盘", symbol: "internaldrive", value: status.diskPercent)
            if let checkedAt = status.checkedAt {
                Text("更新于 \(checkedAt, style: .relative)前")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if let lastConnectedAt {
                Text("最近连接 \(lastConnectedAt, style: .relative)前")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .font(.callout)
    }

    private func serviceRow(_ title: String, symbol: String, state: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(title)
            Spacer()
            Circle().fill(color).frame(width: 7, height: 7)
            Text(state).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

private struct GlassSection<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 11) { content }
        }
        .padding(17)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .serverGlassCard(cornerRadius: 18)
    }
}

private struct DetailAction: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ServerPressButtonStyle())
        .disabled(!enabled)
        .help(enabled ? title : "此操作将在后续版本中提供")
    }
}

private struct ResourceMeter: View {
    let title: String
    let symbol: String
    let value: Double?

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Label(title, systemImage: symbol).foregroundStyle(.secondary)
                Spacer()
                Text(value.map { "\(Int($0))%" } ?? "—").monospacedDigit()
            }
            .font(.caption)
            GeometryReader { proxy in
                Capsule().fill(Color.primary.opacity(0.07))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(meterColor)
                            .frame(width: proxy.size.width * min(max((value ?? 0) / 100, 0), 1))
                    }
            }
            .frame(height: 5)
        }
    }

    private var meterColor: Color {
        guard let value else { return .secondary.opacity(0.25) }
        if value >= 85 { return .red }
        if value >= 65 { return .orange }
        return .accentColor
    }
}

struct ServerStatusLabel: View {
    let status: ServerStatus

    var body: some View {
        HStack(spacing: 5) {
            if status.availability == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(statusColor(status.availability)).frame(width: 7, height: 7)
            }
            Text(status.availability.title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(statusColor(status.availability))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(statusColor(status.availability).opacity(0.09), in: Capsule())
    }
}

private struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ServerManager
    @State private var endpoint = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "bolt.fill").font(.title2).foregroundStyle(Color.accentColor)
                Text("快速连接").font(.title2.weight(.bold))
                Spacer()
            }
            Text("输入 user@host 或 user@host:port，不必先创建服务器资产。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("root@192.168.1.100:22", text: $endpoint)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("连接", action: connect).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(.regularMaterial)
    }

    private func connect() {
        let parts = endpoint.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else {
            errorMessage = "请输入包含用户名的连接地址。"
            return
        }
        let addressParts = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
        guard let host = addressParts.first, !host.isEmpty else {
            errorMessage = "请输入有效的服务器地址。"
            return
        }
        let port = addressParts.count == 2 ? Int(addressParts[1]) ?? 0 : 22
        guard (1...65535).contains(port) else {
            errorMessage = "端口必须在 1 到 65535 之间。"
            return
        }
        let server = Server(name: host, host: host, user: parts[0], port: port, credentialID: UUID())
        manager.connect(to: server)
        dismiss()
    }
}

private struct GroupPrompt: Identifiable {
    let id = UUID()
    var group: ServerGroup?
    var parentID: UUID?
    var name: String
    var title: String { group == nil ? "新建分组" : "重命名分组" }
    var message: String { group == nil ? "新分组将显示在服务器侧栏。" : "请输入新的分组名称。" }

    init(group: ServerGroup? = nil, parentID: UUID? = nil) {
        self.group = group
        self.parentID = parentID
        name = group?.name ?? "新分组"
    }
}

private struct GroupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: GroupPrompt
    let onSave: (String) -> Void
    @State private var name: String

    init(prompt: GroupPrompt, onSave: @escaping (String) -> Void) {
        self.prompt = prompt
        self.onSave = onSave
        _name = State(initialValue: prompt.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.title).font(.title2.weight(.bold))
            Text(prompt.message).font(.callout).foregroundStyle(.secondary)
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

private struct ServerCenterBackground: View {
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

private struct ServerToolbarButtonStyle: ButtonStyle {
    var tinted = false
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(tinted ? Color.white : Color.primary)
            .padding(.horizontal, iconOnly ? 9 : 12)
            .frame(height: 36)
            .background(tinted ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 0.9) : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(tinted ? 0.2 : 0.13), lineWidth: 0.7)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

private struct ServerPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.78 : 0.92), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.18), radius: 9, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

private struct ServerPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

private func statusColor(_ availability: ServerAvailability) -> Color {
    switch availability {
    case .online: .green
    case .offline: .secondary
    case .checking: .blue
    case .unknown: .secondary
    case .error: .red
    }
}

extension View {
    func serverGlassCard(cornerRadius: CGFloat = 20, shadow: Bool = true) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7)
            }
            .shadow(color: shadow ? .black.opacity(0.055) : .clear, radius: 16, y: 8)
    }
}

#if DEBUG
struct ServerManagerView_Previews: PreviewProvider {
    static var previews: some View {
        ServerManagerView(manager: ServerManager()).frame(width: 1200, height: 800)
    }
}
#endif
