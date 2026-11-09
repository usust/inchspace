import Foundation
import Security

nonisolated struct XenPersistence {
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vip.lylab.inchspace/xen-clusters.json")
    }
    func load() throws -> [XenCluster] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let clusters = try JSONDecoder().decode([XenCluster].self, from: Data(contentsOf: url))
        guard Set(clusters.map(\.id)).count == clusters.count else { throw XenError.invalid("集群配置存在重复标识。") }
        for cluster in clusters { _ = try cluster.endpoint() }
        return clusters
    }
    func save(_ clusters: [XenCluster]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(clusters)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

nonisolated protocol XenCredentialStorage {
    func password(for id: UUID) throws -> String
    func save(_ password: String, for id: UUID) throws
    func delete(for id: UUID) throws
}

nonisolated struct XenKeychain: XenCredentialStorage {
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "vip.lylab.inchspace.xen", kSecAttrAccount as String: id.uuidString]
    }
    func password(for id: UUID) throws -> String {
        var lookup = query(id)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { throw XenError.missingCredential }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw XenError.invalid("无法读取集群凭据（\(status)）。")
        }
        return value
    }
    func save(_ password: String, for id: UUID) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id).merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw XenError.invalid("无法保存集群凭据（\(result)）。") }
        } else if status != errSecSuccess { throw XenError.invalid("无法更新集群凭据（\(status)）。") }
    }
    func delete(for id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw XenError.invalid("无法移除集群凭据（\(status)）。") }
    }
}
