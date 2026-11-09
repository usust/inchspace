import XCTest
@testable import inchspace

final class XenProtocolTests: XCTestCase {
    func testNestedXMLRPCRoundTripAndEscaping() throws {
        let value = XenValue.dictionary([
            "label<&": .string("开发 & <测试> \"引号\" '单引号'"),
            "large": .integer(9_223_372_036_854_775_000),
            "list": .array([.bool(true), .bool(false), .double(1.25), .null]),
        ])
        let xml = "<methodResponse><params><param>\(XenXMLRPC.encode(value))</param></params></methodResponse>"
        XCTAssertEqual(try XenXMLRPC.decode(Data(xml.utf8)), value)
    }
    func testXAPIEnvelopesAndErrorParameters() throws {
        XCTAssertEqual(try XenXMLRPC.result(response(.string("OpaqueRef:session"))), .string("OpaqueRef:session"))
        XCTAssertThrowsError(try XenXMLRPC.result(failure("HOST_IS_SLAVE", ["192.0.2.1"]))) { error in
            XCTAssertEqual(error as? XenError, .api("HOST_IS_SLAVE", ["192.0.2.1"]))
        }
    }
    func testRejectsMalformedResponsesAndEntities() {
        for xml in [
            "<html>login page</html>",
            "<methodResponse><params><param><value><boolean>true</boolean></value></param></params></methodResponse>",
            "<methodResponse><params><param><value><i8>99999999999999999999999</i8></value></param></params></methodResponse>",
            "<!DOCTYPE a [<!ENTITY x 'expanded'>]><methodResponse><params><param><value>&x;</value></param></params></methodResponse>",
            "<methodResponse><params><param><value><struct><member><name>a</name><value>1</value></member><member><name>a</name><value>2</value></member></struct></value></param></params></methodResponse>"
        ] { XCTAssertThrowsError(try XenXMLRPC.decode(Data(xml.utf8)), xml) }
    }
    func testEndpointValidation() throws {
        for address in ["https://192.0.2.10", "https://[::1]:443", "http://xen.example:80/"] {
            XCTAssertNoThrow(try XenCluster(name: "Lab", address: address).endpoint())
        }
        for address in ["xen.example", "file:///etc/passwd", "https://root:password@xen.example", "https://xen.example/path", "https://xen.example?token=1", "https://xen.example:99999"] {
            XCTAssertThrowsError(try XenCluster(name: "Lab", address: address).endpoint())
        }
    }
    func testVMPowerGuardsAndControlDomains() {
        let vm = vmRecord(state: "Halted", allowed: ["start", "destroy"])
        XCTAssertTrue(XenPowerAction.start.available(for: vm))
        XCTAssertFalse(XenPowerAction.shutdown.available(for: vm))
        var fields = vm.fields
        fields["is_control_domain"] = .bool(true)
        XCTAssertFalse(XenPowerAction.start.available(for: XenRecord(id: vm.id, kind: .vm, fields: fields)))
        fields = vm.fields
        fields["blocked_operations"] = .dictionary(["start": .string("maintenance")])
        XCTAssertFalse(XenPowerAction.start.available(for: XenRecord(id: vm.id, kind: .vm, fields: fields)))
        fields = vm.fields
        fields["current_operations"] = .dictionary(["task": .string("snapshot")])
        XCTAssertFalse(XenPowerAction.start.available(for: XenRecord(id: vm.id, kind: .vm, fields: fields)))
    }
    func testEveryProtectedCapabilityFailsClosed() {
        for capability in XenProtectedCapability.allCases { XCTAssertThrowsError(try capability.requireAvailable()) }
    }
    func testMemoryConstraints() {
        XCTAssertNoThrow(try XenMemoryConfiguration(staticMin: 1, dynamicMin: 2, dynamicMax: 3, staticMax: 4).validate())
        XCTAssertThrowsError(try XenMemoryConfiguration(staticMin: 2, dynamicMin: 1, dynamicMax: 3, staticMax: 4).validate())
        XCTAssertThrowsError(try XenMemoryConfiguration(staticMin: 1, dynamicMin: 2, dynamicMax: 5, staticMax: 4).validate())
    }
    func testPersistenceContainsNoSecretsAndValidatesDuplicates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = XenPersistence(url: folder.appendingPathComponent("clusters.json"))
        XCTAssertEqual(try persistence.load(), [])
        let cluster = XenCluster(name: "Lab", address: "https://192.0.2.10")
        try persistence.save([cluster])
        XCTAssertEqual(try persistence.load(), [cluster])
        let json = try String(contentsOf: persistence.url, encoding: .utf8)
        XCTAssertFalse(json.contains("password"))
        try persistence.save([cluster, cluster])
        XCTAssertThrowsError(try persistence.load())
    }
    func testLoginFallbackSessionOrderAndMasterRedirect() async throws {
        let wire = XenScriptedTransport([
            failure("HOST_IS_SLAVE", ["master.example"]),
            failure("MESSAGE_PARAMETER_COUNT_MISMATCH"),
            response(.string("OpaqueRef:session")),
            poolResponse(), response(.dictionary([:])), response(.string(""))
        ])
        let client = XenClient(endpoint: URL(string: "https://member.example:443")!, transport: wire)
        let identity = try await client.connect(username: "root", password: "secret")
        XCTAssertEqual(identity.poolUUID, "pool-uuid")
        _ = try await client.records(.host)
        await client.disconnect()
        let requests = await wire.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests[1].0.host, "master.example")
        XCTAssertTrue(requests[0].1.contains("<string>inchspace</string>"))
        XCTAssertFalse(requests[2].1.contains("<string>inchspace</string>"))
        XCTAssertTrue(requests[4].1.contains("<params><param><value><string>OpaqueRef:session</string>"))
    }
    func testAuthenticationFailureNeverTriggersSignatureFallback() async throws {
        let wire = XenScriptedTransport([failure("SESSION_AUTHENTICATION_FAILED")])
        let client = XenClient(endpoint: URL(string: "https://xen.example")!, transport: wire)
        do { _ = try await client.connect(username: "root", password: "wrong"); XCTFail("should reject") } catch {}
        let requests = await wire.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testLostPowerAcknowledgementIsUnknownAndNeverReplayed() async throws {
        let vm = vmRecord(state: "Halted", allowed: ["start"])
        let wire = XenScriptedTransport([response(.string("OpaqueRef:session")), poolResponse(), response(.dictionary(vm.fields))])
        let client = XenClient(endpoint: URL(string: "https://xen.example")!, transport: wire)
        let identity = try await client.connect(username: "root", password: "secret")
        do { try await client.power(.start, vm: vm, identity: identity); XCTFail("should be unknown") }
        catch { XCTAssertTrue((error as? XenError)?.outcomeUnknown == true) }
        let requests = await wire.requests
        XCTAssertEqual(requests.filter { $0.1.contains("<methodName>Async.VM.start</methodName>") }.count, 1)
    }
    func testPowerWaitsForTaskAndChecksPostcondition() async throws {
        let before = vmRecord(state: "Halted", allowed: ["start"])
        let after = vmRecord(state: "Running", allowed: ["clean_shutdown"])
        let wire = XenScriptedTransport([
            response(.string("OpaqueRef:session")), poolResponse(), response(.dictionary(before.fields)),
            response(.string("OpaqueRef:task")), response(.dictionary(["status": .string("success"), "result": .string("")])),
            response(.dictionary(after.fields))
        ])
        let client = XenClient(endpoint: URL(string: "https://xen.example")!, transport: wire)
        let identity = try await client.connect(username: "root", password: "secret")
        try await client.power(.start, vm: before, identity: identity)
        let requests = await wire.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests[3].1.contains("<boolean>0</boolean>"))
    }
    func testStaleSessionIdentityRejectsWriteBeforeSubmission() async throws {
        let wire = XenScriptedTransport([response(.string("OpaqueRef:session")), poolResponse()])
        let client = XenClient(endpoint: URL(string: "https://xen.example")!, transport: wire)
        _ = try await client.connect(username: "root", password: "secret")
        do { try await client.power(.start, vm: vmRecord(state: "Halted", allowed: ["start"]), identity: XenSessionIdentity(generation: UUID(), poolUUID: "pool-uuid")); XCTFail("should reject") } catch {}
        let requests = await wire.requests
        XCTAssertEqual(requests.count, 2)
    }
}

