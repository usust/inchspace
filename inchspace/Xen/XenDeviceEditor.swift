import SwiftUI

struct XenDeviceEditor: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    let vm: XenRecord
    @Environment(\.dismiss) private var dismiss
    @State private var networkID = ""
    @State private var saving = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加虚拟网卡").font(.title2.weight(.semibold))
            Picker("网络", selection: $networkID) {
                Text("选择网络").tag("")
                ForEach(store.state(cluster.id).records[.network] ?? []) { network in Text(network.name).tag(network.id) }
            }
            Text("设备号与 MAC 地址由服务器分配。运行中的虚拟机将尝试连接新网卡。")
                .font(.callout).foregroundStyle(.secondary)
            if let message { XenInlineError(message: message) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.disabled(saving)
                Button("添加") {
                    guard let network = store.state(cluster.id).records[.network]?.first(where: { $0.id == networkID }) else { return }
                    saving = true; store.error = nil
                    Task {
                        await store.perform(cluster.id, title: "添加虚拟网卡", record: vm) { client, identity in
                            try await client.createVIF(vm, network: network, identity: identity)
                        }
                        saving = false
                        if store.error == nil { dismiss() } else { message = store.error }
                    }
                }.buttonStyle(.borderedProminent).disabled(networkID.isEmpty || saving)
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(saving)
        .task { await store.refresh(cluster.id, kind: .network) }
    }
}

struct XenNetworkEditor: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var mtu = 1500
    @State private var saving = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("创建网络").font(.title2.weight(.semibold))
            TextField("名称", text: $name)
            TextField("MTU", value: $mtu, format: .number)
            Text("创建资源池内部网络。物理接口、VLAN 和 Bond 配置仍受保护。")
                .font(.callout).foregroundStyle(.secondary)
            if let message { XenInlineError(message: message) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.disabled(saving)
                Button("创建") {
                    guard let pool = store.state(cluster.id).records[.pool]?.first else { return }
                    saving = true; store.error = nil
                    Task {
                        await store.perform(cluster.id, title: "创建网络", record: pool) { client, identity in
                            try await client.createNetwork(name: name, mtu: mtu, identity: identity)
                        }
                        await store.refresh(cluster.id, kind: .network)
                        saving = false
                        if store.error == nil { dismiss() } else { message = store.error }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(saving)
    }
}
