import AppKit
import SwiftUI

struct EnvironmentVariableView: View {
    @StateObject private var model: EnvironmentVariableViewModel
    private let terminalManager: TerminalManager
    @FocusState private var searchFocused: Bool
    @AppStorage("environment.nameColumnWidth") private var nameColumnWidth = EnvironmentTableColumnLayout.defaultNameWidth
    @State private var nameColumnDragStartWidth: CGFloat?
    @State private var isNameColumnHandleHovered = false

    init(service: EnvironmentVariableService, terminalManager: TerminalManager) {
        self.terminalManager = terminalManager
        _model = StateObject(wrappedValue: EnvironmentVariableViewModel(
            service: service,
            terminalManager: terminalManager
        ))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                toolbar
                if let issue = model.scanIssues.first { issueBanner(issue) }
                content
            }
            keyboardActions
            if let toast = model.toast { toastView(toast).transition(.opacity.combined(with: .scale(scale: 0.96))) }
        }
        .task { model.load() }
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .sheet(isPresented: $model.showsEditor) {
            EnvironmentEditorView(
                variable: model.editingVariable,
                source: model.editingSource,
                service: model.service
            ) { name, value, destination, exportToPath in
                model.save(name: name, value: value, destination: destination, exportToPath: exportToPath)
            }
        }
        .sheet(item: $model.selectedVariable) { variable in
            EnvironmentDetailView(
                variable: variable,
                editableSources: model.editableSources(for: variable),
                onEdit: { model.edit(variable, source: $0) },
                onCopy: model.copy,
                onReveal: model.reveal
            )
        }
        .sheet(isPresented: $model.showsPathManager) {
            if let source = model.pathSource {
                EnvironmentPathManagerView(service: model.service, source: source) {
                    let sourced = source.fileURL.map(terminalManager.sourceEnvironmentFile) ?? false
                    model.load()
                    model.showToast(sourced ? "PATH 已更新并在当前终端重新加载" : "PATH 已更新")
                }
            }
        }
        .alert(item: $model.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("好")))
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            deletionActions
        } message: {
            Text(deletionMessage)
        }
        .onDeleteCommand {
            if let id = model.selectedRowID,
               let variable = model.variables.first(where: { $0.id == id }),
               !model.editableSources(for: variable).isEmpty { model.pendingDeletion = variable }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("环境变量").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("管理本机开发环境变量").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 18)
            Picker("来源", selection: $model.sourceFilter) {
                ForEach(model.sourceFilters) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 142)
            .help("按环境变量来源过滤")
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索环境变量", text: $model.searchText)
                    .textFieldStyle(.plain).focused($searchFocused)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11).frame(width: 245, height: 36)
            .environmentGlass(cornerRadius: 11, shadow: false)

            Button("重新加载", systemImage: "arrow.clockwise") { model.reload() }
                .buttonStyle(.bordered)
            Button("新建变量", systemImage: "plus") { model.newVariable() }
                .buttonStyle(.borderedProminent)
            Menu {
                Button("刷新", systemImage: "arrow.clockwise") { model.reload() }
                Button("复制重新加载命令", systemImage: "doc.on.doc") { model.copy("source ~/.zprofile") }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton).help("更多操作")
        }
        .padding(.horizontal, 24).padding(.vertical, 15)
        .background(.ultraThinMaterial.opacity(0.54))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 1) }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            VStack(spacing: 12) { ProgressView(); Text("正在读取 Shell 配置…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredVariables.isEmpty {
            ContentUnavailableView {
                Label(model.searchText.isEmpty ? "尚未添加自定义环境变量" : "没有匹配的环境变量", systemImage: "curlybraces")
            } description: {
                Text(model.searchText.isEmpty ? "在这里统一管理 Java、Android、Go 等开发环境变量。" : "请尝试其他名称、值或来源。")
            } actions: {
                if model.searchText.isEmpty { Button("新建变量", systemImage: "plus") { model.newVariable() } }
            }
        } else {
            GeometryReader { proxy in
                let resolvedNameWidth = EnvironmentTableColumnLayout.nameWidth(
                    nameColumnWidth,
                    availableWidth: proxy.size.width
                )

                VStack(spacing: 0) {
                    listHeader(nameWidth: resolvedNameWidth, availableWidth: proxy.size.width)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.filteredVariables) { variable in
                                variableRow(variable, nameWidth: resolvedNameWidth)
                                if variable.id != model.filteredVariables.last?.id { Divider().padding(.leading, 30) }
                            }
                        }
                    }
                    HStack {
                        Text("\(model.filteredVariables.count) 个变量").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("保存后：App 新工具立即生效 · 新终端自动生效")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 18).frame(height: 36).background(.ultraThinMaterial.opacity(0.36))
                }
            }
            .padding(20)
        }
    }

    private func listHeader(nameWidth: CGFloat, availableWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            Text("名称").frame(width: nameWidth, alignment: .leading)
            Text("值").frame(maxWidth: .infinity, alignment: .leading)
            Text("来源").frame(width: 125, alignment: .leading)
            Text("状态").frame(width: 86, alignment: .leading)
            Color.clear.frame(width: 20)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 36)
        .background(.ultraThinMaterial.opacity(0.5))
        .overlay(alignment: .leading) {
            nameColumnResizeHandle(nameWidth: nameWidth, availableWidth: availableWidth)
                .offset(x: EnvironmentTableColumnLayout.horizontalPadding + nameWidth)
        }
    }

    private func nameColumnResizeHandle(nameWidth: CGFloat, availableWidth: CGFloat) -> some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.accentColor.opacity(
                    nameColumnDragStartWidth != nil ? 0.85 : (isNameColumnHandleHovered ? 0.55 : 0.16)
                ))
                .frame(width: 2, height: 22)
        }
        .frame(width: EnvironmentTableColumnLayout.intercolumnSpacing, height: 36)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isNameColumnHandleHovered = true
                NSCursor.resizeLeftRight.set()
            case .ended:
                isNameColumnHandleHovered = false
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let startWidth = nameColumnDragStartWidth ?? nameWidth
                    if nameColumnDragStartWidth == nil { nameColumnDragStartWidth = startWidth }
                    nameColumnWidth = EnvironmentTableColumnLayout.nameWidth(
                        startWidth + value.translation.width,
                        availableWidth: availableWidth
                    )
                }
                .onEnded { _ in nameColumnDragStartWidth = nil }
        )
        .onTapGesture(count: 2) {
            nameColumnWidth = EnvironmentTableColumnLayout.nameWidth(
                EnvironmentTableColumnLayout.defaultNameWidth,
                availableWidth: availableWidth
            )
        }
        .help("拖动调整名称列宽；双击恢复默认宽度")
        .accessibilityLabel("名称列宽")
        .accessibilityValue("\(Int(nameWidth)) 点")
        .accessibilityAdjustableAction { direction in
            let offset: CGFloat = direction == .increment ? 20 : -20
            nameColumnWidth = EnvironmentTableColumnLayout.nameWidth(
                nameWidth + offset,
                availableWidth: availableWidth
            )
        }
    }

    private func variableRow(_ variable: EnvironmentVariable, nameWidth: CGFloat) -> some View {
        Button { model.open(variable) } label: {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: variable.variableType == .path ? "point.3.connected.trianglepath.dotted" : "curlybraces")
                        .foregroundStyle(Color.accentColor).frame(width: 18)
                    Text(variable.name).font(.system(.body, design: .monospaced).weight(.medium)).lineLimit(1)
                }.frame(width: nameWidth, alignment: .leading)
                Text(displayValue(for: variable))
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(model.displayedValue(for: variable))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(model.displayedSourceSummary(for: variable)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 125, alignment: .leading)
                statusLabel(model.displayedStatus(for: variable)).frame(width: 86, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 20)
            }
            .padding(.horizontal, 14).frame(height: 48).contentShape(Rectangle())
        }
        .buttonStyle(EnvironmentRowButtonStyle())
        .background(model.selectedRowID == variable.id ? Color.accentColor.opacity(0.08) : Color.clear)
        .contextMenu { contextMenu(for: variable) }
    }

    @ViewBuilder
    private func statusLabel(_ status: EnvironmentVariableStatus) -> some View {
        switch status {
        case .valid: Label("有效", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .disabled: Label("已禁用", systemImage: "pause.circle.fill").foregroundStyle(.orange)
        case .readOnly: Label("只读", systemImage: "lock.fill").foregroundStyle(.secondary)
        case .exportedToPath: Label("已加入 PATH", systemImage: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
        case .missingDirectory: Label("不存在", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unavailable: Label("无值", systemImage: "minus.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func contextMenu(for variable: EnvironmentVariable) -> some View {
        let sources = model.editableSources(for: variable)
        if sources.count == 1, let source = sources.first {
            if source.isEnabled {
                Button("编辑", systemImage: "pencil") { model.edit(variable, source: source) }
                Button("禁用", systemImage: "pause.circle") { model.setEnabled(false, variable: variable, source: source) }
            } else {
                Button("启用", systemImage: "play.circle") { model.setEnabled(true, variable: variable, source: source) }
            }
        } else if sources.count > 1 {
            Menu("按来源操作", systemImage: "doc.on.doc") {
                ForEach(sources) { source in
                    Menu(source.displayName) {
                        if source.isEnabled {
                            Button("编辑", systemImage: "pencil") { model.edit(variable, source: source) }
                            Button("禁用", systemImage: "pause.circle") { model.setEnabled(false, variable: variable, source: source) }
                        } else {
                            Button("启用", systemImage: "play.circle") { model.setEnabled(true, variable: variable, source: source) }
                        }
                    }
                }
            }
        } else {
            Text("当前 App 来源为只读")
        }
        Divider()
        Button("复制变量名", systemImage: "doc.on.doc") { model.copy(variable.name) }
        Button("复制变量值", systemImage: "doc.on.doc") { model.copy(model.displayedValue(for: variable)) }
        if let source = sources.last?.fileURL {
            Button("在 Finder 中显示来源", systemImage: "folder") { model.reveal(source) }
        }
        if !sources.isEmpty {
            Divider()
            Button("删除", role: .destructive) { model.pendingDeletion = variable }
        }
    }

    private func issueBanner(_ issue: EnvironmentScanIssue) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("~/\(issue.fileURL.lastPathComponent) 读取失败；其他来源仍已正常加载。")
            Spacer()
            Text(issue.message).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.caption).padding(.horizontal, 18).frame(height: 34)
        .background(Color.orange.opacity(0.09))
    }

    private func toastView(_ message: String) -> some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium)).padding(.horizontal, 16).frame(height: 38)
            .environmentGlass(cornerRadius: 12, shadow: true).padding(.top, 82)
    }

    private var keyboardActions: some View {
        VStack {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("") { model.newVariable() }.keyboardShortcut("n", modifiers: .command)
        }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    private func displayValue(for variable: EnvironmentVariable) -> String {
        let value = model.displayedValue(for: variable)
        return variable.variableType == .path
            ? "\(Set(value.split(separator: ":").map(String.init)).count) 个目录"
            : value
    }

    private var deletionTitle: String {
        guard let variable = model.pendingDeletion else { return "删除环境变量？" }
        return "删除 \(variable.name)？"
    }

    private var deletionMessage: String {
        guard let variable = model.pendingDeletion else { return "" }
        let sources = model.editableSources(for: variable)
        return sources.count > 1
            ? "请选择要永久删除的用户文件定义；inchspace 不会创建备份。"
            : "该操作将从 \(sources.first?.displayName ?? "配置文件") 中永久移除此变量，且无法撤销。"
    }

    @ViewBuilder
    private var deletionActions: some View {
        if let variable = model.pendingDeletion {
            let sources = model.editableSources(for: variable)
            ForEach(sources) { source in
                if let url = source.fileURL {
                    Button("删除 \(source.displayName) 中的定义", role: .destructive) { model.delete(variable, sources: [url]) }
                }
            }
            if sources.count > 1 {
                Button("删除全部定义", role: .destructive) { model.delete(variable) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

enum EnvironmentTableColumnLayout {
    static let defaultNameWidth: CGFloat = 220
    static let minimumNameWidth: CGFloat = 120
    static let maximumNameWidth: CGFloat = 420
    static let minimumValueWidth: CGFloat = 160
    static let sourceWidth: CGFloat = 125
    static let statusWidth: CGFloat = 86
    static let disclosureWidth: CGFloat = 20
    static let horizontalPadding: CGFloat = 14
    static let intercolumnSpacing: CGFloat = 12

    static func nameWidth(_ proposedWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let fixedWidth = horizontalPadding * 2
            + intercolumnSpacing * 4
            + minimumValueWidth
            + sourceWidth
            + statusWidth
            + disclosureWidth
        let availableMaximum = max(minimumNameWidth, availableWidth - fixedWidth)
        let maximum = min(maximumNameWidth, availableMaximum)
        return min(max(proposedWidth, minimumNameWidth), maximum)
    }
}

private struct EnvironmentRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.07 : 0.001))
            .scaleEffect(configuration.isPressed ? 0.998 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private extension View {
    func environmentGlass(cornerRadius: CGFloat, shadow: Bool) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.7)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom))
                    }
            }
            .shadow(color: shadow ? .black.opacity(0.12) : .clear, radius: 15, y: 7)
    }
}
