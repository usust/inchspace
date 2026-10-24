import SwiftUI

/// Auto-archive as one full-width workbench: a header with every action, a status strip, a Finder-style browser
/// of the folder with each file's status, and a side column with the selected file's details and the batch history.
struct ArchiveView: View {
    @ObservedObject var model: ArchiveViewModel
    @ObservedObject var aiSettings: TerminalAISettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AppPageBackground()
            switch model.screen {
            case .loading:
                ArchiveLoadingView(model: model)
            case .onboarding:
                ArchiveOnboardingView(model: model)
                    .transition(.opacity)
            case .dashboard:
                ArchiveWorkbenchView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : AppMotion.transition, value: model.screen)
        .task {
            model.attach(settings: aiSettings)
            await model.bootstrap()
        }
    }
}

private struct ArchiveLoadingView: View {
    @ObservedObject var model: ArchiveViewModel

    var body: some View {
        VStack(spacing: 14) {
            if let error = model.loadError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.orange)
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重新载入") { Task { await model.bootstrap() } }.buttonStyle(.bordered)
            } else {
                ProgressView()
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
    }
}

// MARK: - First-run guide

private struct ArchiveOnboardingView: View {
    @ObservedObject var model: ArchiveViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            switch model.onboardingStep {
            case .welcome: welcome
            case .folder: folder
            case .privacy: privacy
            }
            StepDots(current: model.onboardingStep.rawValue, count: ArchiveOnboardingStep.allCases.count)
        }
        .id(model.onboardingStep)
        .padding(32)
        .frame(maxWidth: 480)
        .appSurface(cornerRadius: 24)
        .padding(24)
        .animation(reduceMotion ? nil : AppMotion.transition, value: model.onboardingStep)
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            CardHeader(symbol: "sparkles.rectangle.stack", title: "让文件夹自己变整齐",
                       subtitle: "选一个文件夹，AI 会逐个识别文件、放到合适的位置，并记下每个文件是什么。")
            Button { model.advanceOnboarding() } label: { Text("开始").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var folder: some View {
        VStack(spacing: 22) {
            CardHeader(symbol: "folder.badge.plus", title: "选择要整理的文件夹",
                       subtitle: "比如“下载”或“文档”。文件只会在这个文件夹内部移动。")
            Button { model.chooseFolder() } label: { Text("选择文件夹…").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if case .failed(let message) = model.activity {
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    private var privacy: some View {
        VStack(spacing: 22) {
            CardHeader(symbol: "lock.shield", title: "由 AI 来整理",
                       subtitle: "AI 只会收到文件名、所在文件夹和少量关键词，不会收到文件正文。本机模型（如 Ollama 中的 Qwen）数据不出这台 Mac。")
            if let folder = model.workspace {
                Label(folder.url.lastPathComponent, systemImage: "folder")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing: 10) {
                if model.isModelConfigured {
                    Button { model.finishOnboarding() } label: { Text("同意并开始整理").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button { model.openModelSettings() } label: { Text("先配置 AI 模型").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { model.finishOnboarding() } label: { Text("稍后配置，先进入页面").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                }
            }
        }
    }
}

// MARK: - Workbench

private struct ArchiveWorkbenchView: View {
    @ObservedObject var model: ArchiveViewModel
    @State private var confirmsReorganize = false
    @State private var editsConvention = false

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                let wide = proxy.size.width >= 880
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 16) {
                                ArchiveStatusStrip(model: model)
                                ArchiveBrowserPanel(model: model)
                            }
                            ArchiveSideColumn(model: model).frame(width: 330)
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 16) {
                                ArchiveStatusStrip(model: model)
                                ArchiveBrowserPanel(model: model).frame(minHeight: 420)
                                ArchiveSideColumn(model: model).frame(minHeight: 360)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .padding(.top, 8)
            }
        }
        .sheet(isPresented: $editsConvention) { ArchiveConventionSheet(model: model) }
        .confirmationDialog("重新整理全部文件？", isPresented: $confirmsReorganize, titleVisibility: .visible) {
            Button("重新整理全部") { Task { await model.reorganizeEverything() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清空所有文件的处理记录，下次运行重新识别每个文件。已经整理好的文件可能再次被移动或改名。")
        }
    }

    private var header: some View {
        HStack(spacing: AppLayout.featureHeaderSpacing) {
            AppFeatureTitle("自动归档", subtitle: subtitle)
            Spacer(minLength: 16)
            ViewThatFits(in: .horizontal) {
                actions(compact: false)
                actions(compact: true)
            }
        }
        .appFeatureHeaderBackground()
    }

    private var subtitle: String {
        guard let folder = model.workspace else { return "" }
        let path = folder.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if let name = model.modelName { return "\(path) · \(name)" }
        return path
    }

    @ViewBuilder private func actions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if model.isRunning {
                Button("停止", systemImage: "stop.fill") { model.cancelRun() }
                    .buttonStyle(.bordered)
            } else {
                Button("立即整理", systemImage: "sparkles") { model.dismissFailure(); model.organize() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isModelConfigured)
                    .help(model.isModelConfigured ? "现在检查文件夹并整理新文件" : "请先配置 AI 模型")
            }
            Button(model.isWatching ? "暂停" : "恢复", systemImage: model.isWatching ? "pause.fill" : "play.fill") {
                model.setWatching(!model.isWatching)
            }
            .buttonStyle(.bordered)
            .help(model.isWatching ? "暂停监视文件夹" : "恢复监视，文件夹有变化时自动整理")
            Divider().frame(height: 18).padding(.horizontal, 2)
            Group {
                Button("更换文件夹", systemImage: "folder.badge.gearshape") { model.chooseFolder() }
                    .help("选择另一个要整理的文件夹")
                if let folder = model.workspace {
                    Button("在访达中显示", systemImage: "folder") { model.reveal(folder.url) }
                        .help("在访达中打开这个文件夹")
                }
                Button("整理规范", systemImage: "list.bullet.rectangle") { editsConvention = true }
                    .disabled(model.isRunning)
                    .help("查看目录与命名规范，用一句话调整偏好")
                Button("重新整理全部", systemImage: "arrow.counterclockwise") { confirmsReorganize = true }
                    .disabled(model.isRunning)
                    .help("清空处理记录，重新识别每个文件")
                Button("模型设置", systemImage: "cpu") { model.openModelSettings() }
                    .help("选择用于整理的 AI 模型")
            }
            .buttonStyle(.bordered)
            .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
        }
        .controlSize(.regular)
    }
}

private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Status strip

private struct ArchiveStatusStrip: View {
    @ObservedObject var model: ArchiveViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            icon.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(2)
                    .contentTransition(.numericText())
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if case .idle = model.activity, model.isModelConfigured, let notice = model.conventionNotice {
                    Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                if case .working = model.activity {
                    ArchiveRunProgressBar(progress: model.progress, detail: model.progressDetail, startedAt: model.runStartedAt)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface()
        .animation(AppMotion.feedback, value: model.activity)
    }

    @ViewBuilder private var icon: some View {
        switch model.activity {
        case .working:
            ProgressView().controlSize(.regular)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.orange)
        case .idle:
            if model.isModelConfigured {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(.green)
            } else {
                Image(systemName: "cpu").font(.system(size: 22)).foregroundStyle(.orange)
            }
        }
    }

    private var title: String {
        switch model.activity {
        case .working(let message): return message
        case .failed: return "暂时没能整理"
        case .idle:
            guard model.isModelConfigured else { return "还没有可用的 AI 模型" }
            guard let summary = model.lastSummary, !summary.isEmpty else { return "文件夹很整齐" }
            var parts: [String] = []
            if summary.renamedFiles > 0 { parts.append("改名 \(summary.renamedFiles) 个文件") }
            if summary.movedFiles > 0 { parts.append("归类 \(summary.movedFiles) 个文件") }
            if summary.movedDirectories > 0 { parts.append("调整 \(summary.movedDirectories) 个文件夹") }
            return parts.isEmpty ? "刚刚整理了文件夹" : "刚刚" + parts.joined(separator: "、")
        }
    }

    private var subtitle: String {
        if case .failed(let message) = model.activity { return message }
        guard model.isModelConfigured else { return "整理全部由 AI 完成。请在模型设置中选择一个模型（本机 Ollama 的 Qwen 也可以）。" }
        let name = model.workspace?.url.lastPathComponent ?? ""
        var parts = [model.isWatching ? "\(name) · 监视中，有新文件会自动整理" : "\(name) · 已暂停"]
        if let last = model.lastRunAt { parts.append("上次整理 " + last.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        switch model.activity {
        case .failed:
            Button("重试") { model.dismissFailure(); model.organize() }.buttonStyle(.borderedProminent)
        case .idle where !model.isModelConfigured:
            Button("模型设置") { model.openModelSettings() }.buttonStyle(.borderedProminent)
        default:
            let counts = model.liveCounts
            if counts.completed + counts.unplaced + counts.failed + counts.waiting > 0 {
                HStack(spacing: 14) {
                    if counts.waiting > 0 { CountBadge(title: "等待", count: counts.waiting, color: .secondary, symbol: "clock") }
                    if counts.completed > 0 { CountBadge(title: "已完成", count: counts.completed, color: .green, symbol: "checkmark.circle.fill") }
                    if counts.unplaced > 0 { CountBadge(title: "未归位", count: counts.unplaced, color: .yellow, symbol: "questionmark.folder.fill") }
                    if counts.failed > 0 { CountBadge(title: "失败", count: counts.failed, color: .red, symbol: "xmark.octagon.fill") }
                }
            }
        }
    }
}

private struct CountBadge: View {
    let title: String
    let count: Int
    let color: Color
    let symbol: String

    var body: some View {
        VStack(spacing: 3) {
            Text("\(count)").font(.title3.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
            Label(title, systemImage: symbol).font(.caption).labelStyle(.titleAndIcon)
        }
        .foregroundStyle(color)
        .frame(minWidth: 56)
        .accessibilityElement(children: .combine)
    }
}

private struct ArchiveFileStatusStyle {
    let title: String
    let symbol: String
    let color: Color

    init(_ status: ArchiveFileActivity.Status) {
        switch status {
        case .queued: (title, symbol, color) = ("等待中", "clock", .secondary)
        case .processing: (title, symbol, color) = ("处理中", "circle.dotted", .accentColor)
        case .completed: (title, symbol, color) = ("已完成", "checkmark.circle.fill", .green)
        case .unplaced: (title, symbol, color) = ("未归位", "questionmark.folder.fill", .yellow)
        case .skipped: (title, symbol, color) = ("未识别", "arrow.uturn.right.circle.fill", .orange)
        case .failed: (title, symbol, color) = ("失败", "xmark.octagon.fill", .red)
        }
    }
}

// MARK: - Side column: details and history

private struct ArchiveSideColumn: View {
    @ObservedObject var model: ArchiveViewModel

    var body: some View {
        VStack(spacing: 16) {
            ArchiveDetailPanel(model: model)
            ArchiveHistoryPanel(model: model)
        }
    }
}

private struct ArchiveDetailPanel: View {
    @ObservedObject var model: ArchiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文件详情").font(.headline)
                Spacer()
                if model.selectedEntry != nil {
                    Button { model.selectedPath = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("关闭详情")
                }
            }
            .padding(.horizontal, 16).frame(height: 44)
            Divider()
            if let entry = model.selectedEntry {
                ScrollView { details(entry).padding(16) }
            } else if let item = model.selectedItem {
                ScrollView { basics(item).padding(16) }
            } else {
                ScrollView { ArchiveConsistencyView(model: model).padding(16) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appSurface()
    }

    @ViewBuilder private func details(_ entry: ArchiveFileEntry) -> some View {
        let style = ArchiveFileStatusStyle(entry.status)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AppIconTile(symbol: symbol(for: entry), size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.body.weight(.semibold)).textSelection(.enabled)
                    Text(entry.folder.isEmpty ? "工作区根目录" : entry.folder).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Label(style.title, systemImage: style.symbol).font(.caption.weight(.medium)).foregroundStyle(style.color)
                }
            }
            if let summary = entry.record?.summary, !summary.isEmpty {
                Text(summary).font(.callout).foregroundStyle(.primary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .textSelection(.enabled)
            }
            section("基本信息") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    if let record = entry.record {
                        infoRow("创建时间", record.createdAt.map(format) ?? "未知")
                        infoRow("修改时间", format(record.modifiedAt))
                        infoRow("大小", ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file))
                        infoRow("主题", record.topic.isEmpty ? "—" : record.topic)
                        infoRow("处理时间", format(record.processedAt))
                    } else {
                        infoRow("状态", entry.detail ?? style.title)
                    }
                }
            }
            if let record = entry.record {
                section("这次的改动") {
                    VStack(alignment: .leading, spacing: 6) {
                        switch entry.change {
                        case .none:
                            Text(entry.status == .completed ? "位置和名称都没有变化" : (entry.detail ?? "没有改动")).font(.callout).foregroundStyle(.secondary)
                        case .renamed(let from, let to):
                            changeLine("名称", from: from, to: to)
                        case .moved(let from, let to):
                            changeLine("位置", from: from.isEmpty ? "工作区根目录" : from, to: to.isEmpty ? "工作区根目录" : to)
                        case .movedAndRenamed(let fromFolder, let toFolder, let fromName, let toName):
                            changeLine("位置", from: fromFolder.isEmpty ? "工作区根目录" : fromFolder, to: toFolder.isEmpty ? "工作区根目录" : toFolder)
                            changeLine("名称", from: fromName, to: toName)
                        }
                        if !record.reason.isEmpty {
                            Text("依据：" + record.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let suggestion = record.suggestedName, !record.wasRenamed {
                            Text("模型建议的名称（未采用）：" + suggestion).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            } else if let detail = entry.detail {
                section("状态") { Text(detail).font(.callout).foregroundStyle(entry.status == .failed ? .red : .secondary).textSelection(.enabled) }
            }
            HStack(spacing: 8) {
                Button("在访达中显示", systemImage: "folder") { model.reveal(URL(fileURLWithPath: entry.path)) }
                    .disabled(!model.fileExists(entry))
                if model.undoableOperation(for: entry) != nil {
                    Button("撤销此文件", systemImage: "arrow.uturn.backward") { Task { await model.undoFile(entry) } }
                        .disabled(model.isRunning)
                        .help("把这个文件放回原来的位置和名称")
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// A file autopilot has not looked at yet, or a folder: what is on disk and how its files stand.
    @ViewBuilder private func basics(_ item: ArchiveBrowserItem) -> some View {
        let status = ArchiveItemStatus(item)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ArchiveItemIcon(item: item, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.body.weight(.semibold)).textSelection(.enabled)
                    Text(item.folder.isEmpty ? "工作区根目录" : item.folder).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(status.title).font(.caption.weight(.medium)).foregroundStyle(status.color)
                }
            }
            section("基本信息") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    infoRow("种类", item.kind)
                    if !item.isDirectory, let size = item.size { infoRow("大小", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    if let modified = item.modified { infoRow("修改时间", format(modified)) }
                }
            }
            section("整理状态") {
                Text(item.isDirectory ? (item.stats.map(\.summary).flatMap { $0.isEmpty ? nil : $0 } ?? "这个文件夹里还没有整理过的文件")
                     : "还没有整理。下次运行时，歌曲、视频、安装包和大文件按类型放进各自类别的唯一文件夹，其他文件交给 AI 判断。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if item.isDirectory {
                    Button("打开文件夹", systemImage: "folder") { model.open(item) }
                }
                Button("在访达中显示", systemImage: "magnifyingglass") { model.reveal(item.url) }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
            content()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(value).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func changeLine(_ label: String, from: String, to: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(from).font(.callout).foregroundStyle(.secondary).strikethrough().textSelection(.enabled)
            Text("→ " + to).font(.callout.weight(.medium)).textSelection(.enabled)
        }
    }

    private func format(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    private func symbol(for entry: ArchiveFileEntry) -> String {
        switch (entry.path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp", "svg", "raw", "psd": "photo"
        case "mp3", "wav", "aac", "flac", "m4a", "aiff", "ogg": "music.note"
        case "mp4", "mov", "mkv", "avi", "m4v", "webm": "film"
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz": "archivebox"
        case "dmg", "pkg", "iso", "app": "shippingbox"
        case "xls", "xlsx", "csv", "numbers", "tsv": "tablecells"
        case "ppt", "pptx", "key": "rectangle.on.rectangle"
        case "pdf": "doc.richtext"
        default: "doc.text"
        }
    }
}

private struct ArchiveHistoryPanel: View {
    @ObservedObject var model: ArchiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("整理记录").font(.headline)
                Spacer()
                if !model.batches.isEmpty { Text("\(model.batches.count) 批").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).frame(height: 44)
            Divider()
            if model.batches.isEmpty {
                Text("还没有整理记录").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.batches) { plan in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plan.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.callout.weight(.medium))
                                    Text(detail(plan)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 6)
                                Button("撤销") { Task { await model.undo(plan) } }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .disabled(model.isRunning)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 160, idealHeight: 260, maxHeight: 320)
        .appSurface()
    }

    private func detail(_ plan: ArchiveAIPlan) -> String {
        let files = plan.files.filter { $0.status == .complete }
        let renamed = files.filter { $0.source.deletingLastPathComponent() == $0.destination.deletingLastPathComponent() }
        let created = plan.directories.filter { $0.action == .create && $0.status == .complete }.count
        let folders = plan.directories.filter { $0.action == .move && $0.status == .complete }.count
        var parts: [String] = []
        if let only = files.first, files.count == 1 {
            parts.append(renamed.count == 1 ? "改名：\(only.source.lastPathComponent) → \(only.destination.lastPathComponent)"
                         : "移动：\(only.source.lastPathComponent) → \(only.destination.deletingLastPathComponent().lastPathComponent)")
        } else {
            if renamed.count > 0 { parts.append("改名 \(renamed.count) 个文件") }
            if files.count > renamed.count { parts.append("移动 \(files.count - renamed.count) 个文件") }
        }
        if folders > 0 { parts.append("调整 \(folders) 个文件夹") }
        if created > 0 { parts.append("新建 \(created) 个文件夹") }
        return parts.isEmpty ? "没有可撤销的更改" : parts.joined(separator: "，")
    }
}

// MARK: - Convention

/// Shown in the details column while nothing is selected: the convention in effect and what the last consistency
/// check found.
private struct ArchiveConsistencyView: View {
    @ObservedObject var model: ArchiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("点击左侧的文件或文件夹，查看它的基本信息、AI 摘要和这次的改动").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("整理规范").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(model.convention.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("一致性自检").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let report = model.state.consistency {
                    Label(report.summary, systemImage: report.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(report.isClean ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(report.issues.prefix(8)) { issue in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(issue.path).font(.caption.weight(.medium)).textSelection(.enabled)
                            Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if report.issues.count + report.omittedFileIssues > 8 {
                        Text("还有 \(report.issues.count + report.omittedFileIssues - 8) 项").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("检查于 " + report.checkedAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("整理完成后会自动检查目录与命名是否符合规范").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let audit = model.state.audit, audit.status == .failed {
                Label("结构审计未完成：\(audit.message ?? "模型没有回应")", systemImage: "exclamationmark.octagon")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The user's preference in plain words, read as overrides of the convention. Only what the convention offers is
/// taken from it; the parsed result is shown before saving.
private struct ArchiveConventionSheet: View {
    @ObservedObject var model: ArchiveViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("整理规范").font(.title3.weight(.semibold))
            Text("所有整理步骤都遵循同一套目录与命名规范。可以用一句话调整：类别名用中文或英文、文件名中的词用 - 还是空格连接、按类别还是按项目整理、混合文件夹的阈值，或某个类别的名称（如“图片叫相册”）。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 90)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator))
            VStack(alignment: .leading, spacing: 4) {
                Text("将采用").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(ArchiveConvention.parse(preference: draft).summary).font(.callout)
            }
            HStack {
                Button("恢复默认") { draft = ArchiveConvention.defaultPreference }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存并重新审计") {
                    Task { await model.setPreference(draft) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { draft = model.preference }
    }
}

// MARK: - Shared pieces

/// Determinate once the folder size is known, indeterminate before; always shows elapsed time so a
/// long model call never looks frozen.
private struct ArchiveRunProgressBar: View {
    let progress: ArchiveRunProgress?
    let detail: String?
    let startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView(value: nil as Double?)
                }
            }
            .progressViewStyle(.linear)
            .tint(Color.accentColor)
            .animation(.easeInOut(duration: 0.4), value: progress?.fraction)
            HStack(spacing: 6) {
                if let detail {
                    Text(detail).contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                if let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(elapsed(from: startedAt, to: context.date)).monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: 480)
        .accessibilityElement(children: .combine)
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 3_600 ? String(format: "%d:%02d", seconds / 60, seconds % 60)
            : String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
    }
}

private struct CardHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            AppIconTile(symbol: symbol, size: 64)
            Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 18 : 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(current + 1) 步，共 \(count) 步")
    }
}
