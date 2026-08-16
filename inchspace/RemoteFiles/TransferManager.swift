import Combine
import Foundation

@MainActor
final class TransferManager: ObservableObject {
    @Published private(set) var transfers: [FileTransfer] = []
    private let maximumConcurrentTransfers = 3
    private var operations: [UUID: @MainActor () async throws -> Void] = [:]
    private var cancellationTokens: [UUID: CancellableProcess] = [:]
    private var running: Set<UUID> = []

    func enqueue(
        direction: TransferDirection,
        source: String,
        destination: String,
        totalBytes: Int64,
        progressSize: @escaping @MainActor () async -> Int64,
        operation: @escaping @MainActor (CancellableProcess) async throws -> Void
    ) {
        let id = UUID()
        let transfer = FileTransfer(id: id, direction: direction, source: source, destination: destination, filename: URL(fileURLWithPath: source).lastPathComponent, totalBytes: totalBytes, transferredBytes: 0, bytesPerSecond: 0, state: .waiting)
        transfers.insert(transfer, at: 0)
        let token = CancellableProcess()
        cancellationTokens[id] = token
        operations[id] = { [weak self] in
            guard let self else { return }
            let monitor = Task { @MainActor in await self.monitor(id: id, size: progressSize) }
            defer { monitor.cancel() }
            try await operation(token)
        }
        schedule()
    }

    func cancel(_ id: UUID) {
        cancellationTokens[id]?.cancel()
        operations[id] = nil
        update(id) { $0.state = .cancelled }
        running.remove(id)
        schedule()
    }

    func retry(_ id: UUID) {
        guard operations[id] != nil || transfers.first(where: { $0.id == id })?.state == .failed else { return }
        update(id) { $0.state = .waiting; $0.error = nil; $0.transferredBytes = 0; $0.bytesPerSecond = 0 }
        schedule()
    }

    func clearCompleted() { transfers.removeAll { $0.state == .completed || $0.state == .cancelled } }

    private func schedule() {
        let available = maximumConcurrentTransfers - running.count
        guard available > 0 else { return }
        let waiting = transfers.filter { $0.state == .waiting }.prefix(available)
        for transfer in waiting {
            guard let operation = operations[transfer.id] else { continue }
            running.insert(transfer.id)
            update(transfer.id) { $0.state = .transferring }
            Task { @MainActor in
                do {
                    try await operation()
                    guard self.state(for: transfer.id) != .cancelled else { return }
                    self.update(transfer.id) { item in item.state = .completed; item.transferredBytes = item.totalBytes }
                } catch is CancellationError {
                    self.update(transfer.id) { $0.state = .cancelled }
                } catch {
                    self.update(transfer.id) { $0.state = .failed; $0.error = error.localizedDescription }
                }
                self.running.remove(transfer.id)
                self.schedule()
            }
        }
    }

    private func monitor(id: UUID, size: @escaping @MainActor () async -> Int64) async {
        var samples: [(Date, Int64)] = []
        while !Task.isCancelled, state(for: id) == .transferring {
            let bytes = await size()
            let now = Date()
            samples.append((now, bytes)); samples.removeAll { now.timeIntervalSince($0.0) > 4 }
            let speed: Double
            if let first = samples.first, now.timeIntervalSince(first.0) > 0.5 {
                speed = Double(max(0, bytes - first.1)) / now.timeIntervalSince(first.0)
            } else { speed = 0 }
            update(id) { $0.transferredBytes = min(max(0, bytes), max(bytes, $0.totalBytes)); $0.bytesPerSecond = speed }
            try? await Task.sleep(for: .milliseconds(750))
        }
    }

    private func state(for id: UUID) -> TransferState? { transfers.first { $0.id == id }?.state }
    private func update(_ id: UUID, _ body: (inout FileTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        body(&transfers[index])
    }
}
