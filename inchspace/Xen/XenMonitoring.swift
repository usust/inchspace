import Foundation
import SwiftUI
import Charts

nonisolated struct XenMetricSample: Identifiable, Codable, Sendable {
    var id: String { "\(uuid):\(metric):\(timestamp)" }
    let uuid: String
    let object: String
    let metric: String
    let timestamp: Double
    let value: Double
}

nonisolated enum XenRRD {
    static func decode(_ data: Data) throws -> [XenMetricSample] {
        guard data.count <= 10 * 1024 * 1024 else { throw XenError.invalid("监控响应过大。") }
        let delegate = XenRRDParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.root == "xport" else { throw XenError.invalid("监控 XML 格式无效。") }
        return delegate.samples
    }
}

private nonisolated final class XenRRDParser: NSObject, XMLParserDelegate {
    var samples: [XenMetricSample] = []
    var invalid = false
    var root = ""
    private var path: [String] = []
    private var text = ""
    private var legends: [String] = []
    private var values: [String] = []
    private var timestamp = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if path.isEmpty { root = name }
        guard path.count < 32 else { invalid = true; parser.abortParsing(); return }
        path.append(name); text = ""
        if name == "row" { values = []; timestamp = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "entry", path.contains("legend") { legends.append(value) }
        if name == "t", path.contains("row") { timestamp = value }
        if name == "v", path.contains("row") { values.append(value) }
        if name == "row" {
            guard values.count == legends.count, let time = Double(timestamp), time.isFinite else { invalid = true; parser.abortParsing(); return }
            for (legend, raw) in zip(legends, values) {
                let parts = legend.split(separator: ":", maxSplits: 3).map(String.init)
                guard parts.count == 4, parts[0] == "AVERAGE", ["host", "vm"].contains(parts[1]), let number = Double(raw), number.isFinite else { continue }
                samples.append(XenMetricSample(uuid: parts[2], object: parts[1], metric: parts[3], timestamp: time, value: number))
            }
        }
        _ = path.popLast(); text = ""
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
}

extension XenURLTransport {
    func get(_ url: URL, limit: Int = 10 * 1024 * 1024) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url), delegate: self)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw XenError.transport("无法读取监控数据。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw XenError.invalid("监控响应超过大小限制。") }
            data.append(byte)
        }
        return data
    }
}

extension XenClient {
    func monitoringEndpoint(_ record: XenRecord, identity expected: XenSessionIdentity) async throws -> URL {
        try requireIdentity(expected)
        let context = try authenticatedEndpoint()
        let hostRef: String
        if record.kind == .host { hostRef = record.id }
        else {
            let vm = try await self.record(.vm, ref: record.id)
            guard vm.uuid == record.uuid else { throw XenError.invalid("VM 身份已变化。") }
            hostRef = vm["resident_on"].string
        }
        let host = try await self.record(.host, ref: hostRef)
        guard !host["address"].string.isEmpty else { throw XenError.invalid("无法确定指标所属主机。") }
        var parts = URLComponents(url: context.0, resolvingAgainstBaseURL: false)!
        parts.host = host["address"].string
        parts.path = "/rrd_updates"
        parts.queryItems = [URLQueryItem(name: "session_id", value: context.1), URLQueryItem(name: "start", value: String(Int(Date().timeIntervalSince1970) - 600)), URLQueryItem(name: "cf", value: "AVERAGE"), URLQueryItem(name: "interval", value: "5"), URLQueryItem(name: "host", value: "true")]
        guard let url = parts.url else { throw XenError.invalid("监控地址无效。") }
        try requireIdentity(expected)
        return url
    }
}

