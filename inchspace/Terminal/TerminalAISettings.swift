import Combine
import Foundation
import Security

@MainActor
final class TerminalAISettings: ObservableObject {
    @Published var model: String { didSet { save() } }
    @Published var terminalContextEnabled: Bool { didSet { save() } }
    @Published var recentOutputEnabled: Bool { didSet { save() } }
    @Published var secretRedactionEnabled: Bool { didSet { save() } }
    @Published var permission: TerminalAICommandPermission { didSet { save() } }
    @Published var sidebarWidth: Double { didSet { save() } }
    @Published private(set) var hasAPIKey = false
    @Published var keychainError: String?

    private let defaults: UserDefaults
    private var isLoading = true
    private enum Key {
        static let prefix = "terminal.ai."
        static let model = prefix + "deepSeekModel"
        static let context = prefix + "context"
        static let output = prefix + "recentOutput"
        static let redaction = prefix + "redaction"
        static let permission = prefix + "permission"
        static let width = prefix + "sidebarWidth"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = defaults.string(forKey: Key.model) ?? ""
        terminalContextEnabled = defaults.object(forKey: Key.context) as? Bool ?? true
        recentOutputEnabled = defaults.object(forKey: Key.output) as? Bool ?? true
        secretRedactionEnabled = defaults.object(forKey: Key.redaction) as? Bool ?? true
        let storedPermission = TerminalAICommandPermission(rawValue: defaults.string(forKey: Key.permission) ?? "") ?? .askEveryTime
        permission = storedPermission == .autoApproveSession ? .askEveryTime : storedPermission
        let width = defaults.double(forKey: Key.width)
        sidebarWidth = width == 0 ? 380 : min(max(width, 320), 520)
        isLoading = false
        hasAPIKey = (try? TerminalAIKeychain.apiKey())?.isEmpty == false
    }

    func apiKey() throws -> String { try TerminalAIKeychain.apiKey() }

    func setAPIKey(_ value: String) {
        do {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TerminalAIKeychain.deleteAPIKey()
                hasAPIKey = false
            } else {
                try TerminalAIKeychain.saveAPIKey(value.trimmingCharacters(in: .whitespacesAndNewlines))
                hasAPIKey = true
            }
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(model, forKey: Key.model)
        defaults.set(terminalContextEnabled, forKey: Key.context)
        defaults.set(recentOutputEnabled, forKey: Key.output)
        defaults.set(secretRedactionEnabled, forKey: Key.redaction)
        if permission != .autoApproveSession { defaults.set(permission.rawValue, forKey: Key.permission) }
        defaults.set(min(max(sidebarWidth, 320), 520), forKey: Key.width)
    }
}

enum TerminalAIKeychain {
    private static let service = "vip.lylab.inchspace.terminal-ai"
    private static let account = "deepseek-api-key"

    static func saveAPIKey(_ key: String) throws {
        deleteAPIKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(key.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    static func apiKey() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw keychainError(status) }
        return key
    }

    static func deleteAPIKey() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "错误代码 \(status)"
        return NSError(domain: "TerminalAIKeychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法访问 macOS 钥匙串：\(detail)"])
    }
}
