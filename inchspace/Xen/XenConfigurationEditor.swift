import SwiftUI

struct XenConfigurationEditor: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    let record: XenRecord
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "内存"
    @State private var cpu = 1
    @State private var cpuMaximum = 1
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var staticMaximum = ""
    @State private var order = "cdn"
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("计算与启动配置").font(.title2.weight(.semibold))
            Picker("配置", selection: $mode) { Text("内存"); Text("CPU"); Text("启动顺序") }.pickerStyle(.segmented)
            Form {
                if mode == "内存" {
                    TextField("动态下限（GiB）", text: $minimum)
                    TextField("动态上限（GiB）", text: $maximum)
                    TextField("启动上限（GiB）", text: $staticMaximum).disabled(record.state != "Halted")
                    Text("运行中仅调整原固定边界内的动态范围。启动上限需关机后修改。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if mode == "CPU" {
                    Stepper("\(cpu) vCPU", value: $cpu, in: 1...4096)
                    Stepper("vCPU 上限：\(cpuMaximum)", value: $cpuMaximum, in: 1...4096).disabled(record.state != "Halted")
                    Text("运行中调整受服务器能力与原 vCPU 上限约束。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("启动顺序", text: $order)
                    Text("c：磁盘　d：光驱　n：网络，例如 cdn。需关机后修改。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).scrollDisabled(true)
            if let message { XenInlineError(message: message) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.disabled(saving)
                Button(saving ? "正在保存…" : "保存") { save() }
                    .buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(24).frame(width: 480).interactiveDismissDisabled(saving)
        .onAppear {
            cpu = Int(record["VCPUs_at_startup"].string) ?? 1
            cpuMaximum = Int(record["VCPUs_max"].string) ?? cpu
            minimum = gib(record["memory_dynamic_min"])
            maximum = gib(record["memory_dynamic_max"])
            staticMaximum = gib(record["memory_static_max"])
            order = record["HVM_boot_params"].dictionary["order"]?.string ?? "cdn"
        }
    }
    private func gib(_ value: XenValue) -> String { String((value.number ?? 0) / 1_073_741_824) }
    private func bytes(_ text: String) throws -> Int64 {
        guard let value = Double(text), value.isFinite, value >= 0, value < 8_388_608 else { throw XenError.invalid("请输入有效的 GiB 数值。") }
        return Int64((value * 1_073_741_824).rounded())
    }
    private func save() {
        do {
            let memory = try XenMemoryConfiguration(staticMin: Int64(record["memory_static_min"].string) ?? 0, dynamicMin: bytes(minimum), dynamicMax: bytes(maximum), staticMax: record.state == "Halted" ? bytes(staticMaximum) : Int64(record["memory_static_max"].string) ?? 0)
            if mode == "内存" { try memory.validate() }
            saving = true
            let cpu = cpu, cpuMaximum = cpuMaximum, order = order, mode = mode
            Task {
                store.error = nil
                await store.perform(cluster.id, title: "修改\(mode)", record: record) { client, identity in
                    if mode == "内存" { try await client.updateMemory(record, configuration: memory, identity: identity) }
                    else if mode == "CPU" { try await client.updateCPU(record, count: cpu, maximum: cpuMaximum, identity: identity) }
                    else { try await client.setBootOrder(record, order: order, identity: identity) }
                }
                saving = false
                if store.error == nil { dismiss() } else { message = store.error }
            }
        } catch { message = error.localizedDescription }
    }
}