struct XenMonitoringView: View {
    @ObservedObject var store: XenStore
    let cluster: XenCluster
    let record: XenRecord
    @State private var samples: [XenMetricSample] = []
    @State private var category = "CPU"
    @State private var range = 600.0
    private var visibleSamples: [XenMetricSample] { samples.filter { $0.timestamp >= Date().timeIntervalSince1970 - range } }
    private struct ChartPoint: Identifiable {
        var id: String { "\(time):\(series)" }
        let time: Double
        let series: String
        let value: Double
    }
    @State private var message: String?
    @State private var refreshing = false
    @State private var automatic = false
    @State private var updatedAt: Date?
    @State private var refreshID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    private var cpuSamples: [XenMetricSample] {
        let cpu = visibleSamples.filter { $0.metric == "cpu_avg" }
        if !cpu.isEmpty { return cpu.sorted { $0.timestamp < $1.timestamp } }
        let grouped = Dictionary(grouping: visibleSamples.filter { $0.metric.hasPrefix("cpu") && $0.metric.dropFirst(3).allSatisfy(\.isNumber) }, by: \.timestamp)
        return grouped.map { timestamp, values in
            XenMetricSample(uuid: record.uuid, object: record.kind == .host ? "host" : "vm", metric: "cpu_avg", timestamp: timestamp, value: values.map(\.value).reduce(0, +) / Double(values.count))
        }.sorted { $0.timestamp < $1.timestamp }
    }
    private var chartPoints: [ChartPoint] {
        if category == "CPU" { return cpuSamples.map { ChartPoint(time: $0.timestamp, series: "CPU", value: $0.value * 100) } }
        let grouped = Dictionary(grouping: visibleSamples, by: \.timestamp)
        var points: [ChartPoint] = []
        for time in grouped.keys.sorted() {
            let values = grouped[time]!
            if category == "内存" {
                if record.kind == .host,
                   let total = values.first(where: { $0.metric == "memory_total_kib" })?.value,
                   let free = values.first(where: { $0.metric == "memory_free_kib" })?.value, total >= free {
                    points.append(ChartPoint(time: time, series: "已用内存", value: (total - free) / 1_048_576))
                } else if let memory = values.first(where: { $0.metric == "memory" })?.value {
                    points.append(ChartPoint(time: time, series: "分配内存", value: memory / 1_073_741_824))
                }
            } else {
                for (suffix, title) in category == "网络" ? [("_rx", "接收"), ("_tx", "发送")] : [("_read", "读取"), ("_write", "写入")] {
                    let matching = values.filter { sample in
                        sample.metric.hasSuffix(suffix) && (category == "网络" ? sample.metric.hasPrefix("pif_") || sample.metric.hasPrefix("vif_") : sample.metric.hasPrefix("vbd_") || sample.metric.hasPrefix("pbd_") || sample.metric.hasPrefix("sr_"))
                    }
                    if !matching.isEmpty {
                        let selected = matching.contains(where: { $0.metric.hasPrefix("sr_") }) ? matching.filter { $0.metric.hasPrefix("sr_") } : matching
                        points.append(ChartPoint(time: time, series: title, value: selected.map(\.value).reduce(0, +) / 1_048_576))
                    }
                }
            }
        }
        return points
    }
    private var unit: String { category == "CPU" ? "%" : category == "内存" ? "GiB" : "MiB/s" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("性能趋势").font(.headline)
                Spacer()
                Toggle("自动刷新", isOn: $automatic).toggleStyle(.switch).controlSize(.small)
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).disabled(refreshing)
            }
            HStack {
                Picker("指标", selection: $category) { Text("CPU"); Text("内存"); Text("网络"); Text("磁盘") }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
                Spacer()
                Picker("时间范围", selection: $range) { Text("10 分钟").tag(600.0); Text("1 小时").tag(3600.0); Text("24 小时").tag(86400.0); Text("7 天").tag(604800.0) }.labelsHidden().fixedSize()
            }
            if let message { XenInlineError(message: message) }
            if chartPoints.isEmpty {
                Text(refreshing ? "正在读取主机指标…" : "暂无\(category)采样").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(chartPoints) { point in
                    LineMark(x: .value("时间", Date(timeIntervalSince1970: point.time)), y: .value(category, point.value))
                        .foregroundStyle(by: .value("指标", point.series)).interpolationMethod(.linear)
                }
                .chartYScale(domain: 0...(category == "CPU" ? 100 : max(1, (chartPoints.map(\.value).max() ?? 1) * 1.1)))
                .chartYAxisLabel(unit).frame(height: 170)
                .accessibilityLabel("\(category)趋势")
                if category == "内存" && record.isVM { Text("显示主机分配给 VM 的内存，不代表来宾已用内存。").font(.caption).foregroundStyle(.secondary) }
            }
            if let updatedAt { Text("更新于 \(updatedAt, style: .time)").font(.caption).foregroundStyle(.tertiary) }
        }
        .task(id: refreshID) { await load() }
        .task(id: automatic) {
            guard automatic else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                if scenePhase == .active { await load() }
            }
        }
    }
    private func load() async {
        guard !refreshing, let client = store.connectionClient(cluster.id), let identity = store.connectionIdentity(cluster.id) else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let endpoint = try await client.monitoringEndpoint(record, identity: identity)
            let data = try await XenURLTransport(allowsUntrustedCertificate: cluster.allowsUntrustedCertificate).get(endpoint)
            try await client.requireIdentity(identity)
            let object = record.kind == .host ? "host" : "vm"
            let current = try XenRRD.decode(data)
            let history = try await store.metricHistory.merge(current, clusterID: cluster.id, poolUUID: identity.poolUUID)
            try await client.requireIdentity(identity)
            guard !Task.isCancelled else { return }
            samples = history.filter { $0.uuid == record.uuid && $0.object == object }; message = nil; updatedAt = Date()
        } catch {
            if !Task.isCancelled { message = "无法更新性能指标；保留上次数据。" }
        }
    }
}
