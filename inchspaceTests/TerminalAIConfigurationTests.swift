import XCTest
@testable import inchspace

final class TerminalAIConfigurationTests: XCTestCase {
    func testRequestsUseConfiguredPrefixModelAndCredential() throws {
        let configuration = TerminalAIConfiguration(service: .custom, baseURL: " https://EXAMPLE.com/gateway/v1/// ", model: " my-model ")
        let provider = OpenAICompatibleProvider(configuration: configuration, apiKey: "test-key")
        let chat = try provider.chatRequest(messages: [.init(role: "user", content: "hello")])
        let models = try TerminalAIModelService().modelsRequest(baseURL: configuration.baseURL, apiKey: "test-key")

        XCTAssertEqual(chat.url?.absoluteString, "https://example.com/gateway/v1/chat/completions")
        XCTAssertEqual(models.url?.absoluteString, "https://example.com/gateway/v1/models")
        XCTAssertEqual(chat.httpMethod, "POST")
        XCTAssertEqual(chat.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(models.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(chat.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "my-model")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "hello")
    }

    func testUnauthenticatedLocalServiceDoesNotSendBearerHeader() throws {
        let configuration = TerminalAIConfiguration(service: .ollama, baseURL: TerminalAIService.ollama.defaultBaseURL, model: "local-model")
        let chat = try OpenAICompatibleProvider(configuration: configuration, apiKey: "").chatRequest(messages: [])
        let models = try TerminalAIModelService().modelsRequest(baseURL: configuration.baseURL, apiKey: "")
        XCTAssertEqual(chat.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(chat.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(models.value(forHTTPHeaderField: "Authorization"))
    }

    func testInvalidBaseURLsAndBlankModelsAreRejected() {
        for value in ["", "api.example.com/v1", "file:///secret", "https://user:pass@example.com", "https://example.com/v1?key=secret", "https://example.com/#fragment", "https://example.com/v1/models/", "https://example.com/v1/chat/completions"] {
            XCTAssertThrowsError(try TerminalAIConfiguration.normalizedBaseURL(value), value)
        }
        XCTAssertThrowsError(try TerminalAIConfiguration(model: " \n ").validated())
    }

    func testModelListRemovesBlankAndDuplicateIDsAndRejectsWrongProtocol() throws {
        let data = Data(#"{"data":[{"id":" model-b "},{"id":"model-a"},{"id":"model-b"},{"id":" "}]}"#.utf8)
        XCTAssertEqual(try TerminalAIModelService.decodeModels(from: data), ["model-a", "model-b"])
        XCTAssertThrowsError(try TerminalAIModelService.decodeModels(from: Data(#"{"models":[]}"#.utf8)))
    }

    func testLegacyDeepSeekConfigurationAndCredentialRemainUsable() throws {
        try withSettings { defaults, store in
            defaults.set("existing-model", forKey: "terminal.ai.deepSeekModel")
            store.keys["deepseek-api-key"] = "legacy-secret"
            let settings = TerminalAISettings(defaults: defaults, keyStore: store)
            XCTAssertEqual(settings.configuration.service, .deepSeek)
            XCTAssertEqual(settings.configuration.baseURL, "https://api.deepseek.com")
            XCTAssertEqual(settings.model, "existing-model")
            XCTAssertEqual(try settings.apiKey(), "legacy-secret")
            XCTAssertTrue(settings.hasAPIKey)
        }
    }

    func testAppliedProfilesPersistAndKeysAreIsolatedByEndpoint() throws {
        try withSettings { defaults, store in
            let settings = TerminalAISettings(defaults: defaults, keyStore: store)
            let first = TerminalAIConfiguration(service: .deepSeek, model: "first")
            let second = TerminalAIConfiguration(service: .custom, baseURL: "https://example.com/proxy/v1/", model: "second")
            try settings.apply(first, apiKeyDraft: "first-key")
            try settings.apply(second, apiKeyDraft: "second-key")

            let restored = TerminalAISettings(defaults: defaults, keyStore: store)
            XCTAssertEqual(restored.configuration, try second.validated())
            XCTAssertEqual(restored.profile(for: .deepSeek), first)
            XCTAssertEqual(try restored.apiKey(), "second-key")
            XCTAssertEqual(try restored.apiKey(for: first.baseURL), "first-key")
            XCTAssertEqual(try restored.apiKey(for: "https://another.example.com/v1"), "")
            XCTAssertEqual(try restored.apiKey(for: "https://example.com/different/v1"), "")
            try restored.apply(first, apiKeyDraft: "")
            XCTAssertEqual(try restored.apiKey(), "first-key", "空白输入应保留同一地址的已保存密钥")
            try restored.removeAPIKey(for: second.baseURL)
            XCTAssertEqual(try restored.apiKey(for: second.baseURL), "")
            XCTAssertEqual(try restored.apiKey(), "first-key")
            XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("first-key"))
            XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("second-key"))
        }
    }

    func testFailedKeySaveDoesNotActivateDraftOrDiscardOldKey() throws {
        try withSettings { defaults, store in
            let settings = TerminalAISettings(defaults: defaults, keyStore: store)
            try settings.apply(.init(model: "working"), apiKeyDraft: "working-key")
            store.failWrites = true
            XCTAssertThrowsError(try settings.apply(.init(service: .custom, baseURL: "https://example.com/v1", model: "new"), apiKeyDraft: "new-key"))
            XCTAssertEqual(settings.model, "working")
            XCTAssertEqual(settings.configuration.service, .deepSeek)
            XCTAssertEqual(try settings.apiKey(), "working-key")
            XCTAssertEqual(TerminalAISettings(defaults: defaults, keyStore: store).model, "working")
        }
    }

    func testLocalProfileCanBeAppliedWithoutKeyAndInvalidDraftDoesNotChangeSettings() throws {
        try withSettings { defaults, store in
            let settings = TerminalAISettings(defaults: defaults, keyStore: store)
            let local = TerminalAIConfiguration(service: .ollama, baseURL: TerminalAIService.ollama.defaultBaseURL, model: "local-model")
            try settings.apply(local, apiKeyDraft: "")
            XCTAssertEqual(settings.configuration, local)
            XCTAssertFalse(settings.hasAPIKey)
            XCTAssertThrowsError(try settings.apply(.init(service: .custom, baseURL: "invalid", model: "new"), apiKeyDraft: "secret"))
            XCTAssertEqual(settings.configuration, local)
            XCTAssertTrue(store.keys.isEmpty)
        }
    }

    func testStreamingContentIncludesRefusalsAndSurfacesProviderErrors() throws {
        XCTAssertEqual(try OpenAICompatibleProvider.streamContent(from: #"{"choices":[{"delta":{"content":"hello"}}]}"#), "hello")
        XCTAssertEqual(try OpenAICompatibleProvider.streamContent(from: #"{"choices":[{"delta":{"content":null,"refusal":"Request declined"}}]}"#), "Request declined")
        XCTAssertThrowsError(try OpenAICompatibleProvider.streamContent(from: #"{"error":{"message":"Model unavailable"}}"#)) { error in
            XCTAssertEqual(error.localizedDescription, "Model unavailable")
        }
    }

    func testApplyingEnteredKeyDoesNotRequireASecondKeychainRead() throws {
        try withSettings { defaults, store in
            let settings = TerminalAISettings(defaults: defaults, keyStore: store)
            store.failReads = true
            try settings.apply(.init(model: "replacement"), apiKeyDraft: "replacement-key")
            XCTAssertEqual(settings.model, "replacement")
            XCTAssertTrue(settings.hasAPIKey)
            XCTAssertEqual(store.keys["deepseek-api-key"], "replacement-key")
        }
    }

    func testMultipleProvidersOfSameTypePersistAndSwitchIndependently() throws {
        try withSettings { defaults, store in
            let settings = TerminalAISettings(defaults: defaults, keyStore: store)
            let first = TerminalAIProviderProfile(name: "工作服务", configuration: .init(service: .custom, baseURL: "https://work.example.com/v1", model: "work-model"))
            var second = TerminalAIProviderProfile(name: "个人服务", configuration: .init(service: .custom, baseURL: "https://personal.example.com/v1", model: "personal-model"))
            let presetCount = settings.providerProfiles.count
            try settings.saveProvider(first, apiKeyDraft: "work-key")
            try settings.saveProvider(second, apiKeyDraft: "personal-key")
            second.name = "个人备用服务"
            second.configuration.model = "updated-model"
            try settings.saveProvider(second, apiKeyDraft: "")

            let restored = TerminalAISettings(defaults: defaults, keyStore: store)
            XCTAssertEqual(restored.providerProfiles.count, presetCount + 2)
            XCTAssertEqual(restored.providerProfiles.first { $0.id == first.id }, first)
            XCTAssertEqual(restored.providerProfiles.first { $0.id == second.id }, second)
            XCTAssertEqual(restored.activeProviderID, second.id)
            XCTAssertEqual(restored.model, "updated-model")
            XCTAssertEqual(try restored.apiKey(), "personal-key")
            try restored.activateProvider(id: first.id)
            XCTAssertEqual(restored.configuration, first.configuration)
            XCTAssertEqual(try restored.apiKey(), "work-key")
            let reloaded = TerminalAISettings(defaults: defaults, keyStore: store)
            XCTAssertEqual(reloaded.activeProviderID, first.id)
            XCTAssertEqual(reloaded.configuration, first.configuration)
            XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("work-key"))
            XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("personal-key"))
        }
    }

    func testLegacyProfilesMigrateWithoutLosingInactiveConfigurationsOrKeys() throws {
        try withSettings { defaults, store in
            let active = TerminalAIConfiguration(service: .custom, baseURL: "https://existing.example.com/v1", model: "current-model")
            let inactive = TerminalAIConfiguration(service: .openAI, baseURL: "https://proxy.example.com/v1", model: "saved-model")
            defaults.set(try JSONEncoder().encode(active), forKey: "terminal.ai.configuration")
            defaults.set(try JSONEncoder().encode(["openAI": inactive]), forKey: "terminal.ai.profiles")
            store.keys[try TerminalAISettings.keyAccount(for: active.baseURL)] = "existing-key"
            let settings = TerminalAISettings(defaults: defaults, keyStore: store)
            XCTAssertEqual(settings.providerProfiles.count, TerminalAIService.allCases.count)
            XCTAssertEqual(settings.configuration, active)
            XCTAssertEqual(settings.profile(for: .openAI), inactive)
            XCTAssertEqual(try settings.apiKey(), "existing-key")
            let activeID = settings.activeProviderID
            let restored = TerminalAISettings(defaults: defaults, keyStore: store)
            XCTAssertEqual(restored.activeProviderID, activeID)
            XCTAssertEqual(restored.providerProfiles, settings.providerProfiles)
        }
    }

    func testUnconfiguredProviderAndKeychainFailureKeepActiveProviderAndCards() throws {
        try withSettings { defaults, store in
            let settings = TerminalAISettings(defaults: defaults, keyStore: store)
            try settings.apply(.init(model: "working"), apiKeyDraft: "working-key")
            let activeID = settings.activeProviderID
            let profiles = settings.providerProfiles
            let unconfigured = try XCTUnwrap(profiles.first { $0.configuration.service == .custom })
            XCTAssertThrowsError(try settings.activateProvider(id: unconfigured.id))
            XCTAssertEqual(settings.activeProviderID, activeID)
            XCTAssertEqual(settings.model, "working")

            let newProvider = TerminalAIProviderProfile(name: "新服务", configuration: .init(service: .custom, baseURL: "https://new.example.com/v1", model: "new-model"))
            store.failWrites = true
            XCTAssertThrowsError(try settings.saveProvider(newProvider, apiKeyDraft: "new-key"))
            XCTAssertEqual(settings.providerProfiles, profiles)
            XCTAssertEqual(settings.activeProviderID, activeID)
            XCTAssertEqual(TerminalAISettings(defaults: defaults, keyStore: store).providerProfiles, profiles)

            store.failWrites = false
            store.failReads = true
            let local = TerminalAIProviderProfile(name: "本地服务", configuration: .init(service: .ollama, baseURL: TerminalAIService.ollama.defaultBaseURL, model: "local"))
            XCTAssertThrowsError(try settings.saveProvider(local, apiKeyDraft: ""))
            XCTAssertEqual(settings.providerProfiles, profiles)
            XCTAssertEqual(settings.activeProviderID, activeID)
        }
    }

    func testInvalidProviderNameDoesNotCreateCardOrWriteCredential() throws {
        try withSettings { defaults, store in
            let settings = TerminalAISettings(defaults: defaults, keyStore: store)
            let profiles = settings.providerProfiles
            let invalid = TerminalAIProviderProfile(name: " \n ", configuration: .init(service: .custom, baseURL: "https://example.com/v1", model: "model"))
            XCTAssertThrowsError(try settings.saveProvider(invalid, apiKeyDraft: "secret"))
            XCTAssertEqual(settings.providerProfiles, profiles)
            XCTAssertTrue(store.keys.isEmpty)
        }
    }

    private func withSettings(_ body: (UserDefaults, MemoryAIKeyStore) throws -> Void) rethrows {
        let suite = "TerminalAIConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, MemoryAIKeyStore())
    }
}

private final class MemoryAIKeyStore: TerminalAIKeyStore {
    var keys: [String: String] = [:]
    var failWrites = false
    var failReads = false

    func apiKey(account: String) throws -> String {
        if failReads { throw TerminalAIError.provider("Keychain read unavailable") }
        return keys[account] ?? ""
    }
    func saveAPIKey(_ key: String, account: String) throws {
        if failWrites { throw TerminalAIError.provider("Keychain unavailable") }
        keys[account] = key
    }
    func deleteAPIKey(account: String) throws { keys.removeValue(forKey: account) }
}
