import Foundation
import CryptoKit

actor XenMetricHistory {
    private let root: URL
    private var cache: [String: [XenMetricSample]] = [:]
    init(root: URL) { self.root = root }
    private func key(_ clusterID: UUID, _ poolUUID: String) -> String {
        SHA256.hash(data: Data("\(clusterID.uuidString):\(poolUUID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func merge(_ samples: [XenMetricSample], clusterID: UUID, poolUUID: String) throws -> [XenMetricSample] {
        let key = key(clusterID, poolUUID)
        let file = root.appendingPathComponent(key + ".json")
        var existing = cache[key]
        if existing == nil, FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 64 * 1024 * 1024 else { throw XenError.invalid("本地监控历史超过大小限制。") }
            existing = try JSONDecoder().decode([XenMetricSample].self, from: data)
        }
        let cutoff = Date().timeIntervalSince1970 - 7 * 86400
        var index: [String: XenMetricSample] = [:]
        for point in (existing ?? []) + samples where point.timestamp >= cutoff && point.value.isFinite && point.timestamp.isFinite {
            index[point.id] = point
        }
        let merged = Array(index.values.sorted { $0.timestamp < $1.timestamp }.suffix(100_000))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(merged).write(to: file, options: .atomic)
        cache[key] = merged
        return merged
    }
}
