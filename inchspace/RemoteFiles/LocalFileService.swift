import AppKit
import Foundation

struct LocalFileService: Sendable {
    private let manager = FileManager.default

    func list(_ path: String, showsHiddenFiles: Bool) throws -> [FileItem] {
        // Do not force directory URL semantics here. A trailing slash prevents
        // Foundation from traversing some symbolic links that point to folders.
        let requestedURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let directoryURL = requestedURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        return try manager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: Array(keys), options: showsHiddenFiles ? [] : [.skipsHiddenFiles])
            .map { itemURL in
                let values = try itemURL.resourceValues(forKeys: keys)
                let kind: FileItemKind = values.isSymbolicLink == true ? .symbolicLink : (values.isDirectory == true ? .directory : .file)
                let displayedURL = requestedURL.appending(path: itemURL.lastPathComponent)
                return FileItem(name: itemURL.lastPathComponent, path: displayedURL.path, kind: kind, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate)
            }
            .sorted(by: FileItem.defaultOrder)
    }

    func isDirectory(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return manager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func createDirectory(named name: String, in path: String) throws {
        try manager.createDirectory(at: URL(fileURLWithPath: path).appending(path: name), withIntermediateDirectories: false)
    }

    func rename(_ item: FileItem, to name: String) throws {
        try manager.moveItem(atPath: item.path, toPath: URL(fileURLWithPath: item.path).deletingLastPathComponent().appending(path: name).path)
    }

    func moveToTrash(_ items: [FileItem]) throws {
        for item in items { _ = try manager.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil) }
    }

    @MainActor func reveal(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }
}

nonisolated extension FileItem {
    static func defaultOrder(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if lhs.kind == .directory, rhs.kind != .directory { return true }
        if lhs.kind != .directory, rhs.kind == .directory { return false }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
