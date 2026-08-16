import Foundation
import Testing
@testable import inchspace

struct OpenSSHProcessTests {
    @Test func configurationOptionPreservesPathsContainingSpaces() async throws {
        let knownHostsPath = "/tmp/Application Support/inchspace/known_hosts"
        let controlPath = "/tmp/Application Support/inchspace/Control/ssh-%C"

        let result = try await OpenSSHProcess.run(
            executable: "/usr/bin/ssh",
            arguments: [
                "-G",
                "-o", OpenSSHProcess.configurationOption(
                    "UserKnownHostsFile",
                    value: knownHostsPath
                ),
                "-o", OpenSSHProcess.configurationOption(
                    "ControlPath",
                    value: controlPath
                ),
                "example.invalid",
            ]
        )

        #expect(result.status == 0)
        #expect(result.output.contains("userknownhostsfile \(knownHostsPath)"))
        #expect(result.output.contains("controlpath /tmp/Application Support/inchspace/Control/ssh-"))
        #expect(!result.output.contains("extra arguments at end of line"))
    }
}
