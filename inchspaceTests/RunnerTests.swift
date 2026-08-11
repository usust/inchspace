import XCTest
@testable import inchspace

@MainActor
final class RunnerTests: XCTestCase {
    func testRunnerLibraryRoundTrip() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-runner-\(UUID().uuidString).json")
        let persistence = RunnerPersistence(fileURL: fileURL)
        let task = RunnerTask(
            name: "Preview Server",
            command: "swift run",
            workingDirectoryPath: "/tmp",
            launchMode: .background,
            environment: [RunnerEnvironmentVariable(key: "PORT", value: "8080")],
            port: 8080,
            isFavorite: true
        )
        let server = RunnerServer(
            name: "Production",
            host: "10.0.0.2",
            username: "deploy",
            authentication: .sshKey,
            keyPath: "/tmp/id_ed25519"
        )
        let service = RunnerManagedService(
            identifier: "actions.runner.example",
            displayName: "Example Runner",
            kind: .launchd
        )

        try persistence.save(RunnerLibrary(tasks: [task], servers: [server], managedServices: [service]))
        let loaded = try persistence.load()

        XCTAssertEqual(loaded.tasks.count, 1)
        XCTAssertEqual(loaded.tasks.first?.id, task.id)
        XCTAssertEqual(loaded.tasks.first?.name, task.name)
        XCTAssertEqual(loaded.tasks.first?.command, task.command)
        XCTAssertEqual(loaded.tasks.first?.launchMode, .background)
        XCTAssertEqual(loaded.tasks.first?.environment, task.environment)
        XCTAssertEqual(loaded.tasks.first?.port, 8080)
        XCTAssertEqual(loaded.tasks.first?.isFavorite, true)
        XCTAssertEqual(loaded.servers, [server])
        XCTAssertEqual(loaded.managedServices, [service])
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testLegacyServerConfigurationDefaultsToSSHKey() throws {
        let json = """
        {"name":"Legacy","host":"10.0.0.3","username":"root","port":22,"keyPath":"/tmp/id_rsa"}
        """
        let server = try JSONDecoder().decode(RunnerServer.self, from: Data(json.utf8))
        XCTAssertEqual(server.authentication, .sshKey)
    }

    func testLaunchctlRowExtractsServiceIdentifier() {
        XCTAssertEqual(
            RunnerServiceIdentifierParser.parse("672\t0\tactions.runner.usust-inchspace.MacbookProM2Max"),
            "actions.runner.usust-inchspace.MacbookProM2Max"
        )
        XCTAssertEqual(RunnerServiceIdentifierParser.parse("com.example.worker"), "com.example.worker")
        XCTAssertNil(RunnerServiceIdentifierParser.parse("   "))
    }

    func testLaunchctlGUIPrintParsesRunnerService() {
        let output = """
        gui/501 = {
            services = {
                         531      -  com.apple.syncdefaultsd
                         672      -  actions.runner.usust-inchspace.MacbookProM2Max
                           0      0  com.example.stopped
            }
            disabled services = {
                "actions.runner.usust-inchspace.MacbookProM2Max" => enabled
            }
        }
        """

        let services = LocalRunnerServiceManager.parseLaunchdDomain(output, includeAppleServices: true)
        let runner = services.first { $0.identifier == "actions.runner.usust-inchspace.MacbookProM2Max" }
        XCTAssertEqual(runner?.state, .running)
        XCTAssertEqual(runner?.detail, "PID 672")
        XCTAssertEqual(services.first { $0.identifier == "com.example.stopped" }?.state, .stopped)
    }

    func testShortTaskCapturesLogsAndExitCode() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-runner-\(UUID().uuidString).json")
        let store = RunnerStore(persistence: RunnerPersistence(fileURL: fileURL))
        let task = RunnerTask(
            name: "Health Check",
            command: "printf 'runner-ready\\n'",
            workingDirectoryPath: "/tmp",
            launchMode: .temporary,
            environment: []
        )
        store.add(task)
        store.start(task.id)

        for _ in 0..<50 {
            if store.snapshots[task.id]?.lastExitCode != nil { break }
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertEqual(store.snapshots[task.id]?.lastExitCode, 0)
        XCTAssertTrue(store.snapshots[task.id]?.logs.contains(where: { $0.message.contains("runner-ready") }) == true)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
