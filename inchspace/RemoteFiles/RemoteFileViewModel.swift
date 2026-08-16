import AppKit
import Combine
import Foundation

@MainActor
final class RemoteFileViewModel: ObservableObject {
    @Published var localPath: String
    @Published var remotePath = "."
    @Published var localItems: [FileItem] = []
    @Published var remoteItems: [FileItem] = []
    @Published var selectedLocalIDs: Set<String> = []
    @Published var selectedRemoteIDs: Set<String> = []
    @Published var selectedServerID: UUID?
    @Published var connectionState: RemoteConnectionState = .disconnected
    @Published var showsHiddenFiles = false
    @Published var pendingTrust: PendingHostTrust?
    @Published var presentedError: ServerPresentedError?
    @Published var pendingRemoteDeletion: [FileItem] = []
    @Published var pendingLocalDeletion: [FileItem] = []
    @Published var pendingConflict: PendingTransferConflict?
    @Published var fileNamePrompt: FileNamePrompt?
    @Published var showsTransfers = true
    let transfers = TransferManager()

    private let localService = LocalFileService()
    private let remoteService = RemoteFileService()
    private let defaults = UserDefaults.standard

    init() {
        localPath = UserDefaults.standard.string(forKey: "remoteFiles.lastLocalPath") ?? FileManager.default.homeDirectoryForCurrentUser.path
        refreshLocal()
    }

    var selectedLocalItems: [FileItem] { localItems.filter { selectedLocalIDs.contains($0.id) } }
    var selectedRemoteItems: [FileItem] { remoteItems.filter { selectedRemoteIDs.contains($0.id) } }

    func selectServer(_ server: Server?, credential: SSHCredential?) {
        guard let server else { disconnect(); return }
        selectedServerID = server.id
        connectionState = .connecting
        Task {
            do {
                remotePath = try await remoteService.connect(server: server, credential: credential)
                connectionState = .connected
                remotePath = defaults.string(forKey: "remoteFiles.lastRemotePath.\(server.id)") ?? remotePath
                await refreshRemote()
            } catch RemoteFileError.hostNotTrusted(let trust) {
                pendingTrust = trust; connectionState = .disconnected
            } catch RemoteFileError.hostKeyChanged(let trust) {
                pendingTrust = trust; connectionState = .failed("Host Key 已改变")
            } catch { connectionState = .failed(error.localizedDescription); presentedError = ServerPresentedError(error) }
        }
    }

    func trustAndConnect(_ request: PendingHostTrust, server: Server, credential: SSHCredential?) {
        do { try remoteService.trust(request); pendingTrust = nil; selectServer(server, credential: credential) }
        catch { presentedError = ServerPresentedError(error) }
    }

    func disconnect() { remoteService.disconnect(); connectionState = .disconnected; remoteItems = []; selectedRemoteIDs.removeAll() }

    func refreshLocal() {
        do {
            localItems = try localService.list(localPath, showsHiddenFiles: showsHiddenFiles)
            selectedLocalIDs.formIntersection(localItems.map(\.id))
            defaults.set(localPath, forKey: "remoteFiles.lastLocalPath")
        }
        catch { presentedError = ServerPresentedError(error) }
    }

    func refreshRemote() async {
        guard connectionState == .connected else { return }
        do {
            remoteItems = try await remoteService.list(remotePath, showsHiddenFiles: showsHiddenFiles)
            selectedRemoteIDs.formIntersection(remoteItems.map(\.id))
            if let id = selectedServerID { defaults.set(remotePath, forKey: "remoteFiles.lastRemotePath.\(id)") }
        } catch { presentedError = ServerPresentedError(error) }
    }

    func navigateLocal(to path: String) {
        do {
            let items = try localService.list(path, showsHiddenFiles: showsHiddenFiles)
            localPath = path
            localItems = items
            selectedLocalIDs.removeAll()
            defaults.set(path, forKey: "remoteFiles.lastLocalPath")
        } catch {
            presentedError = ServerPresentedError(error)
        }
    }

    func navigateRemote(to path: String) async {
        guard connectionState == .connected else { return }
        do {
            let items = try await remoteService.list(path, showsHiddenFiles: showsHiddenFiles)
            remotePath = path
            remoteItems = items
            selectedRemoteIDs.removeAll()
            if let id = selectedServerID {
                defaults.set(path, forKey: "remoteFiles.lastRemotePath.\(id)")
            }
        } catch {
            // Keep the current directory and its contents when the destination
            // is a file, is missing, or cannot be read by this account.
            presentedError = ServerPresentedError(error)
        }
    }

