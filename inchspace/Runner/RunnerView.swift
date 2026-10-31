import SwiftUI

struct RunnerView: View {
    enum Page: String, CaseIterable, Identifiable {
        case dashboard
        case localServices

        var id: String { rawValue }
        var title: String {
            switch self {
            case .dashboard: "概览"
            case .localServices: "本机服务"
            }
        }
        var symbol: String {
            switch self {
            case .dashboard: "square.grid.2x2"
            case .localServices: "desktopcomputer"
            }
        }
    }

    @ObservedObject var store: RunnerStore
    @State private var page: Page = .dashboard
    @State private var taskEditor: RunnerTaskEditorRequest?
    @State private var logTaskID: UUID?

    var body: some View {
        ZStack {
            RunnerBackground()
            VStack(spacing: 0) {
                header
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
                    }
                }
            }
        }
        .sheet(item: $taskEditor) { request in
            RunnerTaskEditor(task: request.task) { task in
                request.save(task, to: store)
            }
            .id(request.id)
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
        HStack(spacing: AppLayout.featureHeaderSpacing) {
            AppFeatureTitle("运行中心")
            Spacer(minLength: 16)
            Picker("页面", selection: $page) {
                ForEach(Page.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
            Button("新建任务", systemImage: "plus", action: presentNewTaskEditor)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
        }
        .appFeatureHeaderBackground()
    }

    private func edit(_ task: RunnerTask) {
        taskEditor = RunnerTaskEditorRequest(task: task)
    }

    private func presentNewTaskEditor() {
        taskEditor = RunnerTaskEditorRequest(task: nil)
    }
}

struct RunnerBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

extension View {
    func runnerGlassCard(cornerRadius: CGFloat = 12) -> some View {
        appSurface(cornerRadius: cornerRadius)
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
