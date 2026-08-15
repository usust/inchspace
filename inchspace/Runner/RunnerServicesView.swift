import SwiftUI

struct RunnerLocalServicesView: View {
    @ObservedObject var store: RunnerStore
    @State private var search = ""
    @State private var pendingAction: PendingServiceAction?
    @State private var logPresentation: ServiceLogPresentation?
    @State private var showsAddService = false

    private var services: [RunnerService] {
        let keywords = search.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard !keywords.isEmpty else { return store.localServices }
        return store.localServices.filter { service in
            let text = [service.serviceName, service.displayName, service.identifier, service.detail ?? ""].joined(separator: " ")
            return keywords.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("本机服务").font(.title2.weight(.semibold))
                    Spacer()
                    TextField("搜索服务", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button("添加服务", systemImage: "plus") { showsAddService = true }
                        .buttonStyle(.borderedProminent)
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refreshLocalServices() } }
                        .buttonStyle(.bordered)
                }

                if services.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "没有发现可管理的服务" : "没有匹配的服务",
                        systemImage: "server.rack"
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .runnerGlassCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                            serviceRow(service)
                            if index < services.count - 1 { Divider().padding(.leading, 62) }
                        }
                    }
                    .padding(.vertical, 5)
                    .runnerGlassCard()
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 26)
        }
        .sheet(isPresented: $showsAddService) { RunnerAddServiceView(store: store) }
        .confirmationDialog(
            pendingAction?.title ?? "确认操作",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(pendingAction.buttonTitle, role: pendingAction.action == .stop ? .destructive : nil) {
                    Task { await store.operateLocalService(pendingAction.service, action: pendingAction.action) }
                    self.pendingAction = nil
                }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction?.service.requiresConfirmation == true
                 ? "这是 macOS 或系统范围的服务，操作可能影响系统功能和其他应用。"
                 : "这可能会影响正在使用该服务的应用。")
        }
        .sheet(item: $logPresentation) { presentation in
            ServiceTextLogView(title: presentation.title, text: presentation.text)
        }
    }

    private func serviceRow(_ service: RunnerService) -> some View {
        HStack(spacing: 14) {
            Image(systemName: service.kind == .homebrew ? "shippingbox" : "gearshape.2")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(runnerStatusColor(service.state))
                .frame(width: 38, height: 38)
                .background(runnerStatusColor(service.state).opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(service.serviceName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .help(service.serviceName)
                Text(service.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .help(service.identifier)
                Text(serviceMetadata(service))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            StatusBadge(state: service.state)
            if store.isManaged(service) {
                Menu {
                    Button("从运行中心移除", systemImage: "minus.circle") {
                        store.removeManagedService(service)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .help("管理选项")
            }
            if store.busyServiceIDs.contains(service.id) {
                ProgressView().controlSize(.small).frame(width: 70)
            } else {
                if service.state == .running {
                    Button("停止") { pendingAction = PendingServiceAction(service: service, action: .stop) }.buttonStyle(.bordered)
                    Button("重启") { pendingAction = PendingServiceAction(service: service, action: .restart) }.buttonStyle(.bordered)
                } else {
                    Button("启动") { Task { await store.operateLocalService(service, action: .start) } }.buttonStyle(.borderedProminent)
                }
                Button("日志") {
                    Task {
                        let text = await store.localServiceLogs(service)
                        logPresentation = ServiceLogPresentation(title: "\(service.serviceName) 日志", text: text)
                    }
                }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 18).frame(minHeight: 78)
    }

    private func serviceMetadata(_ service: RunnerService) -> String {
        var values = [service.kind.title, service.isSystemService ? "系统范围" : "当前用户"]
        if let instanceName = service.instanceName { values.append("运行器：\(instanceName)") }
        if let detail = service.detail, !detail.isEmpty { values.append(detail) }
        return values.joined(separator: "  ·  ")
    }
}

private struct RunnerAddServiceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RunnerStore
    @State private var search = ""
    @State private var manualEntry = ""
    @State private var kind: RunnerServiceKind = .launchd
    @State private var isSystemService = false
    @State private var errorMessage: String?
    @State private var showsManualEntry = false
    @FocusState private var isSearchFocused: Bool

    private var candidates: [RunnerService] {
        let keywords = search
            .split(whereSeparator: \Character.isWhitespace)
            .map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        return store.discoverableLocalServices.filter { service in
            guard !store.isManaged(service) else { return false }
            guard !keywords.isEmpty else { return true }
            let searchableText = [
                service.displayName,
                service.identifier,
                service.detail ?? "",
                service.kind.title,
                service.state.title
            ]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return keywords.allSatisfy(searchableText.contains)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加本机服务").font(.title2.weight(.bold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(22)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("搜索服务，例如 runner、usust、672", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($isSearchFocused)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(Color.accentColor.opacity(isSearchFocused ? 0.65 : 0.18)) }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if candidates.isEmpty {
                            ContentUnavailableView(
                                "没有找到服务",
                                systemImage: "magnifyingglass"
                            )
                            .frame(maxWidth: .infinity, minHeight: 270)
                        }
                        ForEach(candidates) { service in
                            HStack(spacing: 12) {
                                Image(systemName: service.kind == .homebrew ? "shippingbox" : "gearshape.2")
                                    .foregroundStyle(runnerStatusColor(service.state)).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(service.serviceName).font(.subheadline.weight(.medium))
                                    Text(service.identifier)
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text(service.kind.title
                                         + (service.instanceName.map { "  ·  运行器：\($0)" } ?? "")
                                         + (service.detail.map { "  ·  \($0)" } ?? ""))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                StatusBadge(state: service.state)
                                Button("添加") { add(service) }.buttonStyle(.bordered).controlSize(.small)
                            }
                            .padding(.horizontal, 10).frame(minHeight: 66)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))

                DisclosureGroup("找不到服务？按标识高级添加", isExpanded: $showsManualEntry) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("服务标识，例如 actions.runner.example", text: $manualEntry)
                                .textFieldStyle(.roundedBorder)
                            Picker("类型", selection: $kind) {
                                Text("macOS 服务").tag(RunnerServiceKind.launchd)
                                Text("Homebrew").tag(RunnerServiceKind.homebrew)
                            }
                            .labelsHidden().frame(width: 130)
                            Button("添加", action: addManual).buttonStyle(.borderedProminent)
                        }
                        if kind == .launchd {
                            Toggle("系统范围服务", isOn: $isSystemService)
                                .help("普通用户服务请保持关闭。只有 system 域服务才需要开启。")
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.top, 10)
                }
                .font(.subheadline)
            }
            .padding(20)
        }
        .frame(width: 700, height: 650)
        .background(.regularMaterial)
        .task {
            await store.refreshLocalServices()
            isSearchFocused = true
        }
    }

    private func add(_ service: RunnerService) {
        store.addManagedService(RunnerManagedService(
            identifier: service.identifier,
            displayName: service.serviceName,
            kind: service.kind,
            isSystemService: service.isSystemService
        ))
    }

    private func addManual() {
        guard let identifier = RunnerServiceIdentifierParser.parse(manualEntry) else {
            errorMessage = "请输入有效的服务标识，或粘贴 launchctl list 中的一整行。"
            return
        }
        guard kind != .launchd || identifier.contains(".") else {
            errorMessage = "macOS 服务标识通常包含点号。若只知道关键词，请使用上方搜索，不要在这里添加。"
            return
        }
        let displayName = identifier.split(separator: ".").last.map(String.init) ?? identifier
        store.addManagedService(RunnerManagedService(
            identifier: identifier,
            displayName: displayName,
            kind: kind,
            isSystemService: kind == .launchd && isSystemService
        ))
        manualEntry = ""
        errorMessage = nil
    }
}

