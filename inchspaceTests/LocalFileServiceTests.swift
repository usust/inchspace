import Foundation
import Testing
@testable import inchspace

struct LocalFileServiceTests {
    @Test func listsUnicodeSpacesHiddenFilesAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "inchspace-local-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("test".utf8).write(to: root.appending(path: "测试文件.txt"))
        try Data("space".utf8).write(to: root.appending(path: "a b c.txt"))
        try Data("hidden".utf8).write(to: root.appending(path: ".env"))
        try FileManager.default.createDirectory(at: root.appending(path: "测试 目录"), withIntermediateDirectories: false)

        let service = LocalFileService()
        let visible = try service.list(root.path, showsHiddenFiles: false)
        #expect(visible.first?.kind == .directory)
        #expect(visible.contains { $0.name == "测试文件.txt" })
        #expect(visible.contains { $0.name == "a b c.txt" })
        #expect(!visible.contains { $0.name == ".env" })
        #expect(try service.list(root.path, showsHiddenFiles: true).contains { $0.name == ".env" })
    }

    @Test func identifiesDirectorySymbolicLinksAsNavigable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "inchspace-local-links-\(UUID().uuidString)")
        let directory = root.appending(path: "target")
        let link = root.appending(path: "directory-link")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

        let service = LocalFileService()
        let item = try #require(service.list(root.path, showsHiddenFiles: false).first { $0.name == link.lastPathComponent })
        #expect(item.kind == .symbolicLink)
        #expect(service.isDirectory(item.path))
        #expect(try service.list(item.path, showsHiddenFiles: false).isEmpty)
    }
}