private func response(_ value: XenValue) -> Data {
    let envelope = XenValue.dictionary(["Status": .string("Success"), "Value": value])
    return Data("<methodResponse><params><param>\(XenXMLRPC.encode(envelope))</param></params></methodResponse>".utf8)
}
private func failure(_ code: String, _ parameters: [String] = []) -> Data {
    let envelope = XenValue.dictionary(["Status": .string("Failure"), "ErrorDescription": .array(([code] + parameters).map(XenValue.string))])
    return Data("<methodResponse><params><param>\(XenXMLRPC.encode(envelope))</param></params></methodResponse>".utf8)
}
private func poolResponse() -> Data { response(.dictionary(["OpaqueRef:pool": .dictionary(["uuid": .string("pool-uuid")])])) }
private func vmRecord(state: String, allowed: [String]) -> XenRecord {
    XenRecord(id: "OpaqueRef:vm", kind: .vm, fields: ["uuid": .string("vm-uuid"), "name_label": .string("Test VM"), "power_state": .string(state), "allowed_operations": .array(allowed.map(XenValue.string))])
}
private actor XenScriptedTransport: XenTransport {
    private var responses: [Data]
    var requests: [(URL, String)] = []
    init(_ responses: [Data]) { self.responses = responses }
    func send(to endpoint: URL, body: Data) async throws -> Data {
        requests.append((endpoint, String(decoding: body, as: UTF8.self)))
        guard !responses.isEmpty else { throw XenError.transport("simulated dropped acknowledgement") }
        return responses.removeFirst()
    }
}

