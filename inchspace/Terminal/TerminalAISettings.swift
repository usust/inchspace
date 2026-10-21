import Combine
import Foundation
import Security

@MainActor
final class TerminalAISettings: ObservableObject {
    @Published private(set) var configuration: TerminalAIConfiguration
    @Published private(set) var providerProfiles: [TerminalAIProviderProfile]
    @Published private(set) var activeProviderID: String
    @Published var terminalContextEnabled: Bool { didSet { save() } }
    @Published var recentOutputEnabled: Bool { didSet { save() } }
    @Published var secretRedactionEnabled: Bool { didSet { save() } }
    @Published var permission: TerminalAICommandPermission { didSet { save() } }
    @Published var sidebarWidth: Double { didSet { save() } }
    @Published private(set) var hasAPIKey = false
    @Published private(set) var keychainError: String?

    var model: String { configuration.model }

    private let defaults: UserDefaults
    private let keyStore: any TerminalAIKeyStore
    private var isLoading = true
    private enum Key {
        static let prefix = "terminal.ai."
        static let configuration = prefix + "configuration"
        static let profiles = prefix + "profiles"
        static let providerProfiles = prefix + "providerProfiles"
        static let activeProviderID = prefix + "activeProviderID"
        static let legacyModel = prefix + "deepSeekModel"
        static let context = prefix + "context"
        static let output = prefix + "recentOutput"
        static let redaction = prefix + "redaction"
        static let permission = prefix + "permission"
        static let width = prefix + "sidebarWidth"
    }

    init(defaults: UserDefaults = .standard, keyStore: (any TerminalAIKeyStore)? = nil) {
        self.defaults = defaults
        self.keyStore = keyStore ?? TerminalAIKeychain()
        let currentConfiguration: TerminalAIConfiguration
        if let data = defaults.data(forKey: Key.configuration),
           let stored = try? JSONDecoder().decode(TerminalAIConfiguration.self, from: data) {
            currentConfiguration = stored
        } else {
            currentConfiguration = TerminalAIConfiguration(model: defaults.string(forKey: Key.legacyModel) ?? "")
        }
        let legacyProfiles = defaults.data(forKey: Key.profiles)
            .flatMap { try? JSONDecoder().decode([String: TerminalAIConfiguration].self, from: $0) } ?? [:]
        let storedProfiles = defaults.data(forKey: Key.providerProfiles)
            .flatMap { try? JSONDecoder().decode([TerminalAIProviderProfile].self, from: $0) }
        var loadedProfiles: [TerminalAIProviderProfile]
        if let storedProfiles, !storedProfiles.isEmpty {
            loadedProfiles = storedProfiles
        } else {
            loadedProfiles = TerminalAIService.allCases.map { service in
                let configuration = currentConfiguration.service == service
                    ? currentConfiguration : legacyProfiles[service.rawValue]
                return .preset(service, configuration: configuration)
            }
        }
        let storedActiveID = defaults.string(forKey: Key.activeProviderID)
        let active = loadedProfiles.first(where: { $0.id == storedActiveID })
            ?? loadedProfiles.first(where: { $0.configuration == currentConfiguration })
            ?? TerminalAIProviderProfile(name: currentConfiguration.service.title, configuration: currentConfiguration)
        if !loadedProfiles.contains(where: { $0.id == active.id }) { loadedProfiles.append(active) }
        providerProfiles = loadedProfiles
        activeProviderID = active.id
        configuration = active.configuration
        terminalContextEnabled = defaults.object(forKey: Key.context) as? Bool ?? true
        recentOutputEnabled = defaults.object(forKey: Key.output) as? Bool ?? true
        secretRedactionEnabled = defaults.object(forKey: Key.redaction) as? Bool ?? true
        let storedPermission = TerminalAICommandPermission(rawValue: defaults.string(forKey: Key.permission) ?? "") ?? .askEveryTime
        permission = storedPermission == .autoApproveSession ? .askEveryTime : storedPermission
        let width = defaults.double(forKey: Key.width)
        sidebarWidth = width == 0 ? 380 : min(max(width, 320), 520)
        isLoading = false
        refreshKeyStatus()
        save()
    }

    func profile(for service: TerminalAIService) -> TerminalAIConfiguration {
        if configuration.service == service { return configuration }
        return providerProfiles.first { $0.configuration.service == service }?.configuration
            ?? TerminalAIConfiguration(service: service, baseURL: service.defaultBaseURL)
    }

