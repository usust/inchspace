import SwiftUI

struct ServerManagerView: View {
    @ObservedObject var manager: ServerManager

    var body: some View {
        ServerDashboardView(manager: manager)
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
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
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
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("检测连接状态")
            Button("打开终端", systemImage: "terminal", action: connect)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
            Button("文件管理", systemImage: "folder") {}
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(true)
                .help("文件管理将在后续版本中提供")
            Button("执行命令", systemImage: "chevron.left.forwardslash.chevron.right") {}
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
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
