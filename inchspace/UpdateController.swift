//
//  UpdateController.swift
//  inchspace
//
//  Owns Sparkle for the complete application lifetime.
//

import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    private static let placeholderPublicKey = "SPARKLE_PUBLIC_KEY_REQUIRED"

    private let updaterController: SPUStandardUpdaterController?

    var canCheckForUpdates: Bool {
        updaterController != nil
    }

    init(bundle: Bundle = .main) {
        guard Self.hasProductionUpdateConfiguration(in: bundle) else {
            updaterController = nil
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    private static func hasProductionUpdateConfiguration(in bundle: Bundle) -> Bool {
        guard
            let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            URL(string: feedURL)?.scheme == "https",
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            publicKey != placeholderPublicKey,
            Data(base64Encoded: publicKey)?.count == 32
        else {
            return false
        }

        return true
    }
}
