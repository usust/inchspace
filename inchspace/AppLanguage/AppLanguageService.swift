import Foundation

struct LanguageApplication: Identifiable, Hashable, Sendable {
    nonisolated var id: String { url.path }
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let languages: [String]

    /// UI grouping only: Apple identifiers include separately installed apps and helpers.
    /// System locations provide a fallback for apps without an Apple identifier.
    nonisolated var isAppleApplication: Bool {
        if bundleIdentifier?.hasPrefix("com.apple.") == true { return true }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let systemRoots = ["/System/Applications/", "/System/Library/", "/System/Cryptexes/",
                           "/System/Volumes/Preboot/Cryptexes/"]
        return systemRoots.contains(where: { path.hasPrefix($0) })
    }

    nonisolated static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

struct ApplicationScan: Sendable {
    let applications: [LanguageApplication]
    let warnings: [String]
}

struct AppLanguageService: Sendable {
    nonisolated static var defaultRoots: [URL] {
        ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
         NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
    }

    nonisolated func inspect(_ url: URL) throws -> LanguageApplication {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let info = bundle.infoDictionary, info["CFBundlePackageType"] as? String == "APPL" else {
            throw LanguageError.invalidApplication
        }
        let codes = bundle.localizations + [bundle.developmentLocalization].compactMap { $0 }
        let languages = Array(Set(codes.filter { !$0.isEmpty && $0.lowercased() != "base" }))
            .sorted { LanguageApplication.languageName($0).localizedStandardCompare(LanguageApplication.languageName($1)) == .orderedAscending }
        return LanguageApplication(
            url: url,
            name: [bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                   bundle.object(forInfoDictionaryKey: "CFBundleName") as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) }
                .first { !$0.isEmpty } ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundle.bundleIdentifier,
            languages: languages
        )
    }

    nonisolated func scan(roots: [URL] = Self.defaultRoots, additionalURLs: [URL] = [], useSpotlight: Bool = true) -> ApplicationScan {
        var urls = additionalURLs
        var warnings: [String] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            if let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, _ in
                    warnings.append("无法读取：\(url.path)")
                    return true
                }
            ) {
                for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                    urls.append(url)
                }
            }
        }
        if useSpotlight {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-0", "kMDItemContentType == 'com.apple.application-bundle'"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    urls += String(decoding: data, as: UTF8.self).split(separator: "\0").map { URL(fileURLWithPath: String($0)) }
                } else {
                    warnings.append("Spotlight 不可用，已扫描标准应用目录。")
                }
            } catch {
                warnings.append("Spotlight 不可用，已扫描标准应用目录。")
            }
        }
        var seen = Set<String>()
        let applications = urls.compactMap { url -> LanguageApplication? in
            // Ignore helper apps embedded in another application bundle.
            let path = url.resolvingSymlinksInPath().standardizedFileURL
            guard !path.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
                  seen.insert(path.path).inserted else { return nil }
            return try? inspect(path)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ApplicationScan(applications: applications, warnings: Array(Set(warnings)).sorted())
    }

    nonisolated private func validateDomain(_ identifier: String) throws {
        guard !identifier.isEmpty, identifier.contains("."),
              !identifier.contains("/"), !identifier.hasPrefix("-"),
              !["NSGlobalDomain", "Apple Global Domain", "kCFPreferencesAnyApplication"].contains(identifier) else {
            throw LanguageError.invalidIdentifier
        }
    }

    nonisolated func overrideLanguages(for identifier: String) throws -> [String]? {
        try validateDomain(identifier)
        guard CFPreferencesSynchronize(identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw LanguageError.preferencesUnavailable
        }
        // Exact domain: global language preferences must not appear as an app override.
        return CFPreferencesCopyValue("AppleLanguages" as CFString, identifier as CFString,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
    }

    nonisolated func setLanguage(_ language: String?, for app: LanguageApplication) throws {
        guard let identifier = app.bundleIdentifier else { throw LanguageError.invalidIdentifier }
        try validateDomain(identifier)
        if let language, !app.languages.contains(language) { throw LanguageError.unsupportedLanguage }
        let previous = try overrideLanguages(for: identifier)
        let value = language.map { [$0] }
        CFPreferencesSetValue("AppleLanguages" as CFString, value as CFArray?, identifier as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              try overrideLanguages(for: identifier) == value else {
            CFPreferencesSetValue("AppleLanguages" as CFString, previous as CFArray?, identifier as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            throw LanguageError.saveFailed
        }
    }
}

enum LanguageError: LocalizedError {
    case invalidApplication, invalidIdentifier, unsupportedLanguage, preferencesUnavailable, saveFailed

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidApplication: "无法读取此应用，请选择有效的 .app 文件。"
        case .invalidIdentifier: "此应用没有有效的应用标识，无法单独设置语言。"
        case .unsupportedLanguage: "应用未声明支持此语言。"
        case .preferencesUnavailable: "无法读取应用语言设置，请在系统设置的“语言与地区”中检查。"
        case .saveFailed: "语言设置未能保存，请在系统设置的“语言与地区”中修改。"
        }
    }
}

/// User-facing scope for the installed application list.
enum AppLanguageFilter: String, CaseIterable, Identifiable {
    case all, apple, user

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部"
        case .apple: "APPLE"
        case .user: "USER"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .all: "全部应用"
        case .apple: "Apple 应用"
        case .user: "用户应用"
        }
    }

    func includes(_ app: LanguageApplication) -> Bool {
        switch self {
        case .all: true
        case .apple: app.isAppleApplication
        case .user: !app.isAppleApplication
        }
    }
}
