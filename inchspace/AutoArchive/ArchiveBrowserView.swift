import SwiftUI
import UniformTypeIdentifiers

/// The workspace as Finder shows it: one folder at a time, in a list or as icons, every file and folder with a
/// badge for where autopilot stands with it. A filter or a search lists matching files from all folders.
struct ArchiveBrowserPanel: View {
    @ObservedObject var model: ArchiveViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            scopeBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appSurface()
    }

    private var items: [ArchiveBrowserItem] { model.isBrowsing ? model.browserItems : model.resultItems }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ControlGroup {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack || !model.isBrowsing).help("返回")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward || !model.isBrowsing).help("前进")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            pathBar
            Spacer(minLength: 8)
            Picker("显示方式", selection: $model.browserLayout) {
                Image(systemName: "list.bullet").tag(ArchiveBrowserLayout.list).help("列表")
                Image(systemName: "square.grid.2x2").tag(ArchiveBrowserLayout.icons).help("图标")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索所有文件", text: $model.searchText).textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10).frame(width: 200, height: 26)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
        }
        .padding(.horizontal, 12).frame(height: 46)
    }

    /// The folder's place in the workspace; each part goes back up to that folder.
    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if model.isBrowsing {
                    let trail = model.browserTrail
                    ForEach(Array(trail.enumerated()), id: \.offset) { index, part in
                        if index > 0 { Image(systemName: "chevron.compact.right").font(.caption).foregroundStyle(.tertiary) }
                        Button { model.showFolder(part.folder) } label: {
                            Label(part.name, systemImage: index == 0 ? "house" : "folder.fill")
                                .labelStyle(.titleAndIcon).lineLimit(1)
                                .font(index == trail.count - 1 ? .callout.weight(.semibold) : .callout)
                                .foregroundStyle(index == trail.count - 1 ? .primary : .secondary)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Label(model.searchText.isEmpty ? "筛选：\(model.filter.title)" : "搜索“\(model.searchText)”",
                          systemImage: "line.3.horizontal.decrease.circle")
                        .font(.callout.weight(.semibold)).lineLimit(1)
                }
            }
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 12) {
            Picker("筛选", selection: $model.filter) {
                ForEach(ArchiveEntryFilter.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 8)
            ArchiveBadgeLegend()
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(.ultraThinMaterial.opacity(0.4))
    }

    @ViewBuilder private var content: some View {
        let rows = items
        if rows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: model.isBrowsing ? "folder" : "doc.text.magnifyingglass")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text(emptyText).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            switch model.browserLayout {
            case .list: ArchiveBrowserTable(model: model, items: rows, showsFolder: !model.isBrowsing)
            case .icons: ArchiveBrowserGrid(model: model, items: rows)
            }
        }
    }

    private var emptyText: String {
        if model.isBrowsing { return "此文件夹为空" }
        if model.filter == .live { return model.isRunning ? "正在查找需要整理的文件…" : "本次还没有处理文件" }
        return "没有符合条件的文件"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(items.count) 项").font(.caption).foregroundStyle(.secondary)
            if model.isBrowsing, let stats = model.browserFolderStats, stats.total > 0 {
                Text("此文件夹下 " + stats.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !model.isRunning, model.entries.contains(where: \.isLive) {
                Button("清除本次状态") { model.clearFileActivity() }.buttonStyle(.borderless).font(.caption)
                    .help("只清除“本次”标记，处理记录仍然保留")
            }
        }
        .padding(.horizontal, 14).frame(height: 28)
        .background(.ultraThinMaterial.opacity(0.36))
    }
}

private struct ArchiveBrowserTable: View {
    @ObservedObject var model: ArchiveViewModel
    let items: [ArchiveBrowserItem]
    let showsFolder: Bool
    @State private var sortOrder = [KeyPathComparator(\ArchiveBrowserItem.name, comparator: .localizedStandard)]

