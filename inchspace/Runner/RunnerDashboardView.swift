import SwiftUI

struct RunnerDashboardView: View {
    @ObservedObject var store: RunnerStore
    let addTask: () -> Void
    let editTask: (RunnerTask) -> Void
    let showLogs: (UUID) -> Void

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 430), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                machineOverview
                if !favoriteTasks.isEmpty {
                    sectionTitle("常用")
                    favoriteStrip
                }
                taskSectionTitle
                if store.tasks.isEmpty { emptyTasks }
                else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(store.tasks) { task in
                            RunnerTaskCard(
                                task: task,
                                snapshot: store.snapshots[task.id] ?? RunnerTaskSnapshot(id: task.id),
                                start: { store.start(task.id) },
                                stop: { store.stop(task.id) },
                                restart: { store.restart(task.id) },
                                pause: { store.togglePause(task.id) },
                                logs: { showLogs(task.id) },
                                edit: { editTask(task) },
                                favorite: { store.toggleFavorite(task.id) },
                                delete: { store.delete(task.id) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
        }
    }

    private var favoriteTasks: [RunnerTask] { store.tasks.filter(\.isFavorite) }

    private var machineOverview: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("本机", systemImage: "laptopcomputer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(Host.current().localizedName ?? "这台 Mac")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 7) {
                    Circle().fill(store.runningCount > 0 ? Color.green : Color.secondary.opacity(0.55)).frame(width: 8, height: 8)
                    Text(store.runningCount > 0 ? "服务状态正常" : "等待任务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            metric(title: "运行中", value: "\(store.runningCount)", unit: "个任务", color: .green)
            metric(title: "CPU", value: store.cpuPercent.formatted(.number.precision(.fractionLength(0))), unit: "%", color: .blue)
            metric(title: "内存", value: store.memoryPercent.formatted(.number.precision(.fractionLength(0))), unit: "%", color: .purple)
        }
        .padding(24)
        .runnerGlassCard(cornerRadius: 24)
    }

    private func metric(title: String, value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(color)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, alignment: .leading)
    }

    private var favoriteStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(favoriteTasks) { task in
                    let state = store.snapshots[task.id]?.state ?? .stopped
                    Button {
                        if state == .running || state == .paused { store.stop(task.id) }
                        else { store.start(task.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: state == .running ? "stop.fill" : "play.fill")
                                .foregroundStyle(state == .running ? .red : .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.name).font(.subheadline.weight(.semibold))
                                Text(state.title).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16).frame(height: 54)
                        .runnerGlassCard(cornerRadius: 17)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyTasks: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 68, height: 68)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            VStack(spacing: 5) {
                Text("还没有任务").font(.headline)
                Text("创建任务来运行并监控命令、脚本或开发服务。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button(action: addTask) {
                Label("新建任务", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: .command)
            .help("创建一个可运行的命令任务")
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .runnerGlassCard()
    }

    private var taskSectionTitle: some View {
        HStack {
            Text("我的任务").font(.title3.weight(.semibold))
            Spacer()
            if !store.tasks.isEmpty {
                Button(action: addTask) {
                    Label("新建任务", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .keyboardShortcut("n", modifiers: .command)
                .help("创建一个可运行的命令任务")
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
        }
    }
}

private struct RunnerTaskCard: View {
    @Environment(\.openURL) private var openURL
    let task: RunnerTask
    let snapshot: RunnerTaskSnapshot
    let start: () -> Void
    let stop: () -> Void
    let restart: () -> Void
    let pause: () -> Void
    let logs: () -> Void
    let edit: () -> Void
    let favorite: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(statusColor.opacity(0.13))
                    if snapshot.state == .starting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: snapshot.state == .running ? "waveform.path.ecg" : "play.fill")
                            .foregroundStyle(statusColor)
                            .symbolEffect(.pulse, options: .repeating, isActive: snapshot.state == .running)
                    }
                }.frame(width: 45, height: 45)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                            .shadow(color: snapshot.state == .running ? statusColor.opacity(0.7) : .clear, radius: 4)
                        Text(task.port.map { "\(snapshot.state.title)  ·  端口 \($0)" } ?? snapshot.state.title)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button(task.isFavorite ? "取消收藏" : "收藏", systemImage: task.isFavorite ? "star.slash" : "star", action: favorite)
                    Button("编辑", systemImage: "pencil", action: edit)
                    Divider()
                    Button("删除", systemImage: "trash", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                GridRow {
                    info("PID", snapshot.pid.map(String.init) ?? "—")
                    info("运行时间", RunnerFormat.duration(snapshot.uptime))
                    info("启动时间", snapshot.startedAt?.formatted(date: .omitted, time: .shortened) ?? "—")
                }
                GridRow {
                    info("CPU", "\(snapshot.cpuPercent.formatted(.number.precision(.fractionLength(1))))%")
                    info("内存", RunnerFormat.bytes(snapshot.memoryBytes))
                    info("最近退出码", snapshot.lastExitCode.map(String.init) ?? "—")
                }
            }

            HStack(spacing: 8) {
                if snapshot.state == .running || snapshot.state == .paused || snapshot.state == .starting {
                    Button("停止", systemImage: "stop.fill", action: stop).buttonStyle(.bordered)
                    Button("重启", systemImage: "arrow.clockwise", action: restart).buttonStyle(.bordered)
                    Button(snapshot.state == .paused ? "继续" : "暂停", systemImage: snapshot.state == .paused ? "play.fill" : "pause.fill", action: pause)
                        .buttonStyle(.bordered)
                        .disabled(snapshot.state == .starting)
                } else {
                    Button("启动", systemImage: "play.fill", action: start).buttonStyle(.borderedProminent)
                }
                Spacer()
                if snapshot.state == .running, let port = task.port,
                   let url = URL(string: "http://localhost:\(port)") {
                    Button("打开", systemImage: "safari") { openURL(url) }.buttonStyle(.bordered)
                }
                Button("日志", systemImage: "doc.text.magnifyingglass", action: logs).buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(19)
        .runnerGlassCard()
        .animation(.easeInOut(duration: 0.25), value: snapshot.state)
    }

    private var statusColor: Color {
        switch snapshot.state {
        case .running: .green
        case .starting: .blue
        case .failed: .red
        case .paused: .orange
        case .stopped: .secondary
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption.weight(.medium)).lineLimit(1)
        }
    }
}

enum RunnerFormat {
    static func duration(_ interval: TimeInterval) -> String {
        guard interval >= 1 else { return "—" }
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)秒" }
        if seconds < 3600 { return "\(seconds / 60)分钟" }
        return "\(seconds / 3600)小时\((seconds % 3600) / 60)分钟"
    }

    static func bytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
