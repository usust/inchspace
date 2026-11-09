import SwiftUI

struct XenResourceDetail: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    let record: XenRecord
    let back: () -> Void
    var openResource: ((XenRecord) -> Void)? = nil
    @State private var tab = "概览"
    @State private var confirmation: XenPowerAction?
    @State private var showsMetadata = false
    @State private var showsSnapshot = false
    @State private var snapshotName = ""
    @State private var showsDelete = false
    @State private var showsConfiguration = false
    @State private var showsClone = false
    @State private var showsDeviceEditor = false
    @State private var showsStorageEditor = false
    @State private var showsAdvanced = false
    @State private var showsResize = false
    @State private var convertsTemplate = false
    @State private var resizeGiB = ""
    @State private var deletesResource = false
    @State private var deviceConfirmation: XenDeviceIntent?
    @State private var cloneName = ""
    @State private var restoresSnapshot = false
    @State private var deletesSpecialObject = false
    @State private var related: [String: XenValue] = [:]
    @State private var relatedError: String?
    @State private var relatedLoading = false
    @State private var loadRevision = UUID()
    private var busy: Bool { store.isBusy(record, cluster: cluster.id) }
    private var tabs: [String] {
        if record.isVM { return ["概览", "配置", "存储", "网络", "快照"] }
        switch record.kind {
        case .host: return ["概览", "网络", "存储", "详细信息"]
        case .storage: return ["概览", "虚拟磁盘", "连接", "详细信息"]
        case .network: return ["概览", "物理接口", "虚拟网卡", "详细信息"]
        default: return ["概览", "详细信息"]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.glass).help("返回清单")
                Image(systemName: record.kind.symbol).font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name).font(.title2.weight(.semibold)).lineLimit(2)
                    Text(record.isVM ? record.stateTitle : record.kind.title).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if record.isVM {
                    if record.state == "Running" {
                        Button("控制台", systemImage: "display") { Task { await store.openConsole(cluster.id, vm: record) } }
                            .buttonStyle(.glassProminent).disabled(busy)
                    }
                    powerActions
                }
                Menu {
                    if [.vm, .template, .storage, .network, .host, .pool].contains(record.kind) {
                        Button("编辑名称与简介…") { showsMetadata = true }.disabled(busy)
                    }
                    if record.isVM {
                        Button("转换为模板…") { convertsTemplate = true }.disabled(busy || record.state != "Halted")
                        Button("导出 XVA…") { Task { await store.exportXVA(cluster, vm: record) } }
                            .disabled(busy || !(record.permits("export") || record.permits("checkpoint") || XenPowerAction.shutdown.available(for: record)))
                        Button("添加磁盘或 ISO…") { showsStorageEditor = true }.disabled(busy)
                        Button("添加虚拟网卡…") { showsDeviceEditor = true }.disabled(busy)
                        Button("高级配置…") { showsAdvanced = true }.disabled(busy)
                        Button("计算与启动配置…") { showsConfiguration = true }.disabled(busy)
                        Button(record["blocked_operations"].dictionary["destroy"] == nil ? "启用删除保护" : "取消删除保护") {
                            Task { await store.perform(cluster.id, title: "修改删除保护", record: record) { client, identity in
                                try await client.setDeletionProtection(record, enabled: record["blocked_operations"].dictionary["destroy"] == nil, identity: identity)
                            } }
                        }.disabled(busy)
                        Button("创建快照…", systemImage: "camera") { snapshotName = "\(record.name) 快照"; showsSnapshot = true }
                            .disabled(busy || !record.permits("snapshot"))
                        Divider()
                        ForEach([XenProtectedCapability.migration, .copy]) { capability in
                            Button("\(capability.title) · 暂不可用") {}.disabled(true)
                        }
                        Divider()
                        Button("删除虚拟机…", role: .destructive) { showsDelete = true }
                            .disabled(busy || record.state != "Halted" || !record.permits("destroy"))
                    }
                    if [.template, .snapshot].contains(record.kind) {
                        Button("导出 XVA…") { Task { await store.exportXVA(cluster, vm: record) } }
                            .disabled(busy || !record.permits("export"))
                    }
                    if record.kind == .template {
                        Button("从模板创建虚拟机…") { cloneName = "\(record.name) 副本"; showsClone = true }
                            .disabled(busy || !record.permits("clone"))
                    }
                    if record.kind == .snapshot {
                        Button("恢复快照…") { restoresSnapshot = true }.disabled(busy || !record.permits("revert"))
                    }
                    if [.template, .snapshot].contains(record.kind) {
                        Button("删除\(record.kind.title)…", role: .destructive) { deletesSpecialObject = true }
                            .disabled(busy || !record.permits("destroy") || record["other_config"].dictionary["default_template", default: .null].boolean)
                    }
                    if record.kind == .storage {
                        Button("导入 XVA…") { Task { await store.importXVA(cluster, storage: record) } }.disabled(busy || record["type"].string == "iso")
                        Button("扫描存储仓库") { Task { await store.perform(cluster.id, title: "扫描存储", record: record) { client, identity in try await client.scanStorage(record, identity: identity) } } }
                            .disabled(busy || !record.permits("scan"))
                    }
                    if record.kind == .disk {
                        Button("扩大虚拟磁盘…") { resizeGiB = String(format: "%.1f", (record["virtual_size"].number ?? 0) / 1_073_741_824); showsResize = true }
                            .disabled(busy || !(record.permits("resize") || record.permits("resize_online")))
                        Button("删除未使用的磁盘…", role: .destructive) { deletesResource = true }
                            .disabled(busy || !record.permits("destroy") || !record["VBDs"].array.isEmpty)
                    }
                    if record.kind == .network {
                        Button("删除空网络…", role: .destructive) { deletesResource = true }
                            .disabled(busy || !record.permits("destroy") || !record["PIFs"].array.isEmpty || !record["VIFs"].array.isEmpty)
                    }
                    if record.kind == .task {
                        Button("取消服务器任务…", role: .destructive) { Task { await store.perform(cluster.id, title: "取消任务", record: record) { client, identity in try await client.cancelTask(record, identity: identity) } } }
                            .disabled(busy || !record.permits("cancel"))
                    }
                    if let capability = protectedCapability {
                        Button("\(capability.title) · 暂不可用") {}.disabled(true)
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help("资源操作")
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Picker("详情栏目", selection: $tab) { ForEach(tabs, id: \.self) { Text($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520).padding(.horizontal, 24).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if tab == "概览" { overview }
                    else if tab == "配置" { configuration }
                    else if ["存储", "网络", "快照", "虚拟磁盘", "连接", "物理接口", "虚拟网卡"].contains(tab) { relatedContent }
                    else { rawDetails }
                }
                .padding(24).frame(maxWidth: AppLayout.contentMaxWidth).frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .confirmationDialog("将“\(record.name)”转换为模板？", isPresented: $convertsTemplate) {
            Button("转换为模板") {
                Task {
                    await store.perform(cluster.id, title: "转换为模板", record: record) { client, identity in try await client.convertToTemplate(record, identity: identity) }
                    await store.refresh(cluster.id, kind: .template)
                }
            }
        } message: { Text("转换后不再作为普通虚拟机运行，可从模板创建新的虚拟机。") }
        .alert("扩大虚拟磁盘", isPresented: $showsResize) {
            TextField("新容量（GiB）", text: $resizeGiB)
            Button("取消", role: .cancel) {}
            Button("扩大") {
                guard let gib = Double(resizeGiB), gib.isFinite, gib > 0, gib < 8_388_608 else { store.error = "请输入有效的 GiB 容量。"; return }
                Task { await store.perform(cluster.id, title: "扩大磁盘", record: record) { client, identity in try await client.resizeDisk(record, bytes: Int64(gib * 1_073_741_824), identity: identity) } }
            }
        } message: { Text("只扩大虚拟磁盘容量，来宾分区与文件系统需另行扩展。") }
        .confirmationDialog("删除“\(record.name)”？", isPresented: $deletesResource) {
            Button("删除", role: .destructive) {
                Task { await store.perform(cluster.id, title: "删除\(record.kind.title)", record: record) { client, identity in
                    if record.kind == .disk { try await client.deleteUnusedDisk(record, identity: identity) }
                    else if record.kind == .network { try await client.deleteNetwork(record, identity: identity) }
                } }
            }
        } message: { Text("此操作无法撤销。仅允许删除未关联设备的资源。") }
        .sheet(isPresented: $showsAdvanced) { XenAdvancedEditor(store: store, cluster: cluster, vm: record) }
        .sheet(isPresented: $showsStorageEditor, onDismiss: { Task { await loadRelated() } }) { XenStorageEditor(store: store, cluster: cluster, vm: record) }
        .sheet(isPresented: $showsDeviceEditor, onDismiss: { Task { await loadRelated() } }) { XenDeviceEditor(store: store, cluster: cluster, vm: record) }
        .confirmationDialog("确认设备操作？", isPresented: Binding(get: { deviceConfirmation != nil }, set: { if !$0 { deviceConfirmation = nil } })) {
            if let intent = deviceConfirmation {
                Button(intent.title, role: intent.operation == "destroy" ? .destructive : nil) {
                    deviceConfirmation = nil
                    Task {
                        await store.perform(cluster.id, title: intent.title, record: record) { client, identity in
                            try await client.changeDevice(record, api: intent.api, ref: intent.ref, uuid: intent.uuid, operation: intent.operation, identity: identity)
                        }
                        await loadRelated()
                    }
                }
            }
        } message: { Text("设备操作可能中断来宾的网络或存储访问。移除磁盘设备时保留虚拟磁盘。") }
        .sheet(isPresented: $showsConfiguration) { XenConfigurationEditor(store: store, cluster: cluster, record: record) }
        .alert("从模板创建虚拟机", isPresented: $showsClone) {
            TextField("虚拟机名称", text: $cloneName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                Task { await store.perform(cluster.id, title: "从模板创建", record: record) { client, identity in
                    try await client.createFromTemplate(record, name: cloneName, identity: identity)
                }; await store.refresh(cluster.id, kind: .vm) }
            }
        } message: { Text("在当前资源池创建并保留模板原有磁盘与网络配置，不自动启动。") }
        .confirmationDialog("恢复快照？", isPresented: $restoresSnapshot) {
            Button("恢复快照", role: .destructive) {
                Task { await store.perform(cluster.id, title: "恢复快照", record: record) { client, identity in
                    try await client.restoreSnapshot(record, identity: identity)
                } }
            }
        } message: { Text("原虚拟机必须已关机，恢复会覆盖其当前配置与磁盘状态。") }
        .confirmationDialog("删除\(record.kind.title)？", isPresented: $deletesSpecialObject) {
            Button("删除", role: .destructive) {
                Task { await store.perform(cluster.id, title: "删除\(record.kind.title)", record: record) { client, identity in
                    try await client.deleteSnapshotOrTemplate(record, identity: identity)
                } }
            }
        } message: { Text("仅删除对象，保留虚拟磁盘。默认系统模板不可删除。") }
        .sheet(isPresented: $showsMetadata) { XenMetadataEditor(store: store, cluster: cluster, record: record) }
        .alert(confirmation.map { "\($0.title)“\(record.name)”？" } ?? "确认操作", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("取消", role: .cancel) { confirmation = nil }
            if let action = confirmation {
                Button(action.title, role: action == .forceShutdown ? .destructive : nil) {
                    confirmation = nil
                    Task { await store.power(cluster.id, record: record, action: action) }
                }
            }
        } message: { Text(confirmation == .forceShutdown ? "强制关机可能导致来宾数据丢失。" : "操作将提交到当前资源池，执行期间请等待结果。") }
        .alert("创建快照", isPresented: $showsSnapshot) {
            TextField("快照名称", text: $snapshotName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let name = snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await store.perform(cluster.id, title: "创建快照", record: record) { client, identity in
                    try await client.snapshot(record, name: name, identity: identity)
                } }
            }
        }
        .confirmationDialog("删除“\(record.name)”？", isPresented: $showsDelete) {
            Button("删除虚拟机", role: .destructive) {
                Task { await store.perform(cluster.id, title: "删除虚拟机", record: record) { client, identity in try await client.deleteVM(record, identity: identity) } }
            }
        } message: { Text("仅删除 VM 对象，保留虚拟磁盘。此操作无法撤销。") }
        .task(id: tab) { await loadRelated() }
    }
    private var powerActions: some View {
        HStack(spacing: 10) {
            if let action = XenPowerAction.allCases.first(where: { [.start, .unpause, .resume].contains($0) && $0.available(for: record) }) {
                Button(action.title, systemImage: "play.fill") { confirmation = action }
                    .buttonStyle(.glassProminent).disabled(busy)
            }
            Menu("电源", systemImage: "power") {
                ForEach(XenPowerAction.allCases) { action in
                    Button(action.title, role: action == .forceShutdown ? .destructive : nil) { confirmation = action }
                        .disabled(busy || !action.available(for: record))
                }
            }
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            if record.isVM {
                HStack(spacing: 28) {
                    metric("CPU", "\(record["VCPUs_at_startup"].string) vCPU")
                    metric("内存上限", XenFormat.bytes(record["memory_static_max"]))
                    metric("状态", record.stateTitle)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            }
            if (record.isVM && record.state == "Running") || record.kind == .host {
                XenMonitoringView(store: store, cluster: cluster, record: record)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("基础信息").font(.headline)
                info("名称", record.name)
                info("UUID", record.uuid)
                if !record["name_description"].string.isEmpty { info("简介", record["name_description"].string) }
                ForEach(overviewFields, id: \.0) { key, title in
                    if record.fields[key] != nil { info(title, displayField(key, record[key])) }
                }
            }
        }
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("计算资源").font(.headline)
            info("vCPU", record["VCPUs_at_startup"].string)
            info("vCPU 上限", record["VCPUs_max"].string)
            info("固定内存下限", XenFormat.bytes(record["memory_static_min"]))
            info("动态内存下限", XenFormat.bytes(record["memory_dynamic_min"]))
            info("动态内存上限", XenFormat.bytes(record["memory_dynamic_max"]))
            info("启动内存上限", XenFormat.bytes(record["memory_static_max"]))
            Divider()
            Text("启动配置").font(.headline)
            info("启动顺序", XenFormat.value(record["HVM_boot_params"]))
            info("启动延迟", record["start_delay"].string)
            info("删除保护", record["blocked_operations"].dictionary["destroy"] == nil ? "未启用" : "已启用")
        }
    }
    private var relatedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(record.isVM && tab == "存储" ? "虚拟磁盘与光驱" : tab).font(.headline)
            if relatedLoading { ProgressView().controlSize(.small) }
            if let relatedError { XenInlineError(message: relatedError) }
            if related.isEmpty && !relatedLoading && relatedError == nil {
                Text("暂无\(tab)").foregroundStyle(.secondary)
            }
            ForEach(related.keys.sorted(), id: \.self) { key in
                let fields = related[key]?.dictionary ?? [:]
                VStack(alignment: .leading, spacing: 8) {
                    if tab == "快照", let openResource {
                        Button(fields["name_label"]?.string ?? "快照") { openResource(XenRecord(id: key, kind: .snapshot, fields: fields)) }.buttonStyle(.link)
                    } else {
                        Text(fields["name_label"]?.string ?? fields["device"]?.string.mapDeviceName(record.kind == .host || tab == "物理接口" ? "物理接口" : tab) ?? "设备")
                            .font(.callout.weight(.medium))
                    }
                    if record.isVM && tab != "快照" {
                        HStack {
                            ForEach(tab == "网络" ? ["plug", "unplug", "destroy"] : ["plug", "unplug", "eject", "destroy"], id: \.self) { operation in
                                let title = ["plug": "连接", "unplug": "断开", "destroy": "移除", "eject": "弹出光盘"][operation] ?? operation
                                Button(title) {
                                    deviceConfirmation = XenDeviceIntent(api: tab == "网络" ? "VIF" : "VBD", ref: key, uuid: fields["uuid"]?.string ?? "", operation: operation, title: title)
                                }.disabled(busy || fields["allowed_operations"]?.array.contains(.string(operation)) != true)
                            }
                        }.buttonStyle(.borderless).font(.caption)
                    }
                    ForEach(fields.keys.sorted().filter { ["VDI", "SR", "host", "device", "VLAN", "type", "mode", "currently_attached", "network", "MAC", "MTU", "IP", "virtual_size", "power_state", "snapshot_time"].contains($0) }, id: \.self) { field in
                        info(fieldTitle(field), displayField(field, fields[field]!))
                    }
                }.padding(.vertical, 10)
                Divider()
            }
        }
    }
    private var rawDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("详细信息").font(.headline)
            ForEach(record.fields.keys.sorted().filter { !["session", "session_id", "password"].contains($0.lowercased()) }, id: \.self) { key in
                info(fieldTitle(key), XenFormat.value(record[key]))
            }
        }
    }
    private var overviewFields: [(String, String)] {
        switch record.kind {
        case .host: [("address", "管理地址"), ("enabled", "已启用"), ("software_version", "系统版本"), ("cpu_info", "CPU"), ("memory_total", "内存")]
        case .storage: [("type", "存储类型"), ("shared", "共享存储"), ("physical_size", "总容量（字节）"), ("physical_utilisation", "已用容量（字节）")]
        case .network: [("bridge", "网桥"), ("MTU", "MTU"), ("managed", "受管网络")]
        case .disk: [("virtual_size", "虚拟容量（字节）"), ("read_only", "只读"), ("sharable", "可共享")]
        case .task: [("status", "状态"), ("progress", "进度"), ("error_info", "错误信息")]
        case .message: [("body", "内容"), ("priority", "优先级"), ("timestamp", "时间")]
        default: [("power_state", "电源状态"), ("resident_on", "所属主机"), ("snapshot_time", "快照时间")]
        }
    }
    private var protectedCapability: XenProtectedCapability? {
        switch record.kind {
        case .host: .hostMaintenance
        case .storage: .storageLifecycle
        case .network: .networkTopology
        case .patch: .patches
        case .subject, .role: .rbac
        case .pool: .poolGovernance
        default: nil
        }
    }
    private func info(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value.isEmpty ? "—" : value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func displayField(_ key: String, _ value: XenValue) -> String {
        if key == "power_state" { return record.stateTitle }
        if key == "type", value.string == "CD" { return "光驱" }
        if key == "type", value.string == "Disk" { return "磁盘" }
        if ["virtual_size", "memory_total", "physical_size", "physical_utilisation"].contains(key) { return XenFormat.bytes(value) }
        let kinds: [String: XenResourceKind] = ["VDI": .disk, "SR": .storage, "host": .host, "resident_on": .host, "network": .network]
        if let kind = kinds[key], let target = store.state(cluster.id).records[kind]?.first(where: { $0.id == value.string }) { return target.name }
        return XenFormat.value(value)
    }
    private func fieldTitle(_ key: String) -> String {
        ["currently_attached": "已连接", "network": "所属网络", "VDI": "虚拟磁盘", "type": "类型", "mode": "访问模式", "power_state": "状态", "snapshot_time": "创建时间"][key] ?? key
    }
    private func loadRelated() async {
        let currentTab = tab
        let revision = UUID()
        loadRevision = revision
        related = [:]; relatedError = nil
        guard ["存储", "网络", "快照", "虚拟磁盘", "连接", "物理接口", "虚拟网卡"].contains(currentTab) else { return }
        relatedLoading = true
        defer { if loadRevision == revision { relatedLoading = false } }
        do {
            let api: String
            if record.isVM { api = currentTab == "存储" ? "VBD" : currentTab == "网络" ? "VIF" : "VM" }
            else if record.kind == .host { api = currentTab == "网络" ? "PIF" : "PBD" }
            else if record.kind == .storage { api = currentTab == "虚拟磁盘" ? "VDI" : "PBD" }
            else { api = currentTab == "物理接口" ? "PIF" : "VIF" }
            let values = try await store.relatedRecords(cluster.id, api: api)
            guard loadRevision == revision else { return }
            related = values.filter { _, value in
                let fields = value.dictionary
                if record.isVM { return currentTab == "快照" ? fields["snapshot_of"]?.string == record.id : fields["VM"]?.string == record.id }
                if record.kind == .host { return fields["host"]?.string == record.id }
                if record.kind == .storage { return fields["SR"]?.string == record.id }
                return fields["network"]?.string == record.id
            }
        } catch { if loadRevision == revision { relatedError = error.localizedDescription } }
    }
}

private extension String {
    func mapDeviceName(_ tab: String) -> String { "\(tab == "物理接口" ? "物理接口" : tab == "网络" ? "虚拟网卡" : "设备") \(self)" }
}

private struct XenMetadataEditor: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    let record: XenRecord
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("名称与简介").font(.title2.weight(.semibold))
            TextField("名称", text: $name)
            TextEditor(text: $description).frame(height: 120).border(Color(nsColor: .separatorColor))
                .accessibilityLabel("简介")
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.disabled(saving)
                Button(saving ? "正在保存…" : "保存") {
                    saving = true
                    store.error = nil
                    Task {
                        await store.perform(cluster.id, title: "保存名称与简介", record: record) { client, identity in
                            try await client.updateMetadata(record, name: name, description: description, identity: identity)
                        }
                        saving = false
                        if store.error == nil { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 460)
        .onAppear { name = record.name; description = record["name_description"].string }
        .interactiveDismissDisabled(saving)
    }
}

private struct XenDeviceIntent {
    let api: String
    let ref: String
    let uuid: String
    let operation: String
    let title: String
}
