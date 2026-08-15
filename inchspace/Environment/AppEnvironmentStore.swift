import Foundation

nonisolated final class AppEnvironmentStore: @unchecked Sendable {
    static let shared = AppEnvironmentStore()

    private let lock = NSLock()
    private var overrides: [String: String] = [:]
    private var removedKeys: Set<String> = []

    private init() {}

    func replaceOverrides(with values: [String: String]) {
        lock.lock()
        overrides = values
        lock.unlock()
    }

    func restore(_ name: String) {
        lock.lock()
        removedKeys.remove(name)
        lock.unlock()
    }

    func remove(_ name: String) {
        lock.lock()
        overrides[name] = nil
        removedKeys.insert(name)
        lock.unlock()
    }

    func environment(merging base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        lock.lock()
        let snapshot = overrides
        let removed = removedKeys
        lock.unlock()
        var result = base.merging(snapshot) { _, latest in latest }
        removed.forEach { result[$0] = nil }
        return result
    }
}