final class XenMonitoringTests: XCTestCase {
    func testRRDMatchesExactObjectAndSkipsNaNWithoutInventingZero() throws {
        let xml = """
        <xport><meta><legend><entry>AVERAGE:host:host-a:cpu_avg</entry><entry>AVERAGE:vm:vm-a:cpu0</entry><entry>MIN:vm:vm-a:cpu0</entry></legend></meta>
        <data><row><t>100</t><v>0.25</v><v>NaN</v><v>0.01</v></row><row><t>105</t><v>0.5</v><v>0.75</v><v>0.1</v></row></data></xport>
        """
        let samples = try XenRRD.decode(Data(xml.utf8))
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.filter { $0.uuid == "vm-a" }.map(\.value), [0.75])
        XCTAssertEqual(samples.filter { $0.uuid == "host-a" }.map(\.value), [0.25, 0.5])
    }
    func testRRDRejectsColumnDriftAndEntities() {
        XCTAssertThrowsError(try XenRRD.decode(Data("<xport><meta><legend><entry>AVERAGE:host:h:cpu_avg</entry></legend></meta><data><row><t>100</t></row></data></xport>".utf8)))
        XCTAssertThrowsError(try XenRRD.decode(Data("<!DOCTYPE x [<!ENTITY a 'value'>]><xport>&a;</xport>".utf8)))
    }
    @MainActor func testAlertsRequireContinuousWindowAndDoNotRecoverOnMissingData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = XenAlertCenter(url: folder.appendingPathComponent("alerts.json"))
        try center.save(XenAlertRule(name: "CPU", threshold: 90, duration: 10))
        let cluster = UUID()
        func point(_ time: Double, _ value: Double) -> XenMetricSample { XenMetricSample(uuid: "host", object: "host", metric: "cpu_avg", timestamp: time, value: value) }
        center.observe(clusterID: cluster, poolUUID: "pool", samples: [point(100, 1), point(105, 1)])
        XCTAssertTrue(center.events.isEmpty)
        center.observe(clusterID: cluster, poolUUID: "pool", samples: [point(110, 1)])
        XCTAssertEqual(center.events.count, 1)
        center.observe(clusterID: cluster, poolUUID: "pool", samples: [])
        XCTAssertNil(center.events.first?.recoveredAt)
        center.acknowledge(center.events[0])
        center.observe(clusterID: cluster, poolUUID: "pool", samples: [point(100, 1), point(105, 1), point(110, 1), point(115, 1)])
        XCTAssertEqual(center.events.count, 1)
        center.observe(clusterID: cluster, poolUUID: "pool", samples: [point(120, 0.1)])
        XCTAssertNotNil(center.events.first?.recoveredAt)
    }
    @MainActor func testSamplingGapResetsAlertWindow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = XenAlertCenter(url: folder.appendingPathComponent("alerts.json"))
        try center.save(XenAlertRule(name: "CPU", threshold: 90, duration: 10))
        let points = [100.0, 105, 200, 205].map { XenMetricSample(uuid: "host", object: "host", metric: "cpu_avg", timestamp: $0, value: 1) }
        center.observe(clusterID: UUID(), poolUUID: "pool", samples: points)
        XCTAssertTrue(center.events.isEmpty)
    }
}

