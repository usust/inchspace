import SwiftUI

extension XenClient {
    func updateAdvancedMap(_ vm: XenRecord, field: String, values: [String: XenValue], identity expected: XenSessionIdentity) async throws {
        guard ["platform", "other_config", "HVM_boot_params"].contains(field), values.count <= 256,
              values.keys.allSatisfy({ !$0.isEmpty && $0.count <= 256 }), values.values.allSatisfy({ if case .string(let text) = $0 { return text.count <= 65536 }; return false }) else { throw XenError.invalid("高级配置字段无效。") }
        try await mutate(vm, identity: expected, operation: field, validate: { $0.isVM && $0.state == "Halted" && $0["current_operations"].dictionary.isEmpty }) { before in
            guard before[field] == vm[field] else { throw XenError.invalid("此配置已被其他操作修改，请刷新后重新编辑。") }
            _ = try await self.submit("VM.set_\(field)", [.string(vm.id), .dictionary(values)])
            let after = try await self.record(.vm, ref: vm.id)
            guard after.uuid == vm.uuid, after[field].dictionary == values else { throw XenError.unknown("高级配置读回结果尚未确认。") }
        }
    }
    func setAffinity(_ vm: XenRecord, host: XenRecord?, delay: Int, identity expected: XenSessionIdentity) async throws {
        guard (0...86400).contains(delay) else { throw XenError.invalid("启动延迟需在 0–86400 秒之间。") }
        try await mutate(vm, identity: expected, operation: "affinity", validate: { $0.isVM && $0["current_operations"].dictionary.isEmpty }) { before in
            if let host {
                let current = try await self.record(.host, ref: host.id)
                guard current.uuid == host.uuid, current["enabled"].boolean else { throw XenError.invalid("目标主机已变化或未启用。") }
            }
            let ref = host?.id ?? "OpaqueRef:NULL"
            if before["affinity"].string != ref { _ = try await self.submit("VM.set_affinity", [.string(vm.id), .string(ref)]) }
            if before["start_delay"].string != String(delay) { _ = try await self.submit("VM.set_start_delay", [.string(vm.id), .string(String(delay))]) }
            let after = try await self.record(.vm, ref: vm.id)
            guard after.uuid == vm.uuid, after["affinity"].string == ref, after["start_delay"].string == String(delay) else { throw XenError.unknown("主机偏好或启动延迟可能仅部分保存，请刷新核对。") }
        }
    }
    func updateTags(_ vm: XenRecord, tags: [String], identity expected: XenSessionIdentity) async throws {
        guard tags.count <= 128, tags.allSatisfy({ !$0.isEmpty && $0.count <= 256 }) else { throw XenError.invalid("标签数量或长度超过限制。") }
        try await mutate(vm, identity: expected, operation: "tags", validate: { $0.isVM }) { _ in
            let values = Array(Set(tags)).sorted().map(XenValue.string)
            _ = try await self.submit("VM.set_tags", [.string(vm.id), .array(values)])
            let after = try await self.record(.vm, ref: vm.id)
            guard after.uuid == vm.uuid, Set(after["tags"].array.map(\.string)) == Set(tags) else { throw XenError.unknown("标签保存结果尚未确认。") }
        }
    }
}

struct XenAdvancedEditor: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    let vm: XenRecord
    @Environment(\.dismiss) private var dismiss
    @State private var field = "platform"
    @State private var rows: [Entry] = []
    @State private var hostID = "OpaqueRef:NULL"
    @State private var delay = 0
    @State private var tags = ""
    @State private var saving = false
    @State private var message: String?
    private struct Entry: Identifiable { let id = UUID(); var key: String; var value: String }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("高级配置").font(.title2.weight(.semibold))
            Picker("配置类型", selection: $field) {
                Text("平台").tag("platform"); Text("启动参数").tag("HVM_boot_params"); Text("其他配置").tag("other_config"); Text("主机与标签").tag("placement")
            }.pickerStyle(.segmented).labelsHidden().disabled(saving)
            if field == "placement" {
                Form {
                    Picker("首选主机", selection: $hostID) {
                        Text("自动选择").tag("OpaqueRef:NULL")
                        ForEach(store.state(cluster.id).records[.host] ?? []) { Text($0.name).tag($0.id) }
                    }
                    TextField("启动延迟（秒）", value: $delay, format: .number)
                    TextField("标签（以逗号分隔）", text: $tags)
                }.formStyle(.grouped)
            } else {
                Text("平台与启动参数仅在虚拟机关机后修改。").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($rows) { $row in
                            HStack {
                                TextField("键", text: $row.key).frame(maxWidth: 180)
                                TextField("值", text: $row.value)
                                Button(role: .destructive) { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            }
                        }
                    }
                }
                Button("添加字段", systemImage: "plus") { rows.append(Entry(key: "", value: "")) }.disabled(saving)
            }
            if let message { XenInlineError(message: message) }
            HStack {
                Spacer(); Button("取消", role: .cancel) { dismiss() }.disabled(saving)
                Button(saving ? "正在保存…" : "保存") { save() }.buttonStyle(.borderedProminent).disabled(saving || (field != "placement" && vm.state != "Halted"))
            }
        }.padding(24).frame(width: 640, height: 460).interactiveDismissDisabled(saving)
        .onAppear {
            populate(); hostID = vm["affinity"].string.isEmpty ? "OpaqueRef:NULL" : vm["affinity"].string
            delay = Int(vm["start_delay"].string) ?? 0; tags = vm["tags"].array.map(\.string).joined(separator: ", ")
        }
        .onChange(of: field) { _, _ in populate() }
    }
    private func populate() { rows = vm[field].dictionary.keys.sorted().map { Entry(key: $0, value: vm[field].dictionary[$0]!.string) } }
    private func save() {
        guard Set(rows.map(\.key)).count == rows.count else { message = "配置键不能重复。"; return }
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, XenValue.string($0.value)) })
        let host = store.state(cluster.id).records[.host]?.first { $0.id == hostID }
        let field = field, delay = delay, tagValues = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        saving = true; store.error = nil
        Task {
            await store.perform(cluster.id, title: "修改高级配置", record: vm) { client, identity in
                if field == "placement" {
                    try await client.setAffinity(vm, host: host, delay: delay, identity: identity)
                    try await client.updateTags(vm, tags: tagValues, identity: identity)
                } else { try await client.updateAdvancedMap(vm, field: field, values: values, identity: identity) }
            }
            saving = false
            if store.error == nil { dismiss() } else { message = store.error }
        }
    }
}
