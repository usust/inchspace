import SwiftUI

struct TerminalTabBar: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var preferences: TerminalPreferences
    @Environment(\.colorScheme) private var colorScheme
    let requestClose: (TerminalSession) -> Void

    init(manager: TerminalManager, requestClose: @escaping (TerminalSession) -> Void) {
        self.manager = manager
        self.preferences = manager.preferences
        self.requestClose = requestClose
    }

    var body: some View {
        let appearance = TerminalAppearance(
            theme: manager.preferences.theme, resolvedDark: colorScheme == .dark, preferences: manager.preferences
        )
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(manager.sessions) { session in
                    TerminalTab(
                        session: session,
                        appearance: appearance,
                        selected: manager.selectedSessionID == session.id,
                        select: { manager.select(session.id) },
                        close: { requestClose(session) }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: appearance.background))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: appearance.foreground).opacity(0.12)).frame(height: 1)
        }
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let appearance: TerminalAppearance
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Image(systemName: session.kind.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: selected ? appearance.cursor : appearance.foreground).opacity(selected ? 1 : 0.6))
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
                        .background(Color(nsColor: appearance.foreground).opacity(isHovering ? 0.10 : 0), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering || selected ? 0.8 : 0.16)
                .help("关闭终端")
            }
            .padding(.leading, 11)
            .padding(.trailing, 6)
            .frame(height: 30)
            .foregroundStyle(Color(nsColor: appearance.foreground).opacity(selected ? 1 : 0.65))
            .background(Color(nsColor: appearance.foreground).opacity(selected ? 0.08 : (isHovering ? 0.04 : 0)))
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle().fill(Color(nsColor: appearance.cursor)).frame(height: 2)
                }
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
