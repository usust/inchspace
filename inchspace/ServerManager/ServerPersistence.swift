import Foundation

struct ServerPersistence {
    let fileURL: URL
    let legacyPersistence: RunnerPersistence

    nonisolated init(fileURL: URL? = nil, legacyPersistence: RunnerPersistence = RunnerPersistence()) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? base
            .appendingPathComponent("vip.lylab.inchspace", isDirectory: true)
            .appendingPathComponent("server-manager.json")
        self.legacyPersistence = legacyPersistence
    }

    func loadOrMigrate() throws -> ServerLibrary {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ServerLibrary.self, from: Data(contentsOf: fileURL))
        }

        let legacy = try legacyPersistence.load()
        guard !legacy.servers.isEmpty else { return ServerLibrary() }
        let migrated = migrate(legacy.servers)
        try save(migrated)
        return migrated
    }

    func save(_ library: ServerLibrary) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: fileURL, options: .atomic)
    }

    private func migrate(_ legacyServers: [RunnerServer]) -> ServerLibrary {
        var credentials: [SSHCredential] = []
        let servers = legacyServers.map { legacy in
            let credential = SSHCredential(
                id: legacy.id,
                serverID: legacy.id,
                authentication: legacy.authentication == .password ? .password : .sshKey,
                keyPath: legacy.keyPath,
                keyBookmark: legacy.keyBookmark
            )
            credentials.append(credential)
            return Server(
                id: legacy.id,
                name: legacy.name,
                host: legacy.host,
                user: legacy.username,
                port: legacy.port,
                credentialID: credential.id
            )
        }
        return ServerLibrary(servers: servers, credentials: credentials)
    }
}

enum SSHCredentialStore {
    static func savePassword(_ password: String, for serverID: UUID) throws {
        try RunnerServerCredentialStore.savePassword(password, for: serverID)
    }

    static func deletePassword(for serverID: UUID) {
        RunnerServerCredentialStore.deletePassword(for: serverID)
    }
}
