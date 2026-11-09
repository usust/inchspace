import Foundation
import Combine
import SwiftUI

nonisolated struct XenAlertRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "CPU 持续过高"
    var threshold = 90.0
    var duration = 60.0
    var enabled = true
    var metric: String?
    var metricTitle: String { ["cpu": "CPU", "memory": "主机内存", "networkRx": "网络接收", "networkTx": "网络发送", "diskRead": "磁盘读取", "diskWrite": "磁盘写入"][metric ?? "cpu"] ?? "CPU" }
    var unit: String { ["cpu", "memory"].contains(metric ?? "cpu") ? "%" : "MiB/s" }
}
nonisolated struct XenAlertEvent: Codable, Identifiable {
    var id = UUID()
    let clusterID: UUID
    let poolUUID: String
    let resourceUUID: String
    let ruleID: UUID
    let title: String
    let createdAt: Date
    var recoveredAt: Date?
    var acknowledged = false
    var deliveryStatus: String?
}

/// Sampling gaps never imply recovery. Events stay scoped to pool UUID, resource UUID and rule.
@MainActor
final class XenAlertCenter: ObservableObject {
    @Published private(set) var rules: [XenAlertRule] = []
    @Published private(set) var events: [XenAlertEvent] = []
    @Published var error: String?
    @Published private(set) var notificationConfiguration = XenNotificationConfiguration()
    private var windows: [String: (first: Double, last: Double)] = [:]
    private let url: URL
    private struct Archive: Codable { let rules: [XenAlertRule]; let events: [XenAlertEvent]; var notifications: XenNotificationConfiguration? }
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("vip.lylab.inchspace/xen-alerts.json")
        if FileManager.default.fileExists(atPath: self.url.path) {
            do {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.url))
                rules = archive.rules; events = archive.events
                notificationConfiguration = archive.notifications ?? XenNotificationConfiguration()
            } catch { self.error = "无法读取告警配置：\(error.localizedDescription)" }
        }
    }
    func saveNotifications(_ configuration: XenNotificationConfiguration, password: String?) throws {
        try configuration.validate()
        let previous = notificationConfiguration
        var previousPassword: String?
        if password != nil || (configuration.mailEnabled && !configuration.username.isEmpty) {
            do { previousPassword = try XenKeychain().password(for: configuration.id) }
            catch XenError.missingCredential { previousPassword = nil }
        }
        if configuration.mailEnabled && !configuration.username.isEmpty && password == nil && previousPassword == nil { throw XenError.invalid("请填写 SMTP 密码。") }
        if let password { try XenKeychain().save(password, for: configuration.id) }
        notificationConfiguration = configuration
        do { try persist(rules: rules, events: events) }
        catch {
            notificationConfiguration = previous
            if password != nil {
                if let previousPassword { try? XenKeychain().save(previousPassword, for: configuration.id) }
                else { try? XenKeychain().delete(for: configuration.id) }
            }
            throw error
        }
    }
    func save(_ rule: XenAlertRule) throws {
        guard rule.threshold.isFinite, rule.threshold >= 0, (rule.unit != "%" || rule.threshold <= 100), rule.duration >= 5, rule.duration <= 86400, !rule.name.isEmpty else { throw XenError.invalid("请填写有效阈值与持续时间。") }
        var updated = rules
        if let index = updated.firstIndex(where: { $0.id == rule.id }) { updated[index] = rule } else { updated.append(rule) }
        try persist(rules: updated, events: events)
        rules = updated
        windows = [:]
    }
    func remove(_ rule: XenAlertRule) {
        do { let updated = rules.filter { $0.id != rule.id }; try persist(rules: updated, events: events); rules = updated; windows = [:] }
        catch { self.error = error.localizedDescription }
    }
    func acknowledge(_ event: XenAlertEvent) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        var updated = events; updated[index].acknowledged = true
        do { try persist(rules: rules, events: updated); events = updated } catch { self.error = error.localizedDescription }
    }
    func observe(clusterID: UUID, poolUUID: String, samples: [XenMetricSample]) {
        let objects = Dictionary(grouping: samples, by: \.uuid)
        var changed = false
        let previousEvents = Set(events.map(\.id))
        for (uuid, values) in objects {
            let timestamps = Dictionary(grouping: values, by: \.timestamp)
            for rule in rules where rule.enabled {
                let key = "\(poolUUID):\(uuid):\(rule.id)"
                for time in timestamps.keys.sorted() {
                    let points = timestamps[time]!
                    if let previous = windows[key], time <= previous.last { continue }
                    guard let percent = metricValue(rule.metric ?? "cpu", samples: points) else { continue }
                    if percent > rule.threshold {
                        let window = windows[key]
                        let first = window.map { time - $0.last <= 15 ? $0.first : time } ?? time
                        windows[key] = (first, time)
                        if time - first >= rule.duration && !events.contains(where: { $0.poolUUID == poolUUID && $0.resourceUUID == uuid && $0.ruleID == rule.id && $0.recoveredAt == nil }) {
                            events.insert(XenAlertEvent(clusterID: clusterID, poolUUID: poolUUID, resourceUUID: uuid, ruleID: rule.id, title: "\(rule.name) · \(String(uuid.prefix(8)))", createdAt: Date(timeIntervalSince1970: time)), at: 0)
                            changed = true
                        }
                    } else {
                        windows[key] = (time, time)
                        for index in events.indices where events[index].poolUUID == poolUUID && events[index].resourceUUID == uuid && events[index].ruleID == rule.id && events[index].recoveredAt == nil && events[index].createdAt.timeIntervalSince1970 <= time {
                            events[index].recoveredAt = Date(timeIntervalSince1970: time); changed = true
                        }
                        // A normal sample must not count toward a later high window.
                        windows[key] = (time + 5, time)
                    }
                }
            }
        }
        if changed {
            events = Array(events.prefix(1000))
            do {
                try persist(rules: rules, events: events)
                let configuration = notificationConfiguration
                if configuration.mailEnabled || configuration.webhookEnabled {
                    for event in events where !previousEvents.contains(event.id) && event.recoveredAt == nil {
                        Task {
                            let status: String
                            do {
                                let password = configuration.mailEnabled && !configuration.username.isEmpty ? try? XenKeychain().password(for: configuration.id) : nil
                                status = try await XenNotifications.send(event, configuration: configuration, password: password)
                            } catch { status = "通知未确认送达，请检查配置；不会自动重复发送。" }
                            if let index = events.firstIndex(where: { $0.id == event.id }) {
                                events[index].deliveryStatus = status
                                do { try persist(rules: rules, events: events) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func metricValue(_ metric: String, samples: [XenMetricSample]) -> Double? {
        if metric == "cpu" {
            if let average = samples.first(where: { $0.metric == "cpu_avg" }) { return average.value * 100 }
            let cpus = samples.filter { $0.metric.hasPrefix("cpu") && !$0.metric.dropFirst(3).isEmpty && $0.metric.dropFirst(3).allSatisfy(\.isNumber) }
            return cpus.isEmpty ? nil : cpus.map(\.value).reduce(0, +) / Double(cpus.count) * 100
        }
        if metric == "memory" {
            guard let total = samples.first(where: { $0.metric == "memory_total_kib" })?.value,
                  let free = samples.first(where: { $0.metric == "memory_free_kib" })?.value, total > 0, free >= 0, free <= total else { return nil }
            return (total - free) / total * 100
        }
        let suffix = ["networkRx": "_rx", "networkTx": "_tx", "diskRead": "_read", "diskWrite": "_write"][metric] ?? "!"
        let network = metric.hasPrefix("network")
        let values = samples.filter { $0.metric.hasSuffix(suffix) && (network ? $0.metric.hasPrefix("pif_") || $0.metric.hasPrefix("vif_") : $0.metric.hasPrefix("vbd_") || $0.metric.hasPrefix("pbd_") || $0.metric.hasPrefix("sr_")) }
        guard !values.isEmpty else { return nil }
        let selected = values.contains(where: { $0.metric.hasPrefix("sr_") }) ? values.filter { $0.metric.hasPrefix("sr_") } : values
        return selected.map(\.value).reduce(0, +) / 1_048_576
    }
    private func persist(rules: [XenAlertRule], events: [XenAlertEvent]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(rules: rules, events: events, notifications: notificationConfiguration)).write(to: url, options: .atomic)
    }
}

struct XenAlertsView: View {
    @ObservedObject var center: XenAlertCenter
    @Environment(\.dismiss) private var dismiss
    @State private var editing: XenAlertRule?
    @State private var showsEditor = false
    @State private var showsNotifications = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("告警与规则").font(.title2.weight(.semibold)); Spacer(); Button("通知设置…") { showsNotifications = true }; Button("完成") { dismiss() } }
            Text("规则在已连接的集群中采样，每分钟评估持续阈值。断开连接后停止采样。")
                .font(.callout).foregroundStyle(.secondary)
            if let error = center.error { XenInlineError(message: error) }
            HStack {
                Text("规则").font(.headline); Spacer()
                Button("添加规则", systemImage: "plus") { editing = nil; showsEditor = true }
            }
            ForEach(center.rules) { rule in
                HStack {
                    Toggle(rule.name, isOn: Binding(get: { rule.enabled }, set: { enabled in var copy = rule; copy.enabled = enabled; do { try center.save(copy) } catch { center.error = error.localizedDescription } }))
                    Spacer()
                    Text("\(rule.metricTitle) > \(Int(rule.threshold))\(rule.unit) · \(Int(rule.duration)) 秒").foregroundStyle(.secondary)
                    Button("编辑") { editing = rule; showsEditor = true }
                    Button(role: .destructive) { center.remove(rule) } label: { Image(systemName: "trash") }
                }.font(.callout)
            }
            Divider()
            Text("历史").font(.headline)
            if center.events.isEmpty { Text("暂无告警").foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(center.events) { event in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).font(.callout.weight(.medium))
                                Text(event.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                if let status = event.deliveryStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(event.recoveredAt == nil ? "告警中" : "已恢复").foregroundStyle(event.recoveredAt == nil ? .orange : .secondary)
                            if !event.acknowledged { Button("确认") { center.acknowledge(event) } }
                        }
                    }
                }
            }.frame(minHeight: 160)
        }.padding(24).frame(width: 660, height: 520)
        .sheet(isPresented: $showsNotifications) { XenNotificationEditor(center: center) }
        .sheet(isPresented: $showsEditor) { XenAlertRuleEditor(center: center, initial: editing ?? XenAlertRule()) }
    }
}

private struct XenAlertRuleEditor: View {
    @ObservedObject var center: XenAlertCenter
    let initial: XenAlertRule
    @Environment(\.dismiss) private var dismiss
    @State private var rule = XenAlertRule()
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("告警规则").font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $rule.name)
                Picker("指标", selection: Binding(get: { rule.metric ?? "cpu" }, set: { rule.metric = $0 })) {
                    Text("CPU").tag("cpu"); Text("主机内存").tag("memory"); Text("网络接收").tag("networkRx"); Text("网络发送").tag("networkTx"); Text("磁盘读取").tag("diskRead"); Text("磁盘写入").tag("diskWrite")
                }
                TextField("阈值（\(rule.unit)）", value: $rule.threshold, format: .number)
                TextField("持续时间（秒）", value: $rule.duration, format: .number)
            }
            if let message { XenInlineError(message: message) }
            HStack { Spacer(); Button("取消", role: .cancel) { dismiss() }; Button("保存") { do { try center.save(rule); dismiss() } catch { message = error.localizedDescription } }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 420).onAppear { rule = initial }
    }
}