    var body: some View {
        Table(items.sorted(using: sortOrder), selection: $model.selectedPath, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 8) {
                    ArchiveItemIcon(item: item, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        if showsFolder {
                            Text(item.folder.isEmpty ? "工作区根目录" : item.folder)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .help(item.path)
            }
            .width(min: 200, ideal: 340)
            TableColumn("整理状态", value: \.sortStatus) { item in ArchiveStatusCell(item: item) }
                .width(min: 150, ideal: 260)
            TableColumn("主题", value: \.sortTopic) { item in
                Text(item.entry?.topic ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 50, ideal: 90)
            TableColumn("大小", value: \.sortSize) { item in
                Text(item.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 56, ideal: 76)
            TableColumn("种类", value: \.sortKind) { item in Text(item.kind).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 60, ideal: 110)
            TableColumn("修改日期", value: \.sortModified) { item in
                Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "--").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 100, ideal: 150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { paths in
            if let item = paths.first.flatMap({ path in items.first { $0.path == path } }) {
                ArchiveItemMenu(model: model, item: item, inResults: showsFolder)
            }
        } primaryAction: { paths in
            if let item = paths.first.flatMap({ path in items.first { $0.path == path } }) { model.open(item) }
        }
    }
}

private struct ArchiveBrowserGrid: View {
    @ObservedObject var model: ArchiveViewModel
    let items: [ArchiveBrowserItem]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 128), spacing: 6)], spacing: 10) {
                ForEach(items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { item in
                    ArchiveIconCell(item: item, selected: model.selectedPath == item.path)
                        .onTapGesture(count: 2) { model.open(item) }
                        .onTapGesture { model.selectedPath = item.path }
                        .contextMenu { ArchiveItemMenu(model: model, item: item, inResults: !model.isBrowsing) }
                }
            }
            .padding(14)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedPath = nil }
    }
}

private struct ArchiveIconCell: View {
    let item: ArchiveBrowserItem
    let selected: Bool

    var body: some View {
        let status = ArchiveItemStatus(item)
        VStack(spacing: 5) {
            ArchiveItemIcon(item: item, size: 56)
                .padding(6)
                .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(item.name)
                .font(.caption).multilineTextAlignment(.center).lineLimit(2).truncationMode(.middle)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .foregroundStyle(selected ? Color.white : .primary)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(status.title).font(.caption2).foregroundStyle(status.color).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help(item.path)
        .accessibilityElement(children: .combine)
    }
}

private struct ArchiveItemMenu: View {
    @ObservedObject var model: ArchiveViewModel
    let item: ArchiveBrowserItem
    let inResults: Bool

    var body: some View {
        Button(item.isDirectory ? "打开文件夹" : "打开") { model.open(item) }
        if inResults { Button("在所在文件夹中显示") { model.showInBrowser(item) } }
        Button("在访达中显示") { model.reveal(item.url) }
        if let entry = item.entry, model.undoableOperation(for: entry) != nil {
            Divider()
            Button("撤销此文件") { Task { await model.undoFile(entry) } }.disabled(model.isRunning)
        }
    }
}

/// Finder's own icon for the file type, with a small badge in the corner for autopilot's status.
struct ArchiveItemIcon: View {
    let item: ArchiveBrowserItem
    let size: CGFloat

    var body: some View {
        Image(nsImage: ArchiveIconCache.icon(for: item))
            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .opacity(item.entry?.status == .queued ? 0.6 : 1)
            .overlay(alignment: .bottomTrailing) {
                if item.status != nil {
                    ArchiveStatusBadge(status: ArchiveItemStatus(item), size: max(10, size * 0.42))
                        .offset(x: size * 0.1, y: size * 0.06)
                }
            }
    }
}

private enum ArchiveIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for item: ArchiveBrowserItem) -> NSImage {
        let key = item.isDirectory ? "/folder" : (item.name as NSString).pathExtension.lowercased()
        if let icon = icons[key] { return icon }
        let icon = item.isDirectory ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        icons[key] = icon
        return icon
    }
}

