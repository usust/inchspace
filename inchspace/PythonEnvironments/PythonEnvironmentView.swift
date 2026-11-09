import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PythonEnvironmentView: View {
    @ObservedObject var store: PythonEnvironmentStore
    let terminalManager: TerminalManager
    @State private var selection: UUID?
    @State private var search = ""
    @State private var editor: PythonEnvironmentEditorMode?
    @State private var packagesEnvironment: PythonEnvironment?
    @State private var scriptEnvironment: PythonEnvironment?
    @State private var removingEnvironment: PythonEnvironment?
    @State private var discovered: [PythonEnvironment] = []
    @State private var showsDiscovery = false
    @State private var discovering = false
    @State private var opening = false
    @State private var notice: String?
    @State private var errorMessage: String?

    private var filtered: [PythonEnvironment] {
        store.environments.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)
        }
    }

    private var selected: PythonEnvironment? { store.environments.first { $0.id == selection } }

    var body: some View {
        GeometryReader { page in
            pageContent
                .frame(width: page.size.width, height: page.size.height, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if selection == nil { selection = store.environments.first?.id } }
        .onChange(of: store.environments) { _, environments in
            if !environments.contains(where: { $0.id == selection }) { selection = environments.first?.id }
        }
        .sheet(item: $editor) { mode in
            PythonEnvironmentEditor(mode: mode) { environment in
                try store.save(environment)
                selection = environment.id
            }
        }
        .sheet(item: $packagesEnvironment) { PythonPackagesView(environment: $0) }
        .sheet(item: $scriptEnvironment) { environment in
            PythonScriptSheet(environment: environment) { command, target in
                open(environment, target: target, scriptCommand: command)
            }
        }
        .sheet(isPresented: $showsDiscovery) {
            PythonDiscoverySheet(environments: discovered, existing: store.environments) { environment in
                try store.save(environment)
                selection = environment.id
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("从列表移除环境？", isPresented: Binding(get: { removingEnvironment != nil }, set: { if !$0 { removingEnvironment = nil } }), titleVisibility: .visible) {
            Button("移除记录", role: .destructive) {
                guard let environment = removingEnvironment else { return }
                do { try store.remove(environment) } catch { errorMessage = error.localizedDescription }
                removingEnvironment = nil
            }
            Button("取消", role: .cancel) { removingEnvironment = nil }
        } message: { Text("只移除登记信息，不删除环境目录、已安装模块或项目文件。已经打开的终端不受影响。") }
    }

    private var pageContent: some View {
        VStack(spacing: 0) {
            header
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice {
                HStack {
                    Text(notice).font(.callout)
                    Spacer()
                    Button("关闭", systemImage: "xmark") { self.notice = nil }.labelStyle(.iconOnly)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.08))
            }
            if store.environments.isEmpty {
                ContentUnavailableView {
                    Label("添加你的第一个 Python 环境", systemImage: "terminal")
                } description: {
                    Text("登记已有的 venv、virtualenv 或 uv 虚拟环境。之后一键进入项目，无需重复激活。")
                } actions: {
                    Button("添加已有环境") { editor = .add }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PythonEnvironmentColumns {
                    environmentList
                } detail: {
                    environmentDetail
                }
            }
        }
    }

    @ViewBuilder
    private var environmentDetail: some View {
        if let selected {
            PythonEnvironmentDetailView(
                environment: selected,
                opening: opening,
                onOpen: { open(selected, target: $0) },
                onCopy: { copyActivation(selected) },
                onEdit: { editor = .edit(selected) },
                onPackages: { packagesEnvironment = selected },
                onScript: { scriptEnvironment = selected },
                onRemove: { removingEnvironment = selected }
            )
            .id("\(selected.id)-\(selected.path)-\(selected.workingDirectory)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("选择一个环境", systemImage: "terminal", description: Text("查看环境信息，或打开已激活的终端。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        PythonEnvironmentHeader(discovering: discovering, onDiscover: discover,
                                onAdd: { editor = .add }, onCreate: { editor = .create })
    }

    private var environmentList: some View {
        VStack(spacing: 0) {
            TextField("搜索名称或路径", text: $search)
                .textFieldStyle(.roundedBorder).padding(12)
            List(selection: $selection) {
                ForEach(filtered) { environment in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(environment.name, systemImage: "terminal").font(.headline)
                        Text(environment.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.vertical, 6).tag(environment.id)
                }
            }
            .listStyle(.sidebar)
            if filtered.isEmpty { Text("没有匹配的环境").foregroundStyle(.secondary).padding() }
        }
    }

    private func copyActivation(_ environment: PythonEnvironment) {
        do {
            let command = try PythonEnvironmentService.activationCommand(for: environment)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            notice = "已复制激活命令，可粘贴到 zsh 或 bash 终端。"
        } catch { errorMessage = error.localizedDescription }
    }

    private func open(_ environment: PythonEnvironment, target: PythonTerminalTarget, scriptCommand: String? = nil) {
        opening = true
        Task { @MainActor in
            defer { opening = false }
            do {
                if target == .builtIn {
                    _ = try terminalManager.openPythonSession(environment, scriptCommand: scriptCommand)
                    NotificationCenter.default.post(name: .inchspaceSelectTerminal, object: nil)
                } else {
                    try await PythonSystemTerminal.open(environment, scriptCommand: scriptCommand)
                    notice = "已请求系统终端打开环境，激活结果会显示在新终端中。"
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func discover() {
        let panel = NSOpenPanel()
        panel.title = "选择要扫描的项目目录"
        panel.message = "只扫描所选目录内有限层级的虚拟环境，不执行发现的 Python 或激活脚本。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let root = panel.url else { return }
        discovering = true
        Task { @MainActor in
            defer { discovering = false }
            do {
                discovered = try await PythonEnvironmentService.discover(in: root)
                showsDiscovery = true
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

enum PythonEnvironmentLayout {
    static let listMinimumWidth: CGFloat = 190
    static let listMaximumWidth: CGFloat = 320
    static let detailMinimumWidth: CGFloat = 320

    static func listWidth(preferred: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let maximum = min(listMaximumWidth, max(listMinimumWidth, availableWidth - detailMinimumWidth - 1))
        return min(maximum, max(listMinimumWidth, preferred))
    }
}

struct PythonEnvironmentColumns<Browser: View, Detail: View>: View {
    @ViewBuilder var browser: () -> Browser
    @ViewBuilder var detail: () -> Detail

    @State private var browserWidth: CGFloat = 230
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = PythonEnvironmentLayout.listWidth(preferred: browserWidth, availableWidth: geometry.size.width)
            HStack(spacing: 0) {
                browser()
                    .frame(width: width)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .overlay {
                        Color.clear.frame(width: 9)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(coordinateSpace: .named("pythonEnvironmentColumns")).onChanged { value in
                                let start = dragStartWidth ?? width
                                dragStartWidth = start
                                browserWidth = PythonEnvironmentLayout.listWidth(
                                    preferred: start + value.translation.width, availableWidth: geometry.size.width
                                )
                            }.onEnded { _ in dragStartWidth = nil })
                    }
                    .accessibilityLabel("环境列表宽度")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            browserWidth = PythonEnvironmentLayout.listWidth(preferred: width + 10, availableWidth: geometry.size.width)
                        case .decrement:
                            browserWidth = PythonEnvironmentLayout.listWidth(preferred: width - 10, availableWidth: geometry.size.width)
                        @unknown default: break
                        }
                    }
                detail()
                    .frame(width: max(0, geometry.size.width - width - 1))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "pythonEnvironmentColumns")
        }
    }
}

struct PythonEnvironmentHeader: View {
    let discovering: Bool
    let onDiscover: () -> Void
    let onAdd: () -> Void
    let onCreate: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppLayout.featureHeaderSpacing) {
                title
                Spacer(minLength: 12)
                HStack(spacing: 12) { actions }
            }
            VStack(alignment: .leading, spacing: 12) {
                title
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appFeatureHeaderBackground()
    }

    private var title: some View {
        AppFeatureTitle("Python 环境", subtitle: "独立环境，一键进入项目")
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var actions: some View {
        if discovering { ProgressView().controlSize(.small) }
        Button("发现环境", systemImage: "magnifyingglass", action: onDiscover).disabled(discovering)
        Button("添加已有", systemImage: "folder.badge.plus", action: onAdd)
        Button("新建环境", systemImage: "plus", action: onCreate).buttonStyle(.borderedProminent)
    }
}

struct PythonEnvironmentDetailView: View {
    let environment: PythonEnvironment
    let opening: Bool
    let onOpen: (PythonTerminalTarget) -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onPackages: () -> Void
    let onScript: () -> Void
    let onRemove: () -> Void
    @State private var inspection: PythonEnvironmentInspection?
    @State private var issue: String?
    @State private var inspecting = true

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                detailContent
                    .frame(width: max(0, viewport.size.width - 48), alignment: .leading)
                    .padding(24)
            }
        }
        .task {
            inspecting = true
            inspection = nil
            issue = nil
            do {
                let value = try await PythonEnvironmentService.inspect(environment)
                guard !Task.isCancelled else { return }
                inspection = value
            } catch {
                guard !Task.isCancelled else { return }
                issue = error.localizedDescription
            }
            inspecting = false
        }
    }

    private var detailContent: some View {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(environment.name).font(.title2.bold()).textSelection(.enabled)
                        if inspecting {
                            HStack { ProgressView().controlSize(.small); Text("正在检查环境…") }.foregroundStyle(.secondary)
                        } else if let inspection {
                            Label("\(inspection.kind) · Python \(inspection.version)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            Label("环境需要检查", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                }
                if let issue {
                    Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 16) {
                    pathRow("环境目录", value: environment.path)
                    pathRow("Python", value: environment.pythonPath)
                    pathRow("工作目录", value: environment.workingDirectory)
                    pathRow("默认终端", value: environment.terminalTarget.title)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { launchButtons }
                    VStack(alignment: .leading, spacing: 10) { launchButtons }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("激活命令").font(.headline)
                    Text((try? PythonEnvironmentService.activationCommand(for: environment)) ?? "环境路径无效，请编辑后重试。")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    Text("适用于 zsh / bash，只激活环境，不改变当前目录。只影响粘贴命令的终端会话，不修改全局配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Button(action: onPackages) {
                    HStack {
                        Image(systemName: "shippingbox")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已安装模块").font(.headline)
                            Text("查看当前环境可用的第三方包及版本").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        managementButtons
                        Spacer(minLength: 12)
                        Button("移除记录", role: .destructive, action: onRemove)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        managementButtons
                        Button("移除记录", role: .destructive, action: onRemove)
                    }
                }
                Text("Python 终端以独立的干净 Shell 启动，不加载个人启动脚本。支持 zsh / bash；不会影响其他终端的环境。")
                    .font(.caption).foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var managementButtons: some View {
        Button("编辑", systemImage: "pencil", action: onEdit)
        Button("在 Finder 中显示", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: environment.path)])
        }
    }

    private var launchButtons: some View {
        Group {
            HStack(spacing: 0) {
                Button("打开终端", systemImage: "terminal") { onOpen(environment.terminalTarget) }
                    .buttonStyle(.borderedProminent)
                Menu {
                    Button("在内置终端打开") { onOpen(.builtIn) }
                    Button("在系统终端打开") { onOpen(.system) }
                } label: { Image(systemName: "chevron.down") }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton).frame(width: 26).help("选择终端")
            }.disabled(opening)
            Button("运行脚本", systemImage: "play", action: onScript).disabled(opening)
            Button("复制激活命令", systemImage: "doc.on.doc", action: onCopy)
        }
    }

    private func pathRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
