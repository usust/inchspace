import Foundation
import Testing
@testable import inchspace

struct RemoteFileServiceTests {
    @Test func parsesOpenSSHListingWithUnknownLinkCountAndAbsolutePaths() {
        let directory = RemoteFileService.parseListingLine(
            "drwxr-xr-x    ? root     root         4096 Aug 15 22:42 /home",
            parent: "/"
        )
        #expect(directory?.name == "home")
        #expect(directory?.path == "/home")
        #expect(directory?.kind == .directory)
        #expect(directory?.size == 4096)
        #expect(directory?.modifiedAt != nil)

        let file = RemoteFileService.parseListingLine(
            "-rw-r--r--    1 dok      dok          123 Feb 10  2026 /home/dok/a file.txt",
            parent: "/home/dok"
        )
        #expect(file?.name == "a file.txt")
        #expect(file?.path == "/home/dok/a file.txt")
        #expect(file?.kind == .file)
        #expect(file?.size == 123)

        let link = RemoteFileService.parseListingLine(
            "lrwxrwxrwx    ? root     root            7 Apr 22  2024 /bin",
            parent: "/"
        )
        #expect(link?.name == "bin")
        #expect(link?.path == "/bin")
        #expect(link?.kind == .symbolicLink)
    }
}
