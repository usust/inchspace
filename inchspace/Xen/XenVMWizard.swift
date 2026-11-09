import Foundation
import SwiftUI

nonisolated struct XenCreationPlan: Sendable {
    let template: XenRecord
    let name: String
    let description: String
    let vcpus: Int
    let memoryBytes: Int64
    let storage: XenRecord?
    let diskBytes: Int64
    let network: XenRecord?
    let iso: XenRecord?
    let startAfter: Bool
}

extension XenClient {
    func createVM(_ plan: XenCreationPlan, identity expected: XenSessionIdentity) async throws {
        guard !plan.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...4096).contains(plan.vcpus), plan.memoryBytes > 0 else { throw XenError.invalid("名称、CPU 或内存配置不正确。") }
        try await mutate(plan.template, identity: expected, operation: "clone", validate: { $0["is_a_template"].boolean && !$0["is_a_snapshot"].boolean && $0.permits("clone") }) { template in
            let system = template["other_config"].dictionary["default_template", default: .null].boolean
            guard plan.memoryBytes >= Int64(template["memory_static_min"].string) ?? 0 else { throw XenError.invalid("内存不能小于模板固定下限。") }
            if system && (plan.storage == nil || plan.diskBytes <= 0) { throw XenError.invalid("系统模板需要选择存储并配置磁盘。") }
            let ref = try await self.submit("VM.clone", [.string(template.id), .string(plan.name)]).string
            guard ref.hasPrefix("OpaqueRef:"), ref != "OpaqueRef:NULL" else { throw XenError.unknown("VM 创建结果未知，请核对资源清单。") }
            do {
                var cloned = try await self.record(.template, ref: ref)
                if system, cloned["other_config"].dictionary["disks"] != nil {
                    var config = cloned["other_config"].dictionary
                    config.removeValue(forKey: "disks")
                    _ = try await self.submit("VM.set_other_config", [.string(ref), .dictionary(config)])
                }
                _ = try await self.submit("VM.provision", [.string(ref)])
                cloned = try await self.record(.vm, ref: ref)
                guard cloned.isVM else { throw XenError.unknown("创建后对象仍为模板。") }
                try await self.updateMetadata(cloned, name: plan.name, description: plan.description, identity: expected)
                try await self.updateCPU(cloned, count: plan.vcpus, identity: expected)
                cloned = try await self.record(.vm, ref: ref)
                let memory = XenMemoryConfiguration(staticMin: Int64(cloned["memory_static_min"].string) ?? 0, dynamicMin: plan.memoryBytes, dynamicMax: plan.memoryBytes, staticMax: plan.memoryBytes)
                try await self.updateMemory(cloned, configuration: memory, identity: expected)
                if system, let storage = plan.storage {
                    cloned = try await self.record(.vm, ref: ref)
                    try await self.addDisk(cloned, storage: storage, name: "\(plan.name) 磁盘", bytes: plan.diskBytes, identity: expected)
                }
                if let network = plan.network {
                    cloned = try await self.record(.vm, ref: ref)
                    // System templates have no provisioned NICs. Custom templates preserve their network devices.
                    if system { try await self.createVIF(cloned, network: network, identity: expected) }
                }
                if let iso = plan.iso {
                    cloned = try await self.record(.vm, ref: ref)
                    try await self.insertISO(cloned, disk: iso, identity: expected)
                }
            } catch { throw XenError.unknown("VM \(ref) 已创建，后续配置未完成。已保留对象与设备，请核对后继续，勿重复创建。\(error.localizedDescription)") }
            if plan.startAfter {
                let vm = try await self.record(.vm, ref: ref)
                do { try await self.power(.start, vm: vm, identity: expected) }
                catch { throw XenError.unknown("VM 已创建并完成配置，但启动未确认：\(error.localizedDescription)。请从清单核对 VM。") }
            }
        }
    }
}