private struct XenNotificationEditor: View {
    @ObservedObject var center: XenAlertCenter
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = XenNotificationConfiguration()
    @State private var password = ""
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("告警通知").font(.title2.weight(.semibold))
            Form {
                Section("Webhook") {
                    Toggle("发送 Webhook", isOn: $configuration.webhookEnabled)
                    if configuration.webhookEnabled { TextField("HTTPS 地址", text: $configuration.webhookURL) }
                }
                Section("邮件") {
                    Toggle("发送邮件", isOn: $configuration.mailEnabled)
                    if configuration.mailEnabled {
                        TextField("SMTP 主机", text: $configuration.smtpHost)
                        TextField("TLS 端口", value: $configuration.smtpPort, format: .number)
                        Text("使用隐式 TLS，通常为 465 端口。密码保存到本机钥匙串。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("用户名", text: $configuration.username)
                        SecureField("密码（留空保留）", text: $password)
                        TextField("发件人", text: $configuration.sender)
                        TextField("收件人", text: $configuration.recipient)
                    }
                }
            }.formStyle(.grouped)
            if let message { XenInlineError(message: message) }
            HStack {
                Spacer(); Button("取消", role: .cancel) { dismiss() }
                Button("保存") {
                    do {
                        try center.saveNotifications(configuration, password: password.isEmpty ? nil : password)
                        dismiss()
                    } catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 520, height: 570)
        .onAppear { configuration = center.notificationConfiguration }
    }
}
