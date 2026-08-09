import SwiftUI

struct RunnerLogView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RunnerStore
    let task: RunnerTask
    @State private var search = ""
    @State private var autoScroll = true

    private var entries: [RunnerLogEntry] {
        let logs = store.snapshots[task.id]?.logs ?? []
        guard !search.isEmpty else { return logs }
        return logs.filter { $0.message.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name).font(.title3.weight(.semibold))
                    Text("运行日志").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("搜索", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                Toggle("自动滚动", isOn: $autoScroll).toggleStyle(.switch).controlSize(.small)
                Button("清空") { store.clearLogs(task.id) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if entries.isEmpty {
                            Text(search.isEmpty ? "任务运行后，日志会实时显示在这里。" : "没有匹配的日志。")
                                .foregroundStyle(.secondary).padding(24)
                        }
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 14) {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                                Text(entry.message)
                                    .foregroundStyle(entry.isError ? Color.red.opacity(0.9) : Color(nsColor: .textColor))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 18).padding(.vertical, 5)
                            .id(entry.id)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.82))
                .onChange(of: entries.count) { _, _ in
                    guard autoScroll, let last = entries.last else { return }
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack {
                let snapshot = store.snapshots[task.id] ?? RunnerTaskSnapshot(id: task.id)
                Circle().fill(snapshot.state == .running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(snapshot.state.title)
                if let code = snapshot.lastExitCode { Text("最近退出代码 \(code)") }
                Spacer()
                Text("\(entries.count) 条")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 34)
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(.regularMaterial)
    }
}
