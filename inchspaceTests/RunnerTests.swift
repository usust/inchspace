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

    func testEditingTaskPreservesConfigurationAndUpdatesOriginal() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-runner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let persistence = RunnerPersistence(fileURL: fileURL)
        let store = RunnerStore(persistence: persistence)
        let original = RunnerTask(
            name: "Preview Server",
            command: "swift run",
            workingDirectoryPath: "/tmp",
            workingDirectoryBookmark: Data([1, 2, 3]),
            launchMode: .background,
            environment: [RunnerEnvironmentVariable(key: "PORT", value: "8080")],
            port: 8080,
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.add(original)
        let request = RunnerTaskEditorRequest(task: original)
        XCTAssertEqual(request.task, original)

        var draft = try XCTUnwrap(request.task)
        draft.name = "Updated Server"
        draft.command = "swift run server"
        draft.port = 9090
        XCTAssertEqual(store.tasks, [original], "Editing a draft must not change the saved task.")

        request.save(draft, to: store)

        XCTAssertEqual(store.tasks, [draft])
        XCTAssertEqual(store.tasks.first?.id, original.id)
        XCTAssertEqual(store.tasks.first?.createdAt, original.createdAt)
        XCTAssertEqual(store.tasks.first?.workingDirectoryBookmark, original.workingDirectoryBookmark)
        XCTAssertEqual(store.tasks.first?.environment, original.environment)
        XCTAssertEqual(store.tasks.first?.isFavorite, true)
        XCTAssertNotNil(store.snapshots[original.id])
        XCTAssertEqual(try persistence.load().tasks, [draft])
    }

    func testEditorRequestsHaveFreshIdentityAndSeparateCreationFromEditing() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-runner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RunnerStore(persistence: RunnerPersistence(fileURL: fileURL))
        let task = RunnerTask(
            name: "New Task",
            command: "pwd",
            workingDirectoryPath: "/tmp",
            launchMode: .temporary,
            environment: []
        )
        let creation = RunnerTaskEditorRequest(task: nil)
        XCTAssertNil(creation.task)
        creation.save(task, to: store)
        XCTAssertEqual(store.tasks, [task])

        let edit = RunnerTaskEditorRequest(task: task)
        let reopened = RunnerTaskEditorRequest(task: task)
        let nextCreation = RunnerTaskEditorRequest(task: nil)
        XCTAssertNotEqual(edit.id, creation.id)
        XCTAssertNotEqual(edit.id, reopened.id)
        XCTAssertNotEqual(creation.id, nextCreation.id)
        XCTAssertNil(nextCreation.task)
        XCTAssertEqual(reopened.task, task)
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
        XCTAssertEqual(runner?.serviceName, "usust-inchspace")
        XCTAssertEqual(runner?.instanceName, "MacbookProM2Max")
        XCTAssertEqual(services.first { $0.identifier == "com.example.stopped" }?.state, .stopped)
        XCTAssertEqual(runner?.isSystemService, false)
    }

    func testLaunchctlSystemPrintMarksLaunchDaemonAsSystemService() {
        let output = """
        system = {
            services = {
                     55538      0  ddns-go
                         0      -  com.example.stopped
            }
        }
        """

        let services = LocalRunnerServiceManager.parseLaunchdDomain(
            output,
            includeAppleServices: true,
            isSystemService: true
        )
        let ddns = services.first { $0.identifier == "ddns-go" }
        XCTAssertEqual(ddns?.state, .running)
        XCTAssertEqual(ddns?.detail, "PID 55538")
        XCTAssertEqual(ddns?.isSystemService, true)
        XCTAssertEqual(ddns?.id, "launchd:system:ddns-go")
    }

    func testLaunchctlNonzeroLastExitStatusIsFailed() {
        let output = """
        gui/501 = {
            services = {
                0  78  com.example.failed
            }
        }
        """

        let services = LocalRunnerServiceManager.parseLaunchdDomain(output, includeAppleServices: true)
        XCTAssertEqual(services.first?.state, .failed)
    }

    func testOrdinaryServiceKeepsItsDisplayName() {
        let service = RunnerService(
            identifier: "com.example.worker",
            displayName: "Worker",
            kind: .launchd,
            state: .running
        )

        XCTAssertEqual(service.serviceName, "Worker")
        XCTAssertNil(service.instanceName)
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

        // A completed task must already contain its final output.
        for _ in 0..<100 {
            let snapshot = store.snapshots[task.id]
            if snapshot?.lastExitCode != nil { break }
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertEqual(store.snapshots[task.id]?.lastExitCode, 0)
        XCTAssertTrue(store.snapshots[task.id]?.logs.contains(where: { $0.message.contains("runner-ready") }) == true)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testManualStopPreservesExitCodeWithoutReportingFailure() async throws {
        try await withStoppableTask { store, task in
            store.stop(task.id)
            try await self.waitForRunner { store.snapshots[task.id]?.lastExitCode != nil }

            let snapshot = try XCTUnwrap(store.snapshots[task.id])
            XCTAssertEqual(snapshot.state, .stopped)
            XCTAssertEqual(snapshot.lastExitCode, 143)
            XCTAssertNil(snapshot.pid)
            XCTAssertEqual(store.runningCount, 0)
            XCTAssertEqual(snapshot.logs.last?.message, "任务已停止。")
            XCTAssertEqual(snapshot.logs.last?.isError, false)
            XCTAssertFalse(snapshot.logs.contains { $0.message.contains("任务异常结束") })
        }
    }

    func testRestartDoesNotReportFailureOrHideNextRunFailure() async throws {
        try await withStoppableTask { store, task in
            var updated = task
            updated.command = "exit 7"
            store.update(updated)
            store.restart(task.id)
            try await self.waitForRunner { store.snapshots[task.id]?.lastExitCode == 7 }

            let snapshot = try XCTUnwrap(store.snapshots[task.id])
            XCTAssertEqual(snapshot.state, .failed)
            XCTAssertTrue(snapshot.logs.contains { $0.message == "任务已停止。" && !$0.isError })
            let failures = snapshot.logs.filter { $0.message.contains("任务异常结束") }
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(failures.first?.message, "任务异常结束（代码 7）。")
            XCTAssertEqual(failures.first?.isError, true)
        }
    }

    func testExit143WithoutStopRequestStillReportsFailure() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-runner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RunnerStore(persistence: RunnerPersistence(fileURL: fileURL))
        let task = RunnerTask(
            name: "Nonzero Exit", command: "exit 143", workingDirectoryPath: "/tmp",
            launchMode: .temporary, environment: []
        )
        store.add(task)
        store.start(task.id)
        try await waitForRunner { store.snapshots[task.id]?.lastExitCode != nil }

        XCTAssertEqual(store.snapshots[task.id]?.state, .failed)
        XCTAssertEqual(store.snapshots[task.id]?.lastExitCode, 143)
        XCTAssertEqual(store.snapshots[task.id]?.logs.last?.isError, true)
    }

    private func withStoppableTask(
        _ body: (RunnerStore, RunnerTask) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunnerStore(persistence: RunnerPersistence(fileURL: root.appendingPathComponent("tasks.json")))
        let task = RunnerTask(
            name: "Stoppable Task",
            command: """
            trap 'exit 143' TERM
            : > stop-test-ready
            SECONDS=0
            while (( SECONDS < 10 )); do /bin/sleep 0.05; done
            """,
            workingDirectoryPath: root.path,
            launchMode: .temporary,
            environment: [RunnerEnvironmentVariable(key: "ZDOTDIR", value: root.path)]
        )
        store.add(task)
        store.start(task.id)
        defer { store.stop(task.id) }
        try await waitForRunner {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("stop-test-ready").path)
        }
        try await body(store, task)
    }

    private func waitForRunner(_ condition: () -> Bool) async throws {
        for _ in 0..<125 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Timed out waiting for runner state")
        throw NSError(domain: "RunnerTests", code: 1)
    }

    func testCommandsRunInSelectedDirectoryAfterLoginProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-runner-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("project's folder $test")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "cd /\nexport PATH=/usr/bin:/bin\n".write(
            to: profiles.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8
        )
        let executable = directory.appendingPathComponent("runner-local-tool")
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$1\"\ncat marker.txt\n".write(
            to: executable, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "selected-directory-marker\n".write(
            to: directory.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8
        )

        let commands = [
            "runner-local-tool 'argument with spaces'",
            "./runner-local-tool 'argument with spaces'",
            "printf '%s\\n' \"$PWD\" 'argument with spaces' | cat; cat marker.txt"
        ]
        let tasks = zip(RunnerLaunchMode.allCases, commands).map { mode, command in
            RunnerTask(
                name: "Directory check \(mode.rawValue)",
                command: command,
                workingDirectoryPath: directory.path,
                launchMode: mode,
                environment: [RunnerEnvironmentVariable(key: "ZDOTDIR", value: profiles.path)]
            )
        }
        let persistence = RunnerPersistence(fileURL: root.appendingPathComponent("library.json"))
        try persistence.save(RunnerLibrary(tasks: tasks, servers: [], managedServices: []))
        let store = RunnerStore(persistence: persistence)
        for task in tasks { store.start(task.id) }
        for _ in 0..<250 {
            if tasks.allSatisfy({ store.snapshots[$0.id]?.lastExitCode != nil }) { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        for task in tasks {
            let snapshot = try XCTUnwrap(store.snapshots[task.id])
            XCTAssertEqual(snapshot.lastExitCode, 0, task.command)
            let output = snapshot.logs.map(\.message).joined(separator: "\n")
            XCTAssertTrue(output.contains(directory.resolvingSymlinksInPath().path), output)
            XCTAssertTrue(output.contains("argument with spaces"), output)
            XCTAssertTrue(output.contains("selected-directory-marker"), output)
        }
    }

    func testRapidTasksDrainBothStreamsBeforeReportingExit() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-runner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RunnerStore(persistence: RunnerPersistence(fileURL: fileURL))
        let tasks = (0..<12).map { index in
            RunnerTask(
                name: "Quick task \(index)",
                command: "printf 'stdout-\(index)\\n'; printf 'stderr-\(index)\\n' >&2",
                workingDirectoryPath: "/tmp",
                launchMode: .temporary,
                environment: []
            )
        }
        for task in tasks {
            store.add(task)
            store.start(task.id)
        }
        var pending = Set(tasks.map(\.id))
        for _ in 0..<250 {
            for (index, task) in tasks.enumerated() where pending.contains(task.id) {
                guard let snapshot = store.snapshots[task.id], let exitCode = snapshot.lastExitCode else { continue }
                XCTAssertEqual(exitCode, 0)
                XCTAssertTrue(snapshot.logs.contains { $0.message == "stdout-\(index)" && !$0.isError })
                XCTAssertTrue(snapshot.logs.contains { $0.message == "stderr-\(index)" && $0.isError })
                pending.remove(task.id)
            }
            if pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertTrue(pending.isEmpty, "All short tasks should finish and preserve both output streams.")
    }

}
