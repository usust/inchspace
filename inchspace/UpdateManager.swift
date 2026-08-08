//
//  UpdateManager.swift
//  inchspace
//
//  Owns the single Sparkle controller for the complete application lifetime.
//

import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateManager: ObservableObject {
    private static let placeholderPublicKeys = [
        "YOUR_SPARKLE_PUBLIC_ED25519_KEY",
        "SPARKLE_PUBLIC_KEY_REQUIRED",
    ]

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    private let updaterController: SPUStandardUpdaterController?

    var updater: SPUUpdater? {
        updaterController?.updater
    }

    var isConfigured: Bool {
        updaterController != nil
    }

    init(bundle: Bundle = .main) {
        guard Self.hasProductionUpdateConfiguration(in: bundle) else {
            updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller

        controller.updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates, options: [.initial, .new])
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updaterController?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = enabled
    }

    private static func hasProductionUpdateConfiguration(in bundle: Bundle) -> Bool {
        guard
            let feedURLString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let feedURL = URL(string: feedURLString),
            feedURL.scheme?.lowercased() == "https",
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            !placeholderPublicKeys.contains(publicKey),
            Data(base64Encoded: publicKey)?.count == 32
        else {
            return false
        }

        return true
    }
}