    func apiKey(for baseURL: String? = nil) throws -> String {
        try keyStore.apiKey(account: Self.keyAccount(for: baseURL ?? configuration.baseURL))
    }

    func apply(_ draft: TerminalAIConfiguration, apiKeyDraft: String) throws {
        var provider = providerProfiles.first { $0.id == activeProviderID && $0.configuration.service == draft.service }
            ?? .preset(draft.service)
        provider.configuration = draft
        try saveProvider(provider, apiKeyDraft: apiKeyDraft)
    }

    /// Persist the key before changing the cards or active configuration, so a Keychain failure keeps the working setup.
    func saveProvider(_ draft: TerminalAIProviderProfile, apiKeyDraft: String) throws {
        var provider = draft
        provider.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.name.isEmpty else { throw TerminalAIError.provider("请输入提供商名称。") }
        provider.configuration = try draft.configuration.validated()
        let account = try Self.keyAccount(for: provider.configuration.baseURL)
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let hasKey: Bool
            if !key.isEmpty {
                try keyStore.saveAPIKey(key, account: account)
                hasKey = true
            } else {
                hasKey = try keyStore.apiKey(account: account).isEmpty == false
            }
            if let index = providerProfiles.firstIndex(where: { $0.id == provider.id }) {
                providerProfiles[index] = provider
            } else {
                providerProfiles.append(provider)
            }
            configuration = provider.configuration
            activeProviderID = provider.id
            hasAPIKey = hasKey
            keychainError = nil
            save()
        } catch {
            keychainError = error.localizedDescription
            throw error
        }
    }

    func activateProvider(id: String) throws {
        guard let provider = providerProfiles.first(where: { $0.id == id }) else { return }
        let validated: TerminalAIConfiguration
        do {
            validated = try provider.configuration.validated()
        } catch {
            throw TerminalAIError.provider("请先点击“详情”完成 \(provider.name) 的配置。")
        }
        let hasKey = try !apiKey(for: validated.baseURL).isEmpty
        configuration = validated
        activeProviderID = provider.id
        hasAPIKey = hasKey
        keychainError = nil
        save()
    }

    func removeAPIKey(for baseURL: String) throws {
        do {
            try keyStore.deleteAPIKey(account: Self.keyAccount(for: baseURL))
            keychainError = nil
            refreshKeyStatus()
        } catch {
            keychainError = error.localizedDescription
            throw error
        }
    }

    static func keyAccount(for baseURL: String) throws -> String {
        let normalized = try TerminalAIConfiguration.normalizedBaseURL(baseURL).absoluteString
        // Keep the original account for DeepSeek so existing installations need no credential migration.
        if normalized == TerminalAIService.deepSeek.defaultBaseURL { return "deepseek-api-key" }
        return "endpoint-" + Data(normalized.utf8).base64EncodedString()
    }

    private func refreshKeyStatus() {
        do {
            hasAPIKey = try !apiKey().isEmpty
            keychainError = nil
        } catch {
            hasAPIKey = false
            keychainError = error.localizedDescription
        }
    }

    private func save() {
        guard !isLoading else { return }
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Key.configuration) }
        if let data = try? JSONEncoder().encode(providerProfiles) { defaults.set(data, forKey: Key.providerProfiles) }
        defaults.set(activeProviderID, forKey: Key.activeProviderID)
        defaults.set(terminalContextEnabled, forKey: Key.context)
        defaults.set(recentOutputEnabled, forKey: Key.output)
        defaults.set(secretRedactionEnabled, forKey: Key.redaction)
        if permission != .autoApproveSession { defaults.set(permission.rawValue, forKey: Key.permission) }
        defaults.set(min(max(sidebarWidth, 320), 520), forKey: Key.width)
    }
}

protocol TerminalAIKeyStore {
    func apiKey(account: String) throws -> String
    func saveAPIKey(_ key: String, account: String) throws
    func deleteAPIKey(account: String) throws
}

struct TerminalAIKeychain: TerminalAIKeyStore {
    private static let service = "vip.lylab.inchspace.terminal-ai"

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    func saveAPIKey(_ key: String, account: String) throws {
        let query = query(account: account)
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecValueData as String] = Data(key.utf8)
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    func apiKey(account: String) throws -> String {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw keychainError(status) }
        return key
    }

    func deleteAPIKey(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "错误代码 \(status)"
        return NSError(domain: "TerminalAIKeychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法访问 macOS 钥匙串：\(detail)"])
    }
}
