import SwiftUI

struct XenClusterView: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    let back: () -> Void
    @State private var section: XenResourceKind = .pool
    @State private var query = ""
    @State private var selected: XenRecord?
    @State private var resourceHistory: [XenRecord] = []
    @State private var editingConnection = false
    @State private var removing = false
    @State private var showsTasks = false
    @State private var showsNetworkEditor = false
    @State private var showsAlerts = false
    @State private var showsVMWizard = false
    @State private var showsStartDelays = false
    @State private var selectedIDs: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\XenRecord.name)]
    @State private var guestMetrics: [String: XenValue] = [:]
    @State private var batchAction: XenPowerAction?

    init(store: XenStore, cluster: XenCluster, initialSection: XenResourceKind = .pool, back: @escaping () -> Void) {
        self.store = store; self.cluster = cluster; self.back = back
        _section = State(initialValue: initialSection)
    }
    private var state: XenConnectionState { store.state(cluster.id) }
    private var records: [XenRecord] {
        (state.records[section] ?? []).filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.uuid.localizedStandardContains(query) }.sorted(using: sortOrder)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if !state.connected {
                connectionState
            } else {
                navigation
                if let selected {
                    XenResourceDetail(store: store, cluster: cluster, record: selected, back: {
                        self.selected = resourceHistory.popLast()
                    }, openResource: { resource in
                        resourceHistory.append(selected)
                        self.selected = resource
                    })
                        .id(selected.id)
                } else if section == .pool {
                    overview
                } else {
                    resourceList
                }
            }
            activityBar
        }
        .background(AppPageBackground())
        .confirmationDialog("对选中的虚拟机执行操作？", isPresented: Binding(get: { batchAction != nil }, set: { if !$0 { batchAction = nil } })) {
            if let action = batchAction {
                Button("\(action.title)（\(selectedIDs.count) 台）") {
                    let targets = records.filter { selectedIDs.contains($0.id) }
                    batchAction = nil
                    Task {
                        for target in targets {
                            await store.power(cluster.id, record: target, action: action)
                            if store.error != nil { break }
                        }
                    }
                }
            }
        } message: { Text("逐台校验并提交；出现失败或未知结果时停止后续操作。每台虚拟机保留独立任务记录。") }
        .sheet(isPresented: $showsStartDelays) { XenStartDelayEditor(store: store, cluster: cluster) }
        .sheet(isPresented: $showsVMWizard) { XenVMWizard(store: store, cluster: cluster) }
        .sheet(isPresented: $showsAlerts) { XenAlertsView(center: store.alerts) }
        .sheet(isPresented: $showsNetworkEditor) { XenNetworkEditor(store: store, cluster: cluster) }
        .sheet(isPresented: $editingConnection) {
            XenClusterEditor(store: store, cluster: cluster) { _ in }
        }
        .confirmationDialog("移除“\(cluster.name)”？", isPresented: $removing) {
            Button("移除集群", role: .destructive) {
                Task { await store.remove(cluster.id); if !store.clusters.contains(where: { $0.id == cluster.id }) { back() } }
            }
        } message: { Text("仅移除本机连接配置和保存的密码，不修改远端资源。") }
        .task {
            if state.connected && section != .pool {
                await store.refresh(cluster.id, kind: section)
                if section == .vm { guestMetrics = (try? await store.relatedRecords(cluster.id, api: "VM_guest_metrics")) ?? [:] }
            }
        }
        .onChange(of: section) { _, kind in
            selected = nil
            resourceHistory = []
            selectedIDs = []
            Task {
                await store.refresh(cluster.id, kind: kind)
                if kind == .vm { guestMetrics = (try? await store.relatedRecords(cluster.id, api: "VM_guest_metrics")) ?? [:] }
            }
        }
        .onChange(of: records.map(\.id)) { _, ids in selectedIDs.formIntersection(Set(ids)) }
        .onChange(of: state.records) { _, records in
            if let selected, let refreshed = records[selected.kind] {
                self.selected = refreshed.first { $0.id == selected.id }
            }
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Button(action: back) { Label("服务器", systemImage: "chevron.left") }
                .buttonStyle(.plain).buttonBorderShape(.capsule)
            VStack(alignment: .leading, spacing: 3) {
                Text(cluster.name).font(.title3.weight(.semibold))
                Text(state.connected ? "已连接 · \(cluster.address)" : cluster.address)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            if state.loading.contains(section) { ProgressView().controlSize(.small) }
            if state.connected {
                Button { Task { await store.refresh(cluster.id, kind: section) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新当前栏目").disabled(state.loading.contains(section))
            }
            Menu {
                if state.connected {
                    Button("断开连接") { Task { await store.disconnect(cluster.id) } }
                        .disabled(store.hasActiveOperation(cluster.id))
                } else {
                    Button("编辑连接…") { editingConnection = true }.disabled(state.connecting)
                }
                Divider()
                Button("移除集群…", role: .destructive) { removing = true }
                    .disabled(store.hasActiveOperation(cluster.id) || state.connecting)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().buttonStyle(.plain).help("集群操作")
        }
        .modifier(XenToolbarSurface())
    }
    private var navigation: some View {
        HStack(spacing: 12) {
            Picker("资源栏目", selection: $section) {
                ForEach(XenResourceKind.primary) { Text($0.title).tag($0) }
                if !XenResourceKind.primary.contains(section) { Text(section.title).tag(section) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
            Menu {
                ForEach(XenResourceKind.additional) { kind in
                    Button(kind.title, systemImage: kind.symbol) { section = kind }
                }
                Divider()
                Button("告警与规则…", systemImage: "bell.badge") { showsAlerts = true }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
            .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
    private var connectionState: some View {
        ContentUnavailableView {
            Label(state.connecting ? "正在连接集群" : "连接 Xen 集群", systemImage: "square.stack.3d.up")
        } description: {
            Text(state.connectionError ?? "连接后查看资源池、主机与虚拟机。")
        } actions: {
            if state.connecting { ProgressView().controlSize(.small) }
            else {
                Button("连接", systemImage: "bolt") { Task { await store.connect(cluster) } }
                    .buttonStyle(.borderedProminent)
                Button("编辑连接…") { editingConnection = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = state.errors[.pool] { XenInlineError(message: error) }
                HStack(spacing: 0) {
                    summary("主机", value: "\(state.records[.host]?.count ?? 0)", symbol: "server.rack")
                    Divider().frame(height: 44)
                    summary("运行中虚拟机", value: "\(state.records[.vm]?.filter { $0.state == "Running" }.count ?? 0)", symbol: "desktopcomputer")
                    Divider().frame(height: 44)
                    summary("虚拟机", value: "\(state.records[.vm]?.count ?? 0)", symbol: "square.stack")
                    Divider().frame(height: 44)
                    summary("存储仓库", value: "\(state.records[.storage]?.count ?? 0)", symbol: "externaldrive")
                }
                .padding(.vertical, 18)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                if let pool = state.records[.pool]?.first {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(pool.name).font(.headline)
                        if !pool["name_description"].string.isEmpty { Text(pool["name_description"].string).foregroundStyle(.secondary) }
                        LabeledContent("资源池 UUID", value: pool.uuid).textSelection(.enabled)
                        LabeledContent("高可用", value: pool.fields["ha_enabled"] == nil ? "未知" : pool["ha_enabled"].boolean ? "已启用" : "未启用")
                    }
                    .font(.callout)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("主机").font(.headline)
                    if let error = state.errors[.host] { XenInlineError(message: error) }
                    ForEach(state.records[.host] ?? []) { host in
                        HStack {
                            Label(host.name, systemImage: "server.rack")
                            Spacer()
                            Text(host["address"].string).foregroundStyle(.secondary)
                            Text(host["enabled"].boolean ? "已启用" : "已禁用").foregroundStyle(.secondary)
                        }
                        .font(.callout).padding(.vertical, 9)
                        Divider()
                    }
                }
                HStack {
                    Text("更新于").foregroundStyle(.secondary)
                    if let date = state.updatedAt { Text(date, style: .time).foregroundStyle(.secondary) }
                    Spacer()
                    Menu("高级管理") {
                        Button("虚拟机启动延迟…") { showsStartDelays = true }
                        Divider()
                        ForEach([XenProtectedCapability.poolGovernance, .ha, .hostMaintenance]) { capability in
                            Button("\(capability.title) · 暂不可用") {}.disabled(true)
                        }
                    }
                }.font(.caption)
            }
            .padding(24).frame(maxWidth: AppLayout.contentMaxWidth).frame(maxWidth: .infinity)
        }
    }
    private func summary(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
    }
    private var resourceList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(section.title).font(.headline)
                Text("\(records.count)").foregroundStyle(.secondary).font(.callout.monospacedDigit())
                Spacer()
                if section == .vm && !selectedIDs.isEmpty {
                    Menu("批量操作（\(selectedIDs.count)）") {
                        Button("批量删除 · 暂不可用") {}.disabled(true)
                        Divider()
                        ForEach([XenPowerAction.start, .shutdown, .reboot]) { action in
                            Button(action.title) { store.error = nil; batchAction = action }
                                .disabled(records.filter { selectedIDs.contains($0.id) }.contains { !action.available(for: $0) || store.isBusy($0, cluster: cluster.id) })
                        }
                    }
                }
                if section == .vm {
                    Button("创建虚拟机", systemImage: "plus") { showsVMWizard = true }
                }
                if section == .network {
                    Button("创建网络", systemImage: "plus") { showsNetworkEditor = true }
                }
                TextField("搜索名称或 UUID", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }.padding(.horizontal, 24).padding(.vertical, 12)
            if let error = state.errors[section] { XenInlineError(message: error).padding(.horizontal, 24).padding(.bottom, 10) }
            if records.isEmpty {
                ContentUnavailableView(query.isEmpty ? "暂无\(section.title)" : "没有匹配的资源", systemImage: section.symbol,
                                       description: Text(state.loading.contains(section) ? "正在读取资源…" : "可刷新清单或调整搜索条件。"))
                    .frame(maxHeight: .infinity)
            } else {
                if section == .vm {
                    Table(records, selection: $selectedIDs, sortOrder: $sortOrder) {
                        TableColumn("名称", value: \.name) { record in
                            Button { selected = record } label: { Label(record.name, systemImage: "desktopcomputer").fontWeight(.medium) }.buttonStyle(.plain)
                        }.width(min: 150, ideal: 210)
                        TableColumn("状态") { record in Text(record.stateTitle).foregroundStyle(.secondary) }.width(80)
                        TableColumn("主机") { record in Text(hostName(record)).foregroundStyle(.secondary) }.width(min: 85, ideal: 120)
                        TableColumn("CPU") { record in Text("\(record["VCPUs_at_startup"].string) vCPU").monospacedDigit() }.width(65)
                        TableColumn("内存上限") { record in Text(XenFormat.bytes(record["memory_static_max"])).monospacedDigit() }.width(80)
                        TableColumn("IP 地址") { record in Text(ipAddresses(record)).foregroundStyle(.secondary) }.width(min: 110, ideal: 150)
                    }
                } else {
                Table(records, sortOrder: $sortOrder) {
                    TableColumn("名称", value: \.name) { record in
                        Button { selected = record } label: {
                            Label(record.name, systemImage: section.symbol).fontWeight(.medium)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("查看详情")
                    }.width(min: 170, ideal: 260)
                    TableColumn("状态 / 类型") { record in
                        Text(section.api == "VM" ? record.stateTitle : resourceStatus(record)).foregroundStyle(.secondary)
                    }.width(min: 90, ideal: 120)
                    TableColumn("信息") { record in Text(resourceSummary(record)).foregroundStyle(.secondary).lineLimit(1) }
                }
                }
            }
        }
    }
    private func hostName(_ record: XenRecord) -> String {
        state.records[.host]?.first { $0.id == record["resident_on"].string }?.name ?? "—"
    }
    private func ipAddresses(_ record: XenRecord) -> String {
        let metrics = guestMetrics[record["guest_metrics"].string]?.dictionary["networks"]?.dictionary ?? [:]
        let ips = Set(metrics.filter { $0.key.contains("ip") }.values.map(\.string).filter { !$0.isEmpty })
        return ips.isEmpty ? "未上报" : ips.sorted().joined(separator: "、")
    }
    private func resourceStatus(_ record: XenRecord) -> String {
        switch section {
        case .host: record["enabled"].boolean ? "已启用" : "已禁用"
        case .storage: record["type"].string
        case .network: "网络"
        case .task: record["status"].string
        case .message: "优先级 \(record["priority"].string)"
        default: record["type"].string.isEmpty ? "—" : record["type"].string
        }
    }
    private func resourceSummary(_ record: XenRecord) -> String {
        switch section {
        case .host: record["address"].string
        case .vm, .template: "\(record["VCPUs_max"].string) vCPU · \(XenFormat.bytes(record["memory_static_max"]))"
        case .storage: "\(XenFormat.bytes(record["physical_utilisation"])) / \(XenFormat.bytes(record["physical_size"]))"
        case .disk: XenFormat.bytes(record["virtual_size"])
        case .message: record["body"].string
        default: record["name_description"].string.isEmpty ? record.uuid : record["name_description"].string
        }
    }
    @ViewBuilder private var activityBar: some View {
        let activities = store.activities.filter { $0.clusterID == cluster.id }
        if !activities.isEmpty {
            VStack(spacing: 0) {
                Divider()
                if let progress = store.transferProgress[cluster.id] {
                    HStack {
                        ProgressView(value: progress).frame(maxWidth: 260)
                        Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit())
                        Spacer()
                        Button("取消传输") { store.cancelTransfer(cluster.id) }.buttonStyle(.borderless)
                    }.padding(.horizontal, 24).padding(.top, 10)
                }
                Button { showsTasks.toggle() } label: {
                    HStack {
                        if activities.contains(where: { !$0.finished }) { ProgressView().controlSize(.small) }
                        else { Image(systemName: "list.bullet.rectangle") }
                        Text(activities.first?.title ?? "任务").lineLimit(1)
                        Spacer()
                        Text(activities.first?.message ?? "正在执行…").lineLimit(1).foregroundStyle(.secondary)
                        Image(systemName: showsTasks ? "chevron.down" : "chevron.up")
                    }.font(.caption).padding(.horizontal, 24).padding(.vertical, 12).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if showsTasks {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(activities) { activity in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(activity.title).font(.callout.weight(.medium))
                                    Text(activity.message ?? "正在执行…").font(.caption).foregroundStyle(activity.unknown ? .orange : .secondary).textSelection(.enabled)
                                }
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                }
            }
        }
    }
}

struct XenInlineError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum XenFormat {
    static func bytes(_ value: XenValue) -> String {
        guard let amount = value.number, amount >= 0, amount < Double(Int64.max) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(amount), countStyle: .binary)
    }
    static func value(_ value: XenValue) -> String {
        switch value {
        case .null: "—"
        case .bool(let flag): flag ? "是" : "否"
        case .array(let values): values.map { self.value($0) }.joined(separator: "、")
        case .dictionary(let fields): fields.keys.sorted().map { "\($0)：\(self.value(fields[$0]!))" }.joined(separator: "\n")
        default: value.string.isEmpty ? "—" : value.string
        }
    }
}
