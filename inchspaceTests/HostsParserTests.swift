import Testing
@testable import inchspace

struct HostsParserTests {
    private let parser = HostsParser()

    @Test func preservesRawDocumentExactly() {
        let source = "# macOS hosts\n\n127.0.0.1 localhost # loopback\n::1 localhost\n192.168.1.20 app.local api.local # staging api\n"
        let document = parser.parse(source)
        #expect(document.rendered == source)
        #expect(document.entries.count == 3)
        #expect(document.entries.last?.hostnames == ["app.local", "api.local"])
        #expect(document.entries.last?.comment == "staging api")
    }

    @Test func parsesIPv4IPv6AndProtectsSystemEntries() {
        let document = parser.parse("127.0.0.1 localhost\n255.255.255.255 broadcasthost\n::1 localhost\n2001:db8::1 api.internal\n")
        #expect(document.entries.count == 4)
        #expect(document.entries.prefix(3).allSatisfy { $0.isSystem })
        #expect(document.entries.last?.isSystem == false)
    }

    @Test func disableEnableRoundTripPreservesMeaningAndComment() throws {
        let service = HostsService()
        var document = parser.parse("# before\n192.168.1.20 app.local api.local # staging api\n# after\n")
        let original = try #require(document.entries.first)
        try service.setEnabled(false, for: original, in: &document)
        #expect(document.rendered.contains("# inchspace:disabled 192.168.1.20\tapp.local\tapi.local # staging api"))
        let disabled = try #require(document.entries.first)
        try service.setEnabled(true, for: disabled, in: &document)
        #expect(document.entries.first?.hostnames == ["app.local", "api.local"])
        #expect(document.entries.first?.comment == "staging api")
        #expect(document.lines.first?.raw == "# before")
        #expect(document.lines.last?.raw == "# after")
    }

    @Test func addEditDeleteChangesOnlyTargetLine() throws {
        let service = HostsService()
        var document = parser.parse("# untouched\n127.0.0.1 localhost\n\n")
        try service.add(address: "127.0.0.1", hostnames: ["测试.local", "api.local"], comment: "本地开发", to: &document)
        let added = try #require(document.entries.last)
        try service.update(added, address: "192.168.1.100", hostnames: ["test.local"], comment: "updated", in: &document)
        #expect(document.rendered.hasPrefix("# untouched\n127.0.0.1 localhost\n\n"))
        let updated = try #require(document.entries.last)
        try service.delete(updated, from: &document)
        #expect(document.lines.first?.raw == "# untouched")
        #expect(document.entries.count == 1)
    }

    @Test func validatesAddressAndHostname() throws {
        try parser.validate(address: "127.0.0.1", hostnames: ["localhost", "dev.local"])
        try parser.validate(address: "2001:db8::1", hostnames: ["api.internal"])
        #expect(throws: HostsError.self) { try parser.validate(address: "999.1.1.1", hostnames: ["api.local"]) }
        #expect(throws: HostsError.self) { try parser.validate(address: "127.0.0.1", hostnames: ["bad host"] ) }
    }

    @Test func systemEntryCannotBeDisabledOrDeleted() throws {
        let service = HostsService()
        var document = parser.parse("127.0.0.1 localhost\n")
        let entry = try #require(document.entries.first)
        #expect(throws: HostsError.self) { try service.setEnabled(false, for: entry, in: &document) }
        #expect(throws: HostsError.self) { try service.delete(entry, from: &document) }
    }
}
