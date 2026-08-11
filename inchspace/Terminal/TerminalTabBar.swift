import SwiftUI

struct TerminalTabBar: View {
    @ObservedObject var manager: TerminalManager
    let requestClose: (TerminalSession) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(manager.sessions) { session in
                    TerminalTab(
                        session: session,
                        selected: manager.selectedSessionID == session.id,
                        select: { manager.select(session.id) },
                        close: { requestClose(session) }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Image(systemName: session.kind.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                if session.kind.isRemote {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(session.connectionState.title)
                }
                Text(session.title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(isHovering ? 0.10 : 0), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering || selected ? 0.8 : 0.16)
                .help("关闭终端")
            }
            .padding(.leading, 11)
            .padding(.trailing, 6)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.thinMaterial)
                    .opacity(selected ? 1 : 0)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(isHovering ? 0.045 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            if session.kind.isRemote {
                Button("重新连接", systemImage: "arrow.clockwise") { session.activePane.reconnect() }
                Divider()
            }
            Button("关闭终端", systemImage: "xmark", action: close)
        }
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: .green
        case .connecting, .starting: .orange
        case .disconnected: .secondary
        case .error: Color(nsColor: .systemRed)
        }
    }
}
