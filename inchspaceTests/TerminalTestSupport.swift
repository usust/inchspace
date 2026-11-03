import XCTest
@testable import inchspace

@MainActor
enum TerminalTestSupport {
    static func makeManager(preferences: TerminalPreferences, testCase: XCTestCase) -> TerminalManager {
        let suiteName = "TerminalTestSupport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        testCase.addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let settings = TerminalAISettings(defaults: defaults, keyStore: EmptyKeyStore())
        return TerminalManager(preferences: preferences, aiSettings: settings)
    }

    private struct EmptyKeyStore: TerminalAIKeyStore {
        func apiKey(account: String) throws -> String { "" }
        func saveAPIKey(_ key: String, account: String) throws {}
        func deleteAPIKey(account: String) throws {}
    }
}
