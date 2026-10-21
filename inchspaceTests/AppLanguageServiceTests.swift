import Foundation
import XCTest
@testable import inchspace

final class AppLanguageServiceTests: XCTestCase {
    private let service = AppLanguageService()

    func testScanIncludesNestedApplicationsAndDeduplicatesPaths() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root.appending(path: "Utilities/Example.app"))
        _ = try makeApp(at: app.url.appending(path: "Contents/Helper.app"))
        let result = service.scan(roots: [root], additionalURLs: [app.url], useSpotlight: false)
        XCTAssertEqual(result.applications.count, 1)
        XCTAssertEqual(result.applications.first?.id, app.id)
        XCTAssertEqual(Set(result.applications.first?.languages ?? []), Set(["en", "zh-Hans", "ja"]))
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testRejectsNonApplication() {
        XCTAssertThrowsError(try service.inspect(URL(fileURLWithPath: "/tmp")))
    }

    func testSaveAndResetPreserveOtherPreferences() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root.appending(path: "Language Test.app"))
        let domain = try XCTUnwrap(app.bundleIdentifier) as CFString
        defer {
            for key in ["AppleLanguages", "UnrelatedSetting"] {
                CFPreferencesSetValue(key as CFString, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        CFPreferencesSetValue("UnrelatedSetting" as CFString, "retained" as CFString, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        XCTAssertNil(try service.overrideLanguages(for: app.bundleIdentifier!))
        try service.setLanguage("zh-Hans", for: app)
        XCTAssertEqual(try service.overrideLanguages(for: app.bundleIdentifier!), ["zh-Hans"])
        XCTAssertThrowsError(try service.setLanguage("fr", for: app))
        XCTAssertEqual(try service.overrideLanguages(for: app.bundleIdentifier!), ["zh-Hans"])
        try service.setLanguage(nil, for: app)
        XCTAssertNil(try service.overrideLanguages(for: app.bundleIdentifier!))
        XCTAssertEqual(CFPreferencesCopyValue("UnrelatedSetting" as CFString, domain,
                                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String, "retained")
    }

    func testRejectsGlobalAndPathDomains() {
        for identifier in ["", "NSGlobalDomain", "kCFPreferencesAnyApplication", "/tmp/test.plist", "-g"] {
            XCTAssertThrowsError(try service.overrideLanguages(for: identifier))
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "inchspace-language-\(UUID().uuidString)")
    }

    private func makeApp(at url: URL) throws -> LanguageApplication {
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources/Base.lproj"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "vip.lylab.inchspace.tests.language.\(UUID().uuidString)",
            "CFBundleName": "Language Test",
            "CFBundlePackageType": "APPL",
            "CFBundleLocalizations": ["en", "zh-Hans", "ja", "Base"],
            "CFBundleDevelopmentRegion": "en"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        return try service.inspect(url)
    }
}