final class XenConsoleProtocolTests: XCTestCase {
    func testNativeCONNECTAndRawFramebufferOverRealLoopback() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
        import socket, struct
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        print(listener.getsockname()[1], flush=True)
        conn, _ = listener.accept()
        conn.settimeout(8)
        def read(n):
            data = b''
            while len(data) < n:
                chunk = conn.recv(n - len(data))
                if not chunk: raise RuntimeError('EOF')
                data += chunk
            return data
        header = b''
        while not header.endswith(b'\\r\\n\\r\\n'): header += read(1)
        assert b'Cookie: session_id=OpaqueRef:test' in header
        assert b'session_id=' not in header.split(b'\\r\\n')[0]
        conn.sendall(b'HTTP/1.1 200 Connection established\\r\\n\\r\\nRFB 003.008\\n')
        assert read(12) == b'RFB 003.008\\n'
        conn.sendall(bytes([1, 1]))
        assert read(1) == bytes([1])
        conn.sendall(bytes(4))
        assert read(1) == bytes([1])
        pixel_format = bytes([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        conn.sendall(struct.pack('!HH', 1, 1) + pixel_format + struct.pack('!I', 4) + b'Test')
        assert read(20)[0] == 0
        assert read(12)[0] == 2
        assert read(10)[0] == 3
        conn.sendall(bytes([0,0,0,1]) + struct.pack('!HHHHi', 0,0,1,1,0) + bytes([0x12,0x34,0x56,0]))
        try:
            while conn.recv(1024): pass
        except Exception: pass
        conn.close()
        listener.close()
        """]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let portData = try XCTUnwrap(pipe.fileHandleForReading.availableData as Data?)
        let port = try XCTUnwrap(Int(String(decoding: portData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let received = expectation(description: "native raw frame")
        let client = XenRFBClient()
        let worker = Task {
            try await client.run(location: URL(string: "http://127.0.0.1:\(port)/console?ref=OpaqueRef:console&session_id=remove-me")!, session: "OpaqueRef:test", allowUntrusted: false) { bytes, width, height in
                XCTAssertEqual(width, 1); XCTAssertEqual(height, 1)
                XCTAssertEqual(bytes, Data([0x12, 0x34, 0x56, 0]))
                received.fulfill()
            }
        }
        await fulfillment(of: [received], timeout: 10)
        await client.close()
        worker.cancel()
        _ = try? await worker.value
    }
}

final class XenHTTPProtocolTests: XCTestCase {
    func testPublishedXMLRPCRequestOverRealHTTP() async throws {
        let server = Process()
        let pipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.standardOutput = pipe
        server.arguments = ["-u", "-c", """
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers['Content-Length']))
                assert b'<methodName>VM.get_record</methodName>' in body
                assert body.index(b'OpaqueRef:session') < body.index(b'OpaqueRef:vm')
                assert self.headers['Content-Type'] == 'text/xml; charset=utf-8'
                data = b'<methodResponse><params><param><value><struct><member><name>Status</name><value>Success</value></member><member><name>Value</name><value><string>wire-ok</string></value></member></struct></value></param></params></methodResponse>'
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def log_message(self, *args): pass
        http = HTTPServer(('127.0.0.1', 0), Handler)
        print(http.server_port, flush=True)
        http.handle_request()
        http.server_close()
        """]
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let port = try XCTUnwrap(Int(String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let data = try await XenURLTransport().send(to: URL(string: "http://127.0.0.1:\(port)")!, body: XenXMLRPC.request(method: "VM.get_record", parameters: [.string("OpaqueRef:session"), .string("OpaqueRef:vm")]))
        XCTAssertEqual(try XenXMLRPC.result(data), .string("wire-ok"))
    }
    func testFileUploadStreamsActualBytesAndDoesNotReplayRedirect() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("test.xva")
        try Data(repeating: 0x5a, count: 256 * 1024).write(to: file)
        let server = Process(), pipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.standardOutput = pipe
        server.arguments = ["-u", "-c", """
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class Handler(BaseHTTPRequestHandler):
            def do_PUT(self):
                data = self.rfile.read(int(self.headers['Content-Length']))
                assert data == bytes([0x5a]) * (256 * 1024)
                self.send_response(307)
                self.send_header('Location', 'http://127.0.0.1:1/should-not-follow')
                self.send_header('Content-Length', '0')
                self.end_headers()
            def log_message(self, *args): pass
        http = HTTPServer(('127.0.0.1', 0), Handler)
        print(http.server_port, flush=True)
        http.handle_request()
        http.server_close()
        """]
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let port = try XCTUnwrap(Int(String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/import")!)
        request.httpMethod = "PUT"
        let transfer = XenFileTransfer(allowsUntrusted: false, destination: nil) { _ in }
        do { try await transfer.run(request: request, source: file); XCTFail("redirect must not succeed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("307")) }
    }
}

@MainActor
final class XenStoreTests: XCTestCase {
    func testSavingClusterDoesNotConnectAndUsesSeparateCredentialStore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let credentials = XenMemoryCredentials()
        let store = XenStore(persistence: XenPersistence(url: folder.appendingPathComponent("clusters.json")), credentials: credentials, alerts: XenAlertCenter(url: folder.appendingPathComponent("alerts.json")))
        let cluster = XenCluster(name: "Lab", address: "https://192.0.2.10")
        try store.save(cluster, password: "private")
        XCTAssertFalse(store.state(cluster.id).connected)
        XCTAssertFalse(store.state(cluster.id).connecting)
        XCTAssertEqual(credentials.values[cluster.id], "private")
        let data = try String(contentsOf: folder.appendingPathComponent("clusters.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("private"))
        XCTAssertEqual(store.clusters, [cluster])
    }
    func testFailedProfileWriteRestoresPreviousCredentialAndModel() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let credentials = XenMemoryCredentials()
        let file = folder.appendingPathComponent("clusters.json")
        let store = XenStore(persistence: XenPersistence(url: file), credentials: credentials, alerts: XenAlertCenter(url: folder.appendingPathComponent("alerts.json")))
        var cluster = XenCluster(name: "Lab", address: "https://192.0.2.10")
        try store.save(cluster, password: "old")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        cluster.name = "Edited"
        XCTAssertThrowsError(try store.save(cluster, password: "new"))
        XCTAssertEqual(store.clusters.first?.name, "Lab")
        XCTAssertEqual(credentials.values[cluster.id], "old")
    }
    func testPartialInventoryFailurePreservesIndependentDomains() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = XenScriptedTransport([
            response(.string("OpaqueRef:session")), poolResponse(), poolResponse(),
            failure("RBAC_PERMISSION_DENIED"), response(.dictionary([:])), response(.dictionary([:])), response(.dictionary([:])),
            response(.string(""))
        ])
        let credentials = XenMemoryCredentials()
        let cluster = XenCluster(name: "Lab", address: "https://192.0.2.10")
        credentials.values[cluster.id] = "secret"
        let store = XenStore(persistence: XenPersistence(url: folder.appendingPathComponent("clusters.json")), credentials: credentials,
                             alerts: XenAlertCenter(url: folder.appendingPathComponent("alerts.json")), observesEvents: false, transportFactory: { _ in wire })
        await store.connect(cluster)
        XCTAssertTrue(store.state(cluster.id).connected)
        XCTAssertNotNil(store.state(cluster.id).errors[.host])
        XCTAssertEqual(store.state(cluster.id).records[.pool]?.count, 1)
        XCTAssertNotNil(store.state(cluster.id).records[.vm])
        await store.disconnect(cluster.id)
        XCTAssertFalse(store.state(cluster.id).connected)
        XCTAssertEqual(store.state(cluster.id).records[.pool]?.count, 1)
    }
}

private nonisolated final class XenMemoryCredentials: XenCredentialStorage {
    var values: [UUID: String] = [:]
    func password(for id: UUID) throws -> String {
        guard let value = values[id] else { throw XenError.invalid("missing test credential") }
        return value
    }
    func save(_ password: String, for id: UUID) throws { values[id] = password }
    func delete(for id: UUID) throws { values[id] = nil }
}

final class XenCompatibilityTests: XCTestCase {
    func testOlderClusterConfigurationsDefaultToManualConnection() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Lab","address":"https://192.0.2.10","username":"root","allowsUntrustedCertificate":false}
        """
        let cluster = try JSONDecoder().decode(XenCluster.self, from: Data(json.utf8))
        XCTAssertFalse(cluster.connectsOnLaunch)
        XCTAssertFalse(cluster.reconnectsAutomatically)
    }
    func testTaskResultDecodesPublishedXMLValue() throws {
        XCTAssertEqual(try XenTaskResult.reference(.string("<value><string>OpaqueRef:snapshot</string></value>")), "OpaqueRef:snapshot")
        XCTAssertThrowsError(try XenTaskResult.reference(.string("OpaqueRef:NULL")))
        XCTAssertThrowsError(try XenTaskResult.reference(.string("not-a-reference")))
    }
    func testNotificationConfigurationRejectsHeaderInjectionAndUnencryptedWebhook() {
        var configuration = XenNotificationConfiguration()
        configuration.mailEnabled = true
        configuration.smtpHost = "smtp.example.com"
        configuration.sender = "user@example.com\r\nBcc:other@example.com"
        configuration.recipient = "receiver@example.com"
        XCTAssertThrowsError(try configuration.validate())
        configuration.sender = "user@example.com"
        XCTAssertNoThrow(try configuration.validate())
        configuration.webhookEnabled = true
        configuration.webhookURL = "http://example.com/hook"
        XCTAssertThrowsError(try configuration.validate())
    }
    func testMetricHistoryDeduplicatesAndSeparatesPools() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = XenMetricHistory(root: folder)
        let cluster = UUID(), now = Date().timeIntervalSince1970
        let first = XenMetricSample(uuid: "vm", object: "vm", metric: "cpu0", timestamp: now, value: 0.5)
        let updated = XenMetricSample(uuid: "vm", object: "vm", metric: "cpu0", timestamp: now, value: 0.75)
        _ = try await history.merge([first], clusterID: cluster, poolUUID: "pool-a")
        let result = try await history.merge([updated], clusterID: cluster, poolUUID: "pool-a")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.value, 0.75)
        let other = try await history.merge([], clusterID: cluster, poolUUID: "pool-b")
        XCTAssertTrue(other.isEmpty)
        let old = XenMetricSample(uuid: "vm", object: "vm", metric: "cpu0", timestamp: now - 8 * 86400, value: 1)
        let retained = try await history.merge([old], clusterID: cluster, poolUUID: "pool-a")
        XCTAssertEqual(retained.count, 1)
    }
}

