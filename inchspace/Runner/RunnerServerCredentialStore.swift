import Foundation
import Security

enum RunnerServerCredentialStore {
    private static let service = "vip.lylab.inchspace.runner-server"

    static func savePassword(_ password: String, for serverID: UUID) throws {
        let account = serverID.uuidString
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(lookup as CFDictionary)

        var item = lookup
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw credentialError(status) }
    }

    static func password(for serverID: UUID) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            if status == errSecItemNotFound {
                throw RunnerError.processFailed("未找到该服务器的密码，请移除后重新添加服务器。")
            }
            throw credentialError(status)
        }
        return password
    }

    static func deletePassword(for serverID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func credentialError(_ status: OSStatus) -> RunnerError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "错误代码 \(status)"
        return .processFailed("无法访问 macOS 钥匙串：\(detail)")
    }
}
