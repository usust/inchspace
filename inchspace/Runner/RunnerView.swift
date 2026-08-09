import SwiftUI

struct RunnerView: View {
    enum Page: String, CaseIterable, Identifiable {
        case dashboard
        case localServices
        case servers

        var id: String { rawValue }
        var title: String {
            switch self {
            case .dashboard: "概览"
            case .localServices: "本机服务"
            case .servers: "服务器"
            }
        }
        var symbol: String {
            switch self {
            case .dashboard: "square.grid.2x2"
            case .localServices: "desktopcomputer"
            case .servers: "server.rack"
            }
        }
    }

    @ObservedObject var store: RunnerStore
    @State private var page: Page = .dashboard
    @State private var showsTaskEditor = false
    @State private var editingTask: RunnerTask?
    @State private var logTaskID: UUID?

    var body: some View {
        ZStack {
            RunnerBackground()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.45)
                Group {
                    switch page {
                    case .dashboard:
                        RunnerDashboardView(
                            store: store,
                            addTask: presentNewTaskEditor,
                            editTask: edit,
                            showLogs: { logTaskID = $0 }
                        )
                    case .localServices:
                        RunnerLocalServicesView(store: store)
                    case .servers:
                        RunnerServersView(store: store)
                    }
                }
            }
        }
        .sheet(isPresented: $showsTaskEditor) {
            RunnerTaskEditor(task: editingTask) { task in
                if editingTask == nil { store.add(task) } else { store.update(task) }
            }
        }
        .sheet(item: $logTaskID) { id in
            if let task = store.tasks.first(where: { $0.id == id }) {
                RunnerLogView(store: store, task: task)
            }
        }
        .alert(item: $store.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("好")))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            Text("运行中心")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Spacer()
            HStack(spacing: 4) {
                ForEach(Page.allCases) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { page = item }
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 13)
                            .frame(height: 34)
                            .background(page == item ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(page == item ? Color.accentColor : Color.primary)
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.16)) }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }

    private func edit(_ task: RunnerTask) {
        editingTask = task
        showsTaskEditor = true
    }

    private func presentNewTaskEditor() {
        editingTask = nil
        showsTaskEditor = true
    }
}

struct RunnerBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.09), Color.clear, Color.cyan.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }
}

extension View {
    func runnerGlassCard(cornerRadius: CGFloat = 22) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.055), radius: 18, y: 8)
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

#if DEBUG
struct RunnerView_Previews: PreviewProvider {
    static var previews: some View { RunnerView(store: RunnerStore()).frame(width: 980, height: 780) }
}
#endif