final class XenXVAParserTests: XCTestCase {
    func testReadsPublishedMetadataWithoutExtractingArchive() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xva")
        defer { try? FileManager.default.removeItem(at: file) }
        let manifest = XenXMLRPC.encode(.dictionary(["objects": .array([
            .dictionary(["class": .string("VM"), "snapshot": .dictionary(["name_label": .string("Imported VM"), "VCPUs_max": .string("4"), "memory_static_max": .string("4294967296")])]),
            .dictionary(["class": .string("VDI"), "snapshot": .dictionary([:])])
        ])]))
        try archive(manifest).write(to: file)
        let preview = try XenXVA.preview(file)
        XCTAssertEqual(preview.name, "Imported VM")
        XCTAssertEqual(preview.vcpus, "4")
        XCTAssertEqual(preview.disks, 1)
    }
    func testRejectsInvalidChecksumAndTruncatedArchive() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xva")
        defer { try? FileManager.default.removeItem(at: file) }
        var tar = archive("<value>text</value>")
        tar[0] ^= 1
        try tar.write(to: file)
        XCTAssertThrowsError(try XenXVA.preview(file))
        try Data(tar.prefix(100)).write(to: file)
        XCTAssertThrowsError(try XenXVA.preview(file))
    }
    private func archive(_ xml: String) -> Data {
        let data = Data(xml.utf8)
        var header = Data(repeating: 0, count: 512)
        func set(_ value: String, at offset: Int) {
            let bytes = Data(value.utf8); header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        set("ova.xml", at: 0)
        set(String(format: "%011o", data.count), at: 124)
        set("        ", at: 148)
        let checksum = header.reduce(0) { $0 + Int($1) }
        set(String(format: "%06o", checksum) + "\0 ", at: 148)
        var result = header; result.append(data)
        result.append(Data(repeating: 0, count: (512 - data.count % 512) % 512 + 1024))
        return result
    }
}