struct StatusBadge: View {
    let state: RunnerServiceState
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(state.title)
        }
        .font(.caption.weight(.medium)).foregroundStyle(color)
        .padding(.horizontal, 10).frame(height: 25)
        .background(color.opacity(0.1), in: Capsule())
    }
    private var color: Color {
        switch state {
        case .running: .green
        case .failed: .red
        case .stopped: .secondary
        case .unknown: .orange
        }
    }
}

func runnerStatusColor(_ state: RunnerServiceState) -> Color {
    switch state {
    case .running: .green
    case .failed: .red
    case .stopped: .secondary
    case .unknown: .orange
    }
}

private struct PendingServiceAction: Identifiable {
    let id = UUID()
    let service: RunnerService
    let action: RunnerServiceAction
    var title: String { "\(buttonTitle)“\(service.displayName)”？" }
    var buttonTitle: String {
        switch action { case .start: "启动"; case .stop: "停止"; case .restart: "重启" }
    }
}

struct ServiceLogPresentation: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct ServiceTextLogView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline); Spacer(); Button("完成") { dismiss() } }.padding(18)
            Divider()
            ScrollView {
                Text(text.isEmpty ? "暂无日志。" : text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.82))
        }
        .frame(minWidth: 760, minHeight: 520).background(.regularMaterial)
    }
}
