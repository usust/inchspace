import SwiftUI

struct XenClusterEditor: View {
    @ObservedObject var store: XenStore
    @Environment(\.dismiss) private var dismiss
    @State private var cluster: XenCluster
    @State private var password = ""
    @State private var message: String?
    @State private var advanced = false
    private let isEditing: Bool
    let saved: (XenCluster) -> Void

    init(store: XenStore, cluster: XenCluster? = nil, saved: @escaping (XenCluster) -> Void) {
        self.store = store
        _cluster = State(initialValue: cluster ?? XenCluster(name: "", address: "https://"))
        isEditing = cluster != nil
        self.saved = saved
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isEditing ? "编辑 Xen 集群" : "添加 Xen 集群").font(.title2.weight(.semibold))
            Text("填写 XCP-ng 或 XenServer 的管理地址，连接后识别资源池。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("名称", text: $cluster.name)
                TextField("管理地址", text: $cluster.address, prompt: Text("https://192.168.1.10"))
                    .autocorrectionDisabled()
                TextField("用户名", text: $cluster.username)
                SecureField(isEditing ? "密码（留空保留）" : "密码", text: $password)
                DisclosureGroup("高级选项", isExpanded: $advanced) {
                    Toggle("启动 inchspace 时连接", isOn: $cluster.connectsOnLaunch)
                    Toggle("断线后尝试重新连接", isOn: $cluster.reconnectsAutomatically)
                    Toggle("允许不受信任的服务器证书", isOn: $cluster.allowsUntrustedCertificate)
                    if cluster.allowsUntrustedCertificate {
                        Text("仅对此连接生效。请确认管理地址来自可信网络。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if cluster.address.lowercased().hasPrefix("http:") {
                    Text("HTTP 会以明文传输管理凭据。建议使用 HTTPS。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if let message { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEditing ? "保存" : "添加并连接") {
                    do {
                        try store.save(cluster, password: isEditing && password.isEmpty ? nil : password)
                        saved(cluster)
                        dismiss()
                    } catch { message = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(cluster.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!isEditing && password.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

struct XenClusterSection: View {
    @ObservedObject var store: XenStore
    let open: (XenCluster) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Xen 集群").font(.headline)
            ForEach(store.clusters) { cluster in
                Button { open(cluster) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(.secondary).frame(width: 40)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(cluster.name).font(.headline).foregroundStyle(.primary)
                            Text(cluster.address).font(.callout).foregroundStyle(.secondary)
                            if store.state(cluster.id).updatedAt != nil {
                                let state = store.state(cluster.id)
                                Text("\(state.records[.host]?.count ?? 0) 台主机 · \(state.records[.vm]?.count ?? 0) 台虚拟机\(state.connected ? "" : " · 上次连接数据")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Label(store.state(cluster.id).connected ? "已连接" : "未连接", systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(store.state(cluster.id).connected ? .green : .secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(cluster.name)，Xen 集群，\(store.state(cluster.id).connected ? "已连接" : "未连接")")
            }
        }
    }
}