    func openLocal(_ item: FileItem) {
        if item.kind == .directory || (item.kind == .symbolicLink && localService.isDirectory(item.path)) { navigateLocal(to: item.path) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
    }

    func openRemote(_ item: FileItem) {
        guard item.kind == .directory || item.kind == .symbolicLink else { return }
        Task { await navigateRemote(to: item.path) }
    }

    func localUp() { let parent = (localPath as NSString).deletingLastPathComponent; guard !parent.isEmpty, parent != localPath else { return }; navigateLocal(to: parent) }
    func remoteUp() { let parent = (remotePath as NSString).deletingLastPathComponent; guard !parent.isEmpty, parent != remotePath else { return }; Task { await navigateRemote(to: parent) } }

    func upload(_ items: [FileItem]? = nil) {
        let values = items ?? selectedLocalItems
        for item in values {
            let destination = join(remotePath, item.name)
            Task {
                if await remoteService.exists(destination) {
                    pendingConflict = PendingTransferConflict(direction: .upload, item: item, destination: destination, existingSize: await remoteService.remoteSize(destination))
                } else {
                    enqueueUpload(item, destination: destination)
                }
            }
        }
    }

    func download(_ items: [FileItem]? = nil) {
        let values = items ?? selectedRemoteItems
        for item in values {
            let destination = URL(fileURLWithPath: localPath).appending(path: item.name).path
            if FileManager.default.fileExists(atPath: destination) {
                let size = Self.localTreeSizeStatic(destination)
                pendingConflict = PendingTransferConflict(direction: .download, item: item, destination: destination, existingSize: size)
            } else {
                if item.kind == .directory {
                    Task { enqueueDownload(item, destination: destination, totalBytes: await remoteService.treeSize(item)) }
                } else {
                    enqueueDownload(item, destination: destination, totalBytes: item.size)
                }
            }
        }
    }

    func resolveConflict(_ choice: TransferConflictChoice) {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        switch choice {
        case .cancel: return
        case .replace:
            if conflict.direction == .upload { Task { try? await remoteService.delete([FileItem(name: conflict.item.name, path: conflict.destination, kind: conflict.item.kind)]); enqueueUpload(conflict.item, destination: conflict.destination) } }
            else {
                try? FileManager.default.removeItem(atPath: conflict.destination)
                Task { enqueueDownload(conflict.item, destination: conflict.destination, totalBytes: await remoteService.treeSize(conflict.item)) }
            }
        case .keepBoth:
            if conflict.direction == .upload {
                Task { enqueueUpload(conflict.item, destination: await availableRemotePath(conflict.destination)) }
            } else {
                let destination = availableLocalPath(conflict.destination)
                Task { enqueueDownload(conflict.item, destination: destination, totalBytes: await remoteService.treeSize(conflict.item)) }
            }
        }
    }

    func deleteRemoteConfirmed() { let items = pendingRemoteDeletion; pendingRemoteDeletion = []; Task { do { try await remoteService.delete(items); await refreshRemote() } catch { presentedError = ServerPresentedError(error) } } }
    func deleteLocalConfirmed() { do { try localService.moveToTrash(pendingLocalDeletion); pendingLocalDeletion = []; refreshLocal() } catch { presentedError = ServerPresentedError(error) } }
    func toggleHidden() { showsHiddenFiles.toggle(); refreshLocal(); Task { await refreshRemote() } }

    func promptForNewDirectory(isLocal: Bool) { fileNamePrompt = FileNamePrompt(kind: .createDirectory, isLocal: isLocal, item: nil, name: "新建文件夹") }
    func promptForRename(_ item: FileItem, isLocal: Bool) { fileNamePrompt = FileNamePrompt(kind: .rename, isLocal: isLocal, item: item, name: item.name) }
    func applyFileNamePrompt(_ prompt: FileNamePrompt) {
        let name = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { presentedError = ServerPresentedError("名称不能为空或包含 /。"); return }
        fileNamePrompt = nil
        if prompt.isLocal {
            do {
                if prompt.kind == .createDirectory { try localService.createDirectory(named: name, in: localPath) }
                else if let item = prompt.item { try localService.rename(item, to: name) }
                refreshLocal()
            } catch { presentedError = ServerPresentedError(error) }
        } else {
            Task {
                do {
                    if prompt.kind == .createDirectory { try await remoteService.createDirectory(named: name, in: remotePath) }
                    else if let item = prompt.item { try await remoteService.rename(item, to: name) }
                    await refreshRemote()
                } catch { presentedError = ServerPresentedError(error) }
            }
        }
    }

    private func localTreeSize(_ path: String) -> Int64 { Self.localTreeSizeStatic(path) }
    private func enqueueUpload(_ item: FileItem, destination: String) {
        let total = localTreeSize(item.path)
        transfers.enqueue(direction: .upload, source: item.path, destination: destination, totalBytes: total) { [weak self] in
            guard let self else { return 0 }
            let temporaryName = ".\(URL(fileURLWithPath: destination).lastPathComponent).inchspace-transfer"
            return await self.remoteService.remoteSize(self.join((destination as NSString).deletingLastPathComponent, temporaryName))
        } operation: { [weak self] token in
            guard let self else { return }
            try await self.remoteService.upload(localPath: item.path, remotePath: destination, cancellation: token)
            await self.refreshRemote()
        }
    }

    private func enqueueDownload(_ item: FileItem, destination: String, totalBytes: Int64) {
        transfers.enqueue(direction: .download, source: item.path, destination: destination, totalBytes: totalBytes) {
            Self.localTreeSizeStatic(URL(fileURLWithPath: destination).deletingLastPathComponent().appending(path: ".\(URL(fileURLWithPath: destination).lastPathComponent).inchspace-transfer").path)
        } operation: { [weak self] token in
            guard let self else { return }
            try await self.remoteService.download(remotePath: item.path, localPath: destination, isDirectory: item.kind == .directory, cancellation: token)
            self.refreshLocal()
        }
    }

    private func availableRemotePath(_ original: String) async -> String {
        let url = URL(fileURLWithPath: original); let ext = url.pathExtension; let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent; let parent = (original as NSString).deletingLastPathComponent
        var number = 2
        while true { let name = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"; let candidate = join(parent, name); if !(await remoteService.exists(candidate)) { return candidate }; number += 1 }
    }

    private func availableLocalPath(_ original: String) -> String {
        let url = URL(fileURLWithPath: original); let ext = url.pathExtension; let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var number = 2
        while true { let name = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"; let candidate = url.deletingLastPathComponent().appending(path: name).path; if !FileManager.default.fileExists(atPath: candidate) { return candidate }; number += 1 }
    }
    nonisolated private static func localTreeSizeStatic(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path); let fm = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator { if let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), v.isDirectory != true { total += Int64(v.fileSize ?? 0) } }
        return total
    }
    private func join(_ parent: String, _ child: String) -> String { parent == "/" ? "/\(child)" : "\(parent)/\(child)" }
}
