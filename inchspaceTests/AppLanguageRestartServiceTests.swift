import Foundation
import XCTest
@testable import inchspace

@MainActor
final class AppLanguageRestartServiceTests: XCTestCase {
    private var app: LanguageApplication {
        LanguageApplication(url: URL(fileURLWithPath: "/Applications/Language Test.app"),
                            name: "Language Test", bundleIdentifier: "test.language.restart", languages: ["en"])
    }

    func testWaitsForNormalExitBeforeOpeningExactURL() async throws {
        var events: [String] = []
        var terminated = false
        let targetURL = app.url
        let service = AppLanguageRestartService(
            runningApplications: { url in
                XCTAssertEqual(url, targetURL)
                return [.init(terminate: { events.append("quit"); return true }, isTerminated: { terminated })]
            },
            openApplication: { url in
                XCTAssertEqual(url, targetURL)
                XCTAssertTrue(terminated)
                events.append("open")
            },
            pause: { events.append("wait"); terminated = true }
        )
        try await service.restart(app)
        XCTAssertEqual(events, ["quit", "wait", "open"])
    }

    func testNotRunningOpensDirectly() async throws {
        var opened = false
        let service = AppLanguageRestartService(runningApplications: { _ in [] }, openApplication: { _ in opened = true })
        try await service.restart(app)
        XCTAssertTrue(opened)
    }

    func testDeclinedQuitDoesNotReopen() async {
        let service = AppLanguageRestartService(
            runningApplications: { _ in [.init(terminate: { false }, isTerminated: { false })] },
            openApplication: { _ in XCTFail("Must not reopen when quitting was declined") }
        )
        do { try await service.restart(app); XCTFail("Expected error") }
        catch RestartError.quitDeclined { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testTimeoutDoesNotReopenOrForceTerminate() async {
        var quitCount = 0
        let service = AppLanguageRestartService(
            runningApplications: { _ in [.init(terminate: { quitCount += 1; return true }, isTerminated: { false })] },
            openApplication: { _ in XCTFail("Must not reopen while still running") },
            pause: {}, maximumWaits: 2
        )
        do { try await service.restart(app); XCTFail("Expected timeout") }
        catch RestartError.quitTimedOut { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(quitCount, 1)
    }

    func testOpenFailureIsReported() async {
        let service = AppLanguageRestartService(runningApplications: { _ in [] }, openApplication: { _ in throw CocoaError(.fileNoSuchFile) })
        do { try await service.restart(app); XCTFail("Expected open error") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileNoSuchFile.rawValue) }
    }

    func testSystemServicesCannotBeRestarted() {
        let serviceApp = LanguageApplication(url: URL(fileURLWithPath: "/System/Library/CoreServices/AuthorizationPromptService.app"),
                                             name: "Service", bundleIdentifier: "test.service", languages: [])
        XCTAssertNotNil(AppLanguageRestartService.unavailableReason(for: serviceApp))
        XCTAssertNil(AppLanguageRestartService.unavailableReason(for: app))
    }
}
