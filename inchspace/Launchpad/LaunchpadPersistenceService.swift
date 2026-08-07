//
//  LaunchpadPersistenceService.swift
//  inchspace
//

import Foundation

struct LaunchpadPersistenceService {
    let fileURL: URL

    var modificationDate: Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }

        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = baseURL
            .appendingPathComponent("vip.lylab.inchspace", isDirectory: true)
            .appendingPathComponent("launchpad-library.json", isDirectory: false)
    }

    func load() throws -> LaunchpadLibrary? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        if let library = try? LaunchpadJSONCodec.decode(LaunchpadLibrary.self, from: data) {
            return library
        }

        // Pre-launchpad builds stored the shortcut list as a top-level array.
        // Keep that format readable and let the repository normalize it once.
        let legacyItems = try LaunchpadJSONCodec.decode([LaunchItem].self, from: data)
        return LaunchpadLibrary(version: 0, items: legacyItems)
    }

    func save(_ library: LaunchpadLibrary) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try LaunchpadJSONCodec.encode(library)
        try data.write(to: fileURL, options: .atomic)
    }
}

enum LaunchpadJSONCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