final class XenMemoryProtocolTests: XCTestCase {
    func testHaltedDynamicEditPreservesStaticBoundaries() async throws {
        var before = vmRecord(state: "Halted", allowed: ["changing_dynamic_range"]).fields
        before["memory_static_min"] = .string("1")
        before["memory_dynamic_min"] = .string("2")
        before["memory_dynamic_max"] = .string("3")
        before["memory_static_max"] = .string("4")
        var after = before; after["memory_dynamic_max"] = .string("4")
        let wire = XenScriptedTransport([response(.string("OpaqueRef:session")), poolResponse(), response(.dictionary(before)), response(.string("")), response(.dictionary(after))])
        let client = XenClient(endpoint: URL(string: "https://xen.example")!, transport: wire)
        let identity = try await client.connect(username: "root", password: "fixture")
        try await client.updateMemory(XenRecord(id: "OpaqueRef:vm", kind: .vm, fields: before), configuration: XenMemoryConfiguration(staticMin: 1, dynamicMin: 2, dynamicMax: 4, staticMax: 4), identity: identity)
        let requests = await wire.requests
        XCTAssertTrue(requests[3].1.contains("VM.set_memory_dynamic_range"))
        XCTAssertFalse(requests.contains { $0.1.contains("VM.set_memory_limits") })
    }
}

