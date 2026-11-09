import SwiftUI

extension XenClient {
    func setStartDelay(_ vm: XenRecord, seconds: Int, identity expected: XenSessionIdentity) async throws {
        guard (0...86400).contains(seconds) else { throw XenError.invalid("启动延迟需在 0–86400 秒之间。") }
        try await mutate(vm, identity: expected, operation: "delay", validate: { $0.isVM && $0["current_operations"].dictionary.isEmpty }) { before in
            if before["start_delay"].string == String(seconds) { return }
            _ = try await self.submit("VM.set_start_delay", [.string(vm.id), .string(String(seconds))])
            let after = try await self.record(.vm, ref: vm.id)
            guard after.uuid == before.uuid, after["start_delay"].string == String(seconds) else { throw XenError.unknown("启动延迟保存结果尚未确认。") }
        }
    }
}

struct XenStartDelayEditor: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var saving = false
    @State private var message: String?
    private struct Entry: Identifiable { var id: String { vm.id }; let vm: XenRecord; var seconds: Int }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("虚拟机启动延迟").font(.title2.weight(.semibold))
            Text("分别设置每台虚拟机的启动延迟，不开启资源池 HA 或自动启动。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach($entries) { $entry in
                        HStack {
                            Text(entry.vm.name).frame(maxWidth: .infinity, alignment: .leading)
                            TextField("秒", value: $entry.seconds, format: .number).frame(width: 100)
                            Text("秒").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let message { XenInlineError(message: message) }
            HStack {
                Spacer(); Button("取消", role: .cancel) { dismiss() }.disabled(saving)
                Button(saving ? "正在保存…" : "保存") {
                    guard entries.allSatisfy({ (0...86400).contains($0.seconds) }) else { message = "延迟需在 0–86400 秒之间。"; return }
                    let updates = entries.filter { $0.seconds != Int($0.vm["start_delay"].string) ?? 0 }
                    saving = true; store.error = nil
                    Task {
                        for entry in updates {
                            await store.perform(cluster.id, title: "设置启动延迟", record: entry.vm) { client, identity in try await client.setStartDelay(entry.vm, seconds: entry.seconds, identity: identity) }
                            if store.error != nil { break }
                        }
                        saving = false
                        if store.error == nil { dismiss() } else { message = store.error }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(24).frame(width: 560, height: 460).interactiveDismissDisabled(saving)
        .onAppear { entries = (store.state(cluster.id).records[.vm] ?? []).map { Entry(vm: $0, seconds: Int($0["start_delay"].string) ?? 0) } }
    }
}
