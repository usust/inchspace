import XCTest
@testable import inchspace

@MainActor
final class ServerManagerTests: XCTestCase {
    func testServerLibraryRoundTrip() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-servers-\(UUID().uuidString).json")
        let persistence = ServerPersistence(fileURL: fileURL)
        let group = ServerGroup(name: "生产环境", order: 0)
        let tag = ServerTag(name: "Linux")
        let credential = SSHCredential(serverID: UUID(), authentication: .agent)
        let server = Server(
            name: "Ubuntu Server",
            host: "172.16.5.101",
            user: "lyu",
            groupID: group.id,
            tagIDs: [tag.id],
            credentialID: credential.id
        )

        try persistence.save(ServerLibrary(
            servers: [server],
            groups: [group],
            tags: [tag],
            credentials: [credential]
        ))
        let loaded = try persistence.loadOrMigrate()

        XCTAssertEqual(loaded.servers.first?.id, server.id)
        XCTAssertEqual(loaded.servers.first?.name, server.name)
        XCTAssertEqual(loaded.servers.first?.host, server.host)
        XCTAssertEqual(loaded.servers.first?.groupID, group.id)
        XCTAssertEqual(loaded.servers.first?.tagIDs, [tag.id])
        XCTAssertEqual(loaded.groups, [group])
        XCTAssertEqual(loaded.tags, [tag])
        XCTAssertEqual(loaded.credentials, [credential])
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testLegacyRunnerServersMigrateWithStableIDs() throws {
        let identifier = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-server-migration-\(UUID().uuidString)", isDirectory: true)
        let legacyURL = directory.appendingPathComponent("runner-library.json")
        let serverURL = directory.appendingPathComponent("server-manager.json")
        let legacyPersistence = RunnerPersistence(fileURL: legacyURL)
        let legacy = RunnerServer(
            id: identifier,
            name: "Legacy Host",
            host: "10.0.0.8",
            username: "deploy",
            authentication: .sshKey,
            keyPath: "/tmp/id_ed25519"
        )
        try legacyPersistence.save(RunnerLibrary(servers: [legacy]))

        let persistence = ServerPersistence(fileURL: serverURL, legacyPersistence: legacyPersistence)
        let migrated = try persistence.loadOrMigrate()

        XCTAssertEqual(migrated.servers.first?.id, identifier)
        XCTAssertEqual(migrated.servers.first?.user, "deploy")
        XCTAssertEqual(migrated.credentials.first?.serverID, identifier)
        XCTAssertEqual(migrated.credentials.first?.authentication, .sshKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: serverURL.path))
        try? FileManager.default.removeItem(at: directory)
    }

    func testSSHConfigurationImportSkipsWildcardsAndDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-ssh-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let libraryURL = directory.appendingPathComponent("server-manager.json")
        let configURL = directory.appendingPathComponent("config")
        let config = """
        Host production
          HostName 10.0.0.8
          User deploy
          Port 2202
          IdentityFile ~/.ssh/id_ed25519

        Host *
          ServerAliveInterval 60
        """
        try Data(config.utf8).write(to: configURL)

        let manager = ServerManager(persistence: ServerPersistence(fileURL: libraryURL))
        manager.importSSHConfiguration(from: configURL)
        manager.importSSHConfiguration(from: configURL)

        XCTAssertEqual(manager.servers.count, 1)
        XCTAssertEqual(manager.servers.first?.name, "production")
        XCTAssertEqual(manager.servers.first?.host, "10.0.0.8")
        XCTAssertEqual(manager.servers.first?.user, "deploy")
        XCTAssertEqual(manager.servers.first?.port, 2202)
        XCTAssertEqual(manager.credentials.first?.authentication, .sshKey)
        XCTAssertTrue(manager.credentials.first?.keyPath.hasSuffix("/.ssh/id_ed25519") == true)
        try? FileManager.default.removeItem(at: directory)
    }

    func testFavoritesAndGroupMovePersist() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-server-organizing-\(UUID().uuidString).json")
        let persistence = ServerPersistence(fileURL: fileURL)
        let manager = ServerManager(persistence: persistence)
        let group = manager.createGroup(named: "Development")!
        let credential = SSHCredential(serverID: UUID(), authentication: .agent)
        let server = Server(name: "Web Server", host: "10.0.0.10", user: "dev", credentialID: credential.id)

        manager.add(server, credential: credential, password: nil)
        manager.move(server, to: group.id)
        manager.toggleFavorite(server)

        let restored = ServerManager(persistence: persistence)
        XCTAssertEqual(restored.servers.first?.groupID, group.id)
        XCTAssertTrue(restored.favoriteServerIDs.contains(server.id))
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testCommonRemoteSystemsAreDetectedFromProbeValues() {
        XCTAssertEqual(ServerManager.detectSystem(kernel: "Linux", identifier: "ubuntu", like: "debian"), .ubuntu)
        XCTAssertEqual(ServerManager.detectSystem(kernel: "Linux", identifier: "rocky", like: "rhel,centos,fedora"), .rockyLinux)
        XCTAssertEqual(ServerManager.detectSystem(kernel: "Linux", identifier: "alpine", like: "none"), .alpineLinux)
        XCTAssertEqual(ServerManager.detectSystem(kernel: "Linux", identifier: "arch", like: "none"), .archLinux)
        XCTAssertEqual(ServerManager.detectSystem(kernel: "Darwin", identifier: "unknown", like: "none"), .macOS)
        XCTAssertEqual(ServerManager.detectSystem(kernel: "FreeBSD", identifier: "unknown", like: "none"), .freeBSD)
    }
}