extension XenStoreTests {
    func testMetadataOnlySaveFailureNeverDeletesUnchangedPassword() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("clusters.json")
        let credentials = XenMemoryCredentials()
        let store = XenStore(persistence: XenPersistence(url: file), credentials: credentials, alerts: XenAlertCenter(url: folder.appendingPathComponent("alerts.json")))
        var cluster = XenCluster(name: "Lab", address: "https://192.0.2.10")
        try store.save(cluster, password: "unchanged-secret")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        cluster.name = "Edited"
        XCTAssertThrowsError(try store.save(cluster, password: nil))
        XCTAssertEqual(credentials.values[cluster.id], "unchanged-secret")
        XCTAssertEqual(store.clusters.first?.name, "Lab")
    }
}

extension XenMonitoringTests {
    @MainActor func testOlderSamplesCannotRecoverANewerActiveAlertAfterRuleEdit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = XenAlertCenter(url: folder.appendingPathComponent("alerts.json"))
        let rule = XenAlertRule(name: "CPU", threshold: 90, duration: 10)
        try center.save(rule)
        let cluster = UUID()
        func point(_ time: Double, _ value: Double) -> XenMetricSample { XenMetricSample(uuid: "host", object: "host", metric: "cpu_avg", timestamp: time, value: value) }
        center.observe(clusterID: cluster, poolUUID: "pool", samples: [point(100, 1), point(105, 1), point(110, 1)])
        XCTAssertEqual(center.events.count, 1)
        try center.save(rule)
        center.observe(clusterID: cluster, poolUUID: "pool", samples: [point(100, 0.1), point(105, 1), point(110, 1), point(115, 1)])
        XCTAssertEqual(center.events.count, 1)
        XCTAssertNil(center.events[0].recoveredAt)
    }
}

