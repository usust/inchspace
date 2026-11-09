import SwiftUI

struct XenStorageEditor: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    let vm: XenRecord
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "新建磁盘"
    @State private var storageID = ""
    @State private var isoID = ""
    @State private var diskID = ""
    @State private var name = ""
    @State private var size = "32"
    @State private var saving = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加存储设备").font(.title2.weight(.semibold))
            Picker("类型", selection: $mode) { Text("新建磁盘"); Text("现有磁盘"); Text("挂载 ISO") }.pickerStyle(.segmented)
            Form {
                if mode == "新建磁盘" {
                    TextField("名称", text: $name)
                    TextField("容量（GiB）", text: $size)
                    Picker("存储仓库", selection: $storageID) {
                        Text("选择存储").tag("")
                        ForEach((store.state(cluster.id).records[.storage] ?? []).filter { $0["type"].string != "iso" }) { Text($0.name).tag($0.id) }
                    }
                } else if mode == "现有磁盘" {
                    Picker("磁盘", selection: $diskID) {
                        Text("选择磁盘").tag("")
                        ForEach((store.state(cluster.id).records[.disk] ?? []).filter { !$0["read_only"].boolean && !$0["is_a_snapshot"].boolean && $0["type"].string != "iso" && ($0["VBDs"].array.isEmpty || $0["sharable"].boolean) }) { Text($0.name).tag($0.id) }
                    }
                } else {
                    Picker("ISO 镜像", selection: $isoID) {
                        Text("选择 ISO").tag("")
                        ForEach((store.state(cluster.id).records[.disk] ?? []).filter { $0["type"].string == "iso" || $0["read_only"].boolean }) { Text($0.name).tag($0.id) }
                    }
                }
            }.formStyle(.grouped).scrollDisabled(true)
            if let message { XenInlineError(message: message) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.disabled(saving)
                Button("添加") { save() }.buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(24).frame(width: 480).interactiveDismissDisabled(saving)
        .task {
            name = "\(vm.name) 磁盘"
            await store.refresh(cluster.id, kind: .storage)
            await store.refresh(cluster.id, kind: .disk)
        }
    }
    private func save() {
        let storage = store.state(cluster.id).records[.storage]?.first { $0.id == storageID }
        let iso = store.state(cluster.id).records[.disk]?.first { $0.id == isoID }
        let existingDisk = store.state(cluster.id).records[.disk]?.first { $0.id == diskID }
        let gib = Double(size) ?? 0
        guard mode == "挂载 ISO" ? iso != nil : mode == "现有磁盘" ? existingDisk != nil : storage != nil && gib > 0 && gib < 8_388_608 else { message = "请选择设备来源并填写有效容量。"; return }
        saving = true; store.error = nil
        let mode = mode, name = name
        Task {
            await store.perform(cluster.id, title: mode, record: vm) { client, identity in
                if mode == "挂载 ISO", let iso { try await client.insertISO(vm, disk: iso, identity: identity) }
                else if mode == "现有磁盘", let existingDisk { try await client.attachDisk(vm, disk: existingDisk, identity: identity) }
                else if let storage { try await client.addDisk(vm, storage: storage, name: name, bytes: Int64(gib * 1_073_741_824), identity: identity) }
            }
            saving = false
            if store.error == nil { dismiss() } else { message = store.error }
        }
    }
}
