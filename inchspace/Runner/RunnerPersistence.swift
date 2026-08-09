import Foundation

struct RunnerPersistence {
    let fileURL: URL

    nonisolated init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("vip.lylab.inchspace", isDirectory: true)
                .appendingPathComponent("runner-library.json")
        }
    }

    func load() throws -> RunnerLibrary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return RunnerLibrary() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RunnerLibrary.self, from: Data(contentsOf: fileURL))
    }

    func save(_ library: RunnerLibrary) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: fileURL, options: .atomic)
    }
}
