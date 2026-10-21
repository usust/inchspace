import CoreServices
import Foundation

/// Reports changes below a folder using FSEvents, coalesced by the system latency.
/// The folder's security scope is held for the watcher's lifetime so events keep flowing in the sandbox.
@MainActor
final class ArchiveFolderWatcher {
    private var stream: FSEventStreamRef?
    private var scopedURL: URL?
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) { self.handler = handler }

    var isRunning: Bool { stream != nil }

    func start(url: URL, latency: TimeInterval = 3) -> Bool {
        stop()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ArchiveFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in watcher.handler() }
        }
        guard let created = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else {
            releaseScope()
            return false
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            releaseScope()
            return false
        }
        stream = created
        return true
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        releaseScope()
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}