final class XenTLSProtocolTests: XCTestCase {
    func testSelfSignedTLSOptInAppliesToRPCAndMetricsWithoutChangingDefaultTrust() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let certificate = folder.appendingPathComponent("cert.pem"), key = folder.appendingPathComponent("key.pem")
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", key.path, "-out", certificate.path]
        openssl.standardOutput = FileHandle.nullDevice; openssl.standardError = FileHandle.nullDevice
        try openssl.run(); openssl.waitUntilExit()
        XCTAssertEqual(openssl.terminationStatus, 0)
        let server = Process(), pipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.standardOutput = pipe
        server.arguments = ["-u", "-c", """
        import ssl, sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class Handler(BaseHTTPRequestHandler):
            def respond(self):
                data = b'<methodResponse><params><param><value><struct><member><name>Status</name><value>Failure</value></member><member><name>ErrorDescription</name><value><array><data><value>SESSION_INVALID</value></data></array></value></member></struct></value></param></params></methodResponse>'
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                self.respond()
            def do_GET(self): self.respond()
            def log_message(self, *args): pass
        http = HTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[1], sys.argv[2])
        http.socket = context.wrap_socket(http.socket, server_side=True)
        print(http.server_port, flush=True)
        http.serve_forever()
        """, certificate.path, key.path]
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let port = try XCTUnwrap(Int(String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let url = URL(string: "https://127.0.0.1:\(port)")!
        let body = XenXMLRPC.request(method: "pool.get_all_records", parameters: [.string("OpaqueRef:tls-test")])
        for allows in [false, true, false] {
            do {
                let data = try await XenURLTransport(allowsUntrustedCertificate: allows).send(to: url, body: body)
                XCTAssertTrue(allows, "Trust must remain opt-in for each transport")
                XCTAssertThrowsError(try XenXMLRPC.result(data)) { XCTAssertEqual($0 as? XenError, .api("SESSION_INVALID", [])) }
            } catch {
                XCTAssertFalse(allows, "Explicit opt-in must reach the XAPI response: \(error)")
                XCTAssertTrue(error.localizedDescription.contains("尚未验证账号密码"))
            }
        }
        let metrics = try await XenURLTransport(allowsUntrustedCertificate: true).get(url)
        XCTAssertFalse(metrics.isEmpty)
    }
}

extension XenStoreTests {
    func testConnectUsesLatestSavedCertificatePolicyInsteadOfStaleViewValue() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = XenScriptedTransport([response(.string("OpaqueRef:session")), poolResponse(), poolResponse(), response(.dictionary([:])), response(.dictionary([:])), response(.dictionary([:])), response(.dictionary([:])), response(.string(""))])
        var policy: Bool?
        let store = XenStore(persistence: XenPersistence(url: folder.appendingPathComponent("clusters.json")), credentials: XenMemoryCredentials(),
                             alerts: XenAlertCenter(url: folder.appendingPathComponent("alerts.json")), observesEvents: false, transportFactory: { profile in policy = profile.allowsUntrustedCertificate; return wire })
        let old = XenCluster(name: "Lab", address: "https://192.0.2.10")
        try store.save(old, password: "fixture")
        var updated = old; updated.allowsUntrustedCertificate = true
        try store.save(updated, password: nil)
        await store.connect(old)
        XCTAssertEqual(policy, true)
        XCTAssertTrue(store.state(old.id).connected)
        await store.disconnect(old.id)
    }
}