struct XenVMWizard: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var templateID = ""
    @State private var name = ""
    @State private var description = ""
    @State private var cpu = 2
    @State private var memory = "4"
    @State private var disk = "32"
    @State private var storageID = ""
    @State private var networkID = ""
    @State private var isoID = ""
    @State private var startAfter = false
    @State private var saving = false
    @State private var message: String?
    private var state: XenConnectionState { store.state(cluster.id) }
    private var template: XenRecord? { state.records[.template]?.first { $0.id == templateID } }
    private var system: Bool { template?["other_config"].dictionary["default_template", default: .null].boolean == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("创建虚拟机").font(.title2.weight(.semibold))
            HStack(spacing: 18) {
                ForEach(Array(["模板", "资源", "确认"].enumerated()), id: \.offset) { index, title in
                    Label(title, systemImage: "\(index + 1).circle\(index == step ? ".fill" : "")")
                        .foregroundStyle(index == step ? Color.accentColor : Color.secondary)
                }
            }.font(.callout)
            Form {
                if step == 0 {
                    Picker("模板", selection: $templateID) {
                        Text("选择模板").tag("")
                        ForEach(state.records[.template] ?? []) { Text($0.name).tag($0.id) }
                    }
                    TextField("名称", text: $name)
                    TextField("简介", text: $description, axis: .vertical).lineLimit(3...5)
                } else if step == 1 {
                    Stepper("\(cpu) vCPU", value: $cpu, in: 1...4096)
                    TextField("内存（GiB）", text: $memory)
                    if system {
                        TextField("磁盘（GiB）", text: $disk)
                        Picker("存储仓库", selection: $storageID) {
                            Text("选择存储").tag("")
                            ForEach((state.records[.storage] ?? []).filter { $0["type"].string != "iso" && $0["type"].string != "udev" }) { Text($0.name).tag($0.id) }
                        }
                        Picker("网络", selection: $networkID) {
                            Text("暂不添加网卡").tag("")
                            ForEach(state.records[.network] ?? []) { Text($0.name).tag($0.id) }
                        }
                    } else { Text("自定义模板保留原有磁盘与网络配置。创建后可在设备页面调整。").font(.callout).foregroundStyle(.secondary) }
                    Picker("安装介质", selection: $isoID) {
                        Text("暂不挂载 ISO").tag("")
                        ForEach((state.records[.disk] ?? []).filter { $0["type"].string == "iso" }) { Text($0.name).tag($0.id) }
                    }
                } else {
                    LabeledContent("模板", value: template?.name ?? "—")
                    LabeledContent("名称", value: name)
                    LabeledContent("CPU", value: "\(cpu) vCPU")
                    LabeledContent("内存", value: "\(memory) GiB")
                    if system { LabeledContent("磁盘", value: "\(disk) GiB") }
                    Toggle("创建完成后启动", isOn: $startAfter)
                    Text("创建或配置中断时保留对象和设备，供核对与继续处理。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let message { XenInlineError(message: message) }
            if let error = state.errors[.template] { XenInlineError(message: error) }
            HStack {
                Button("取消", role: .cancel) { dismiss() }.disabled(saving)
                Spacer()
                if step > 0 { Button("上一步") { step -= 1 }.disabled(saving) }
                Button(saving ? "正在创建…" : step == 2 ? "创建" : "下一步") {
                    if step < 2 { step += 1 } else { create() }
                }.buttonStyle(.borderedProminent).disabled(saving || template == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 580, height: 570).interactiveDismissDisabled(saving)
        .task { for kind: XenResourceKind in [.template, .storage, .network, .disk] { await store.refresh(cluster.id, kind: kind) } }
    }
    private func create() {
        guard let template, let memoryGiB = Double(memory), memoryGiB.isFinite, memoryGiB > 0, memoryGiB < 8_388_608,
              let diskGiB = Double(disk), diskGiB.isFinite, diskGiB > 0, diskGiB < 8_388_608 else { message = "请输入有效的内存与磁盘容量。"; return }
        let storage = state.records[.storage]?.first { $0.id == storageID }
        if system && storage == nil { message = "请选择存储仓库。"; step = 1; return }
        let plan = XenCreationPlan(template: template, name: name, description: description, vcpus: cpu, memoryBytes: Int64(memoryGiB * 1_073_741_824), storage: storage, diskBytes: Int64(diskGiB * 1_073_741_824), network: state.records[.network]?.first { $0.id == networkID }, iso: state.records[.disk]?.first { $0.id == isoID }, startAfter: startAfter)
        saving = true; store.error = nil
        Task {
            await store.perform(cluster.id, title: "创建虚拟机", record: template) { client, identity in try await client.createVM(plan, identity: identity) }
            await store.refresh(cluster.id, kind: .vm)
            saving = false
            if store.error == nil { dismiss() } else { message = store.error }
        }
    }
}
