import Foundation
import XCTest
@testable import inchspace

@MainActor
final class AppLanguageFilterTests: XCTestCase {
    private func application(_ path: String, _ identifier: String? = nil) -> LanguageApplication {
        LanguageApplication(url: URL(fileURLWithPath: path), name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                            bundleIdentifier: identifier, languages: [])
    }

    func testAppleIdentifiersIncludeHelpersAndSeparatelyInstalledApps() {
        XCTAssertTrue(application("/Library/Image Capture/Support/LegacyDeviceDiscoveryHelpers/AirScanLegacyDiscovery.app",
                                  "com.apple.print.AirScanLegacyDiscovery").isAppleApplication)
        XCTAssertTrue(application("/Applications/Xcode.app", "com.apple.dt.Xcode").isAppleApplication)
        XCTAssertTrue(application("/Applications/Pages.app", "com.apple.iWork.Pages").isAppleApplication)
        XCTAssertTrue(application("/Applications/Safari.app", "com.apple.Safari").isAppleApplication)
        XCTAssertTrue(application("/Users/example/Applications/Notes.app", "com.apple.Notes").isAppleApplication)
    }

    func testAppleClassificationRetainsSystemLocationsAsFallback() {
        for path in ["/System/Applications/Notes.app", "/System/Library/CoreServices/Finder.app",
                     "/System/Cryptexes/App/System/Applications/Safari.app",
                     "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"] {
            XCTAssertTrue(application(path).isAppleApplication, path)
        }
    }

    func testUserClassificationRespectsIdentifierAndPathBoundaries() {
        let identifiers: [String?] = [nil, "", "com.apple", "com.appleish.Editor", "com.apples.Editor",
                                      "org.example.com.apple.Editor"]
        for identifier in identifiers {
            XCTAssertFalse(application("/Applications/Editor.app", identifier).isAppleApplication, identifier ?? "nil")
        }
        XCTAssertFalse(application("/Users/example/Applications/Other.app").isAppleApplication)
        XCTAssertFalse(application("/System/Applications-copy/Other.app").isAppleApplication)
        XCTAssertFalse(application("/Library/Application Support/Other.app", "org.example.Other").isAppleApplication)
    }

    func testFiltersPartitionEveryApplicationAndUseNewLabels() {
        let apps = [application("/Applications/Xcode.app", "com.apple.dt.Xcode"),
                    application("/Library/Image Capture/Support/AirScanLegacyDiscovery.app", "com.apple.print.AirScanLegacyDiscovery"),
                    application("/System/Applications/Notes.app"),
                    application("/Applications/Other.app", "org.example.Other")]
        for app in apps {
            XCTAssertTrue(AppLanguageFilter.all.includes(app))
            XCTAssertNotEqual(AppLanguageFilter.apple.includes(app), AppLanguageFilter.user.includes(app))
        }
        XCTAssertEqual(AppLanguageFilter.apple.title, "APPLE")
        XCTAssertEqual(AppLanguageFilter.user.title, "USER")
    }

    func testLanguageActionsDoNotRunDuringScan() async {
        let model = AppLanguageViewModel()
        let app = application("/System/Library/ExampleBackground.app")
        model.applications = [app]
        model.selection = app.id
        model.preferenceReadable = true
        model.savedLanguage = "en"
        model.selectedLanguage = "fr"
        model.isScanning = true

        await model.save(restart: true)
        XCTAssertNil(model.error)
        XCTAssertNil(model.status)
        XCTAssertFalse(model.isSaving)
        await model.restartSelectedApplication()
        XCTAssertNil(model.error)
        XCTAssertNil(model.status)
        XCTAssertFalse(model.isRestarting)
        XCTAssertEqual(model.selectedLanguage, "fr")
        XCTAssertEqual(model.savedLanguage, "en")
    }

    func testFilterCombinesWithSearchAndReconcilesSelection() {
        let model = AppLanguageViewModel()
        let notes = application("/System/Applications/Notes.app", "com.apple.Notes")
        let other = application("/Applications/Other Notes.app", "org.example.notes")
        model.applications = [notes, other]
        model.selection = notes.id
        model.search = " notes "
        XCTAssertEqual(model.filteredApplications.count, 2)
        model.filter = .user
        XCTAssertEqual(model.filteredApplications.map(\.id), [other.id])
        XCTAssertEqual(model.selection, other.id)
        model.search = "missing"
        XCTAssertTrue(model.filteredApplications.isEmpty)
        XCTAssertNil(model.selection)
        model.search = ""
        XCTAssertEqual(model.selection, other.id)
        model.filter = .all
        XCTAssertEqual(model.selection, other.id)
        model.filter = .apple
        XCTAssertEqual(model.selection, notes.id)
        model.applications = [other]
        model.reconcileSelection()
        XCTAssertNil(model.selection)
    }
}
