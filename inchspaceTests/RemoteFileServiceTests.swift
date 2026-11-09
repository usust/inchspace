import Foundation
import Testing
@testable import inchspace

struct RemoteFileServiceTests {
    @Test func readsDroppedFilesOutsideCurrentDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = [root.appending(path: "中文 file.py"), root.appending(path: "second.py")]
        for url in urls { try Data("hello".utf8).write(to: url) }
        let service = LocalFileService()
        let items = try urls.map { try service.item(at: $0) }
        #expect(items.map(\.name) == ["中文 file.py", "second.py"])
        #expect(items.allSatisfy { $0.kind == .file && $0.size == 5 })
        #expect(try service.item(at: root).kind == .directory)
        #expect(throws: (any Error).self) { try service.item(at: URL(string: "https://example.com/file")!) }
        #expect(throws: (any Error).self) { try service.item(at: root.appending(path: "missing")) }
    }

    @Test @MainActor func queuesConflictsUntilEachSheetDismisses() {
        let model = RemoteFileViewModel()
        let conflicts = (1...3).map { index in
            PendingTransferConflict(direction: .upload, item: FileItem(name: "file\(index)", path: "/local/file\(index)", kind: .file), destination: "/remote/file\(index)", existingSize: 1)
        }
        conflicts.forEach { model.queueConflict($0) }
        #expect(model.pendingConflict?.id == conflicts[0].id)
        model.resolveConflict(.cancel)
        #expect(model.pendingConflict == nil)
        model.conflictSheetDismissed()
        #expect(model.pendingConflict?.id == conflicts[1].id)
        // Closing the sheet without a choice also skips only the current item.
        model.pendingConflict = nil
        model.conflictSheetDismissed()
        #expect(model.pendingConflict?.id == conflicts[2].id)
        model.resolveConflict(.cancel)
        model.conflictSheetDismissed()
        #expect(model.pendingConflict == nil)
    }

    @Test @MainActor func conflictArrivingDuringDismissalWaitsForSheet() {
        let model = RemoteFileViewModel()
        let first = PendingTransferConflict(direction: .upload, item: FileItem(name: "first", path: "/first", kind: .file), destination: "/remote/first", existingSize: 1)
        let second = PendingTransferConflict(direction: .upload, item: FileItem(name: "second", path: "/second", kind: .file), destination: "/remote/second", existingSize: 1)
        model.queueConflict(first)
        model.resolveConflict(.cancel)
        model.queueConflict(second)
        #expect(model.pendingConflict == nil)
        model.conflictSheetDismissed()
        #expect(model.pendingConflict?.id == second.id)
    }

    @Test @MainActor func disconnectClearsConflictsAndRejectsStaleDrops() {
        let model = RemoteFileViewModel()
        let generation = model.connectionGeneration
        let conflict = PendingTransferConflict(direction: .upload, item: FileItem(name: "file", path: "/file", kind: .file), destination: "/remote/file", existingSize: 1)
        model.queueConflict(conflict)
        model.queueConflict(conflict)
        model.disconnect()
        model.conflictSheetDismissed()
        #expect(model.pendingConflict == nil)
        #expect(model.connectionGeneration != generation)
        model.connectionState = .connected
        model.uploadURLs([URL(string: "https://example.com/file")!], to: "/remote", generation: generation)
        #expect(model.presentedError == nil)
        model.queueConflict(conflict)
        #expect(model.pendingConflict?.id == conflict.id)
    }

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