private struct ArchiveStatusBadge: View {
    let status: ArchiveItemStatus
    let size: CGFloat

    var body: some View {
        Image(systemName: status.badge)
            .font(.system(size: size * 0.56, weight: .bold))
            .foregroundStyle(.white)
            .symbolEffect(.rotate, isActive: status.isWorking)
            .frame(width: size, height: size)
            .background(status.color, in: Circle())
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: max(1, size * 0.1)))
            .accessibilityLabel(status.title)
    }
}

/// What the badge and the status column say about one row.
struct ArchiveItemStatus {
    var title: String
    var detail: String?
    var color: Color
    var badge: String
    var isWorking = false

    init(_ item: ArchiveBrowserItem) {
        if item.isDirectory {
            let stats = item.stats ?? ArchiveFolderStats()
            switch stats.headline {
            case .processing: self.init("处理中", stats.summary, .accentColor, "arrow.trianglehead.2.clockwise", working: true)
            case .failed, .skipped: self.init("有失败", stats.summary, .red, "exclamationmark")
            case .unplaced: self.init("有未归位", stats.summary, .yellow, "questionmark")
            case .queued: self.init("等待中", stats.summary, .gray, "clock")
            case .completed: self.init("已整理", stats.summary, .green, "checkmark")
            case nil: self.init("未整理", nil, .secondary, "circle")
            }
            return
        }
        guard let entry = item.entry else {
            self.init("未整理", "下次运行时处理", .secondary, "circle")
            return
        }
        switch entry.status {
        case .processing: self.init("处理中", entry.detail, .accentColor, "arrow.trianglehead.2.clockwise", working: true)
        case .queued: self.init("等待中", entry.detail, .gray, "clock")
        case .failed: self.init("失败", entry.detail, .red, "exclamationmark")
        case .skipped: self.init("未识别", "留在原处", .orange, "exclamationmark")
        case .unplaced: self.init("未归位", "暂无合适的文件夹", .yellow, "questionmark")
        case .completed:
            switch entry.change {
            case .movedAndRenamed(let fromFolder, _, let fromName, _):
                self.init("已移动并改名", "从 \(Self.folderName(fromFolder))，原名 \(fromName)", .purple, "arrow.right")
            case .moved(let from, _):
                self.init("已移动", "从 \(Self.folderName(from)) 移入", .purple, "arrow.right")
            case .renamed(let from, _):
                self.init("已改名", "原名 \(from)", .blue, "pencil")
            case .none:
                self.init("已整理", "保持不变", .green, "checkmark")
            }
        }
    }

    private init(_ title: String, _ detail: String?, _ color: Color, _ badge: String, working: Bool = false) {
        self.title = title
        self.detail = detail
        self.color = color
        self.badge = badge
        isWorking = working
    }

    private static func folderName(_ folder: String) -> String { folder.isEmpty ? "工作区根目录" : folder }
}

private struct ArchiveStatusCell: View {
    let item: ArchiveBrowserItem

    var body: some View {
        let status = ArchiveItemStatus(item)
        HStack(spacing: 6) {
            if status.isWorking { ProgressView().controlSize(.mini) }
            Text(status.title).fontWeight(.medium).foregroundStyle(status.color)
            if let detail = status.detail, !detail.isEmpty {
                Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .lineLimit(1)
        .help(status.detail ?? status.title)
    }
}

private struct ArchiveBadgeLegend: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                item("已整理", .green, "checkmark")
                item("已移动", .purple, "arrow.right")
                item("已改名", .blue, "pencil")
                item("未归位", .yellow, "questionmark")
                item("失败", .red, "exclamationmark")
                item("处理中", .accentColor, "arrow.trianglehead.2.clockwise")
            }
            EmptyView()
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func item(_ title: String, _ color: Color, _ symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 6, weight: .bold)).foregroundStyle(.white)
                .frame(width: 11, height: 11).background(color, in: Circle())
            Text(title)
        }
    }
}
