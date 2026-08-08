//
//  AppVersion.swift
//  inchspace
//

import Foundation

struct AppVersion {
    static var shortVersion: String {
        bundleValue(for: "CFBundleShortVersionString") ?? "未知"
    }

    static var buildVersion: String {
        bundleValue(for: "CFBundleVersion") ?? ""
    }

    static var displayVersion: String {
        guard !buildVersion.isEmpty else { return shortVersion }
        return "\(shortVersion) (\(buildVersion))"
    }

    static var appName: String {
        bundleValue(for: "CFBundleDisplayName")
            ?? bundleValue(for: "CFBundleName")
            ?? ProcessInfo.processInfo.processName
    }

    private static func bundleValue(for key: String) -> String? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }
}
