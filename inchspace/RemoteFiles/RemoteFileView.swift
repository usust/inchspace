import AppKit
import SwiftUI

struct RemoteFileView: View {
    @ObservedObject var model: RemoteFileViewModel
    @ObservedObject var serverManager: ServerManager
    @State private var localPathInput = ""
    @State private var remotePathInput = ""
    @State private var editsLocalPath = false
    @State private var editsRemotePath = false
    @State private var localDropTargeted = false
    @State private var remoteDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HSplitView {
                filePanel(title: "本机", symbol: "laptopcomputer", path: model.localPath, pathInput: $localPathInput, editsPath: $editsLocalPath, items: model.localItems, selection: $model.selectedLocalIDs, isLocal: true)
                    .frame(minWidth: 340)
                filePanel(title: selectedServer?.name ?? "服务器", symbol: "server.rack", path: model.remotePath, pathInput: $remotePathInput, editsPath: $editsRemotePath, items: model.remoteItems, selection: $model.selectedRemoteIDs, isLocal: false)
                    .frame(minWidth: 340)
            }
            if model.showsTransfers { transferPanel }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: $model.presentedError) { error in Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("好"))) }
        .sheet(item: $model.pendingTrust) { request in trustSheet(request) }
        .sheet(item: $model.pendingConflict) { conflict in conflictSheet(conflict) }
        .sheet(item: $model.fileNamePrompt) { prompt in fileNameSheet(prompt) }
        .confirmationDialog("永久删除所选远程项目？", isPresented: Binding(get: { !model.pendingRemoteDeletion.isEmpty }, set: { if !$0 { model.pendingRemoteDeletion = [] } }), titleVisibility: .visible) {
            Button("永久删除", role: .destructive) { model.deleteRemoteConfirmed() }
            Button("取消", role: .cancel) { model.pendingRemoteDeletion = [] }
        } message: { Text("远程文件删除后可能无法恢复。") }
        .confirmationDialog("将所选项目移到废纸篓？", isPresented: Binding(get: { !model.pendingLocalDeletion.isEmpty }, set: { if !$0 { model.pendingLocalDeletion = [] } }), titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) { model.deleteLocalConfirmed() }
            Button("取消", role: .cancel) { model.pendingLocalDeletion = [] }
        }
        .onChange(of: model.showsHiddenFiles) { _, _ in model.refreshLocal(); Task { await model.refreshRemote() } }
        .onDisappear { model.disconnect() }
        .focusable()
        .onKeyPress(.init("r"), phases: .down) { event in guard event.modifiers.contains(.command) else { return .ignored }; model.refreshLocal(); Task { await model.refreshRemote() }; return .handled }
        .onKeyPress(.init("l"), phases: .down) { event in guard event.modifiers.contains(.command) else { return .ignored }; localPathInput = model.localPath; editsLocalPath = true; return .handled }
    }

    private var selectedServer: Server? { serverManager.servers.first { $0.id == model.selectedServerID } }

    private var toolbar: some View {
        HStack(spacing: AppLayout.featureHeaderSpacing) {
            AppFeatureTitle("远程文件", subtitle: "本机与 SFTP 双栏文件管理")
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.connectionState == .connected ? Color.green : (model.connectionState == .connecting ? .orange : .secondary)).frame(width: 7, height: 7)
                Text(model.connectionState.title).lineLimit(1).font(.caption)
            }
            Menu {
                Button("断开连接", systemImage: "xmark.circle") { model.disconnect() }.disabled(model.connectionState == .disconnected)
                Divider()
                ForEach(serverManager.servers) { server in
                    Button { model.selectServer(server, credential: serverManager.credential(for: server)) } label: {
                        VStack { Text(server.name); Text(server.endpoint) }
                    }
                }
            } label: { Label(selectedServer?.name ?? "选择服务器", systemImage: "server.rack") }
            .menuStyle(.button).buttonStyle(.glass)
            Menu {
                Toggle("显示隐藏文件", isOn: $model.showsHiddenFiles)
                Toggle("显示传输队列", isOn: $model.showsTransfers)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(.glass)
                .help("文件视图选项")
                .accessibilityLabel("文件视图选项")
        }
        .appFeatureHeaderBackground(opacity: 0.58)
    }

    private func filePanel(title: String, symbol: String, path: String, pathInput: Binding<String>, editsPath: Binding<Bool>, items: [FileItem], selection: Binding<Set<String>>, isLocal: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                Button { isLocal ? model.localUp() : model.remoteUp() } label: { Image(systemName: "arrow.up") }.buttonStyle(.glass).help("上级目录")
                Button {
                    if isLocal { model.refreshLocal() }
                    else { Task { await model.refreshRemote() } }
                } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.glass).help("刷新")
                Button { model.promptForNewDirectory(isLocal: isLocal) } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.glass).disabled(!isLocal && model.connectionState != .connected).help("新建文件夹")
            }.padding(.horizontal, 14).frame(height: 45)
            pathBar(path: path, input: pathInput, edits: editsPath, isLocal: isLocal)
            Table(items, selection: selection) {
                TableColumn("名称") { item in
                    HStack(spacing: 7) {
                        Image(systemName: icon(for: item)).foregroundStyle(item.kind == .directory ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) { Text(item.name).lineLimit(1); if let target = item.linkTarget { Text("→ \(target)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }
                    }
                    .draggable("\(isLocal ? "inchspace-local:" : "inchspace-remote:")\(item.path)")
                }.width(min: 150, ideal: 260)
                TableColumn("大小") { item in Text(item.kind == .directory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).foregroundStyle(.secondary) }.width(min: 70, ideal: 90)
                TableColumn("修改时间") { item in Text(item.modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "—").foregroundStyle(.secondary) }.width(min: 110, ideal: 140)
                if !isLocal { TableColumn("权限") { item in Text(item.permissions ?? "—").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }.width(92) }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                selectionMenu(items.filter { ids.contains($0.id) }, isLocal: isLocal)
            } primaryAction: { ids in
                guard let item = items.first(where: { ids.contains($0.id) }) else { return }
                isLocal ? model.openLocal(item) : model.openRemote(item)
            }
            .dropDestination(for: URL.self) { urls, _ in guard !isLocal else { return false }; let lookup = Dictionary(uniqueKeysWithValues: model.localItems.map { (URL(fileURLWithPath: $0.path), $0) }); model.upload(urls.compactMap { lookup[$0] }); return true } isTargeted: { if !isLocal { remoteDropTargeted = $0 } }
            .dropDestination(for: String.self) { values, _ in
                if isLocal {
                    let paths = Set(values.compactMap { $0.hasPrefix("inchspace-remote:") ? String($0.dropFirst(17)) : nil })
                    model.download(model.remoteItems.filter { paths.contains($0.path) })
                    return !paths.isEmpty
                } else {
                    let paths = Set(values.compactMap { $0.hasPrefix("inchspace-local:") ? String($0.dropFirst(16)) : nil })
                    model.upload(model.localItems.filter { paths.contains($0.path) })
                    return !paths.isEmpty
                }
            } isTargeted: { targeted in if isLocal { localDropTargeted = targeted } else { remoteDropTargeted = targeted } }
            .overlay { if (isLocal ? localDropTargeted : remoteDropTargeted) { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2).padding(5).allowsHitTesting(false) } }
            HStack {
                Text("\(items.count) 个项目").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if isLocal { Button("上传", systemImage: "arrow.up") { model.upload() }.disabled(model.selectedLocalIDs.isEmpty || model.connectionState != .connected) }
                else { Button("下载", systemImage: "arrow.down") { model.download() }.disabled(model.selectedRemoteIDs.isEmpty || model.connectionState != .connected) }
            }.buttonStyle(.borderless).padding(.horizontal, 13).frame(height: 36).background(.ultraThinMaterial.opacity(0.36))
        }
    }

    private func pathBar(path: String, input: Binding<String>, edits: Binding<Bool>, isLocal: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "location").foregroundStyle(.secondary)
            if edits.wrappedValue {
                TextField("输入路径", text: input).textFieldStyle(.plain).onSubmit { if isLocal { model.navigateLocal(to: input.wrappedValue) } else { Task { await model.navigateRemote(to: input.wrappedValue) } }; edits.wrappedValue = false }
            } else {
                ScrollView(.horizontal, showsIndicators: false) { Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.system(.caption, design: .monospaced)).lineLimit(1).onTapGesture { input.wrappedValue = path; edits.wrappedValue = true } }
            }
        }.padding(.horizontal, 10).frame(height: 34).background(.ultraThinMaterial.opacity(0.48)).overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    @ViewBuilder private func selectionMenu(_ items: [FileItem], isLocal: Bool) -> some View {
        if isLocal {
            if let item = items.first, items.count == 1 {
                Button("打开") { model.openLocal(item) }
                Button("在 Finder 中显示") { LocalFileService().reveal(item) }
            }
            Button("上传到服务器") { model.upload(items) }.disabled(items.isEmpty || model.connectionState != .connected)
            if let item = items.first, items.count == 1 {
                Button("复制路径") { copy(item.path) }
                Button("重命名") { model.promptForRename(item, isLocal: true) }
            }
            Divider(); Button("移到废纸篓", role: .destructive) { model.pendingLocalDeletion = items }.disabled(items.isEmpty)
        } else {
            if let item = items.first, items.count == 1, item.kind != .file {
                Button("打开") { model.openRemote(item) }
            }
            Button("下载") { model.download(items) }.disabled(items.isEmpty)
            if let item = items.first, items.count == 1 {
                Button("复制远程路径") { copy(item.path) }
                Button("重命名") { model.promptForRename(item, isLocal: false) }
            }
            Divider(); Button("删除", role: .destructive) { model.pendingRemoteDeletion = items }.disabled(items.isEmpty)
        }
    }

    private var transferPanel: some View {
        VStack(spacing: 0) {
            HStack { Text("传输").font(.headline); Text("\(model.transfers.transfers.count)").font(.caption).foregroundStyle(.secondary); Spacer(); Button("清除已完成") { model.transfers.clearCompleted() }.buttonStyle(.borderless) }.padding(.horizontal, 14).frame(height: 35)
            Divider()
            if model.transfers.transfers.isEmpty { Text("暂无传输任务").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 56) }
            else {
                ScrollView { LazyVStack(spacing: 0) { ForEach(model.transfers.transfers) { transfer in transferRow(transfer); Divider().padding(.leading, 45) } } }.frame(maxHeight: 150)
            }
        }.background(.ultraThinMaterial).overlay(alignment: .top) { Divider() }
    }

    private func transferRow(_ transfer: FileTransfer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction.symbol).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(transfer.filename).lineLimit(1); Spacer(); Text(transfer.state.title).font(.caption).foregroundStyle(transfer.state == .failed ? Color.red : .secondary) }
                ProgressView(value: transfer.progress)
                HStack { Text("\(ByteCountFormatter.string(fromByteCount: transfer.transferredBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file))"); Spacer(); if transfer.bytesPerSecond > 0 { Text("\(ByteCountFormatter.string(fromByteCount: Int64(transfer.bytesPerSecond), countStyle: .file))/s") }; if let eta = transfer.eta { Text("剩余 \(Duration.seconds(eta).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))") } }.font(.caption2).foregroundStyle(.secondary)
            }
            if transfer.state == .transferring || transfer.state == .waiting { Button { model.transfers.cancel(transfer.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless) }
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func trustSheet(_ request: PendingHostTrust) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(request.changed ? "服务器身份已改变" : "无法验证服务器身份", systemImage: request.changed ? "exclamationmark.triangle.fill" : "lock.shield").font(.title2.weight(.semibold)).foregroundStyle(request.changed ? Color.orange : .primary)
            Text(request.changed ? "保存的 Host Key 与服务器当前提供的密钥不同。仅在确认服务器已重新配置后继续。" : "这是首次连接到此服务器。请通过可信渠道核对指纹。")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) { GridRow { Text("服务器").foregroundStyle(.secondary); Text(request.host) }; GridRow { Text("算法").foregroundStyle(.secondary); Text(request.algorithm) }; GridRow { Text("指纹").foregroundStyle(.secondary); Text(request.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled) } }
            HStack { Spacer(); Button("取消", role: .cancel) { model.pendingTrust = nil }; Button(request.changed ? "更新信任并连接" : "信任并连接") { if let selectedServer { model.trustAndConnect(request, server: selectedServer, credential: serverManager.credential(for: selectedServer)) } }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 530).background(.regularMaterial)
    }

    private func conflictSheet(_ conflict: PendingTransferConflict) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("“\(conflict.item.name)”已经存在", systemImage: "doc.on.doc").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Text("现有项目").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: conflict.existingSize, countStyle: .file)) }
                GridRow { Text("新项目").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: conflict.item.size, countStyle: .file)) }
                GridRow { Text("目标").foregroundStyle(.secondary); Text(conflict.destination).lineLimit(2).truncationMode(.middle) }
            }
            HStack { Button("取消") { model.resolveConflict(.cancel) }; Spacer(); Button("保留两者") { model.resolveConflict(.keepBoth) }; Button("替换") { model.resolveConflict(.replace) }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 520).background(.regularMaterial)
    }

    private func fileNameSheet(_ initial: FileNamePrompt) -> some View {
        FileNameSheet(prompt: initial) { model.applyFileNamePrompt($0) }
    }

    private func icon(for item: FileItem) -> String { item.kind == .directory ? "folder.fill" : (item.kind == .symbolicLink ? "link" : "doc") }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

private struct FileNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var prompt: FileNamePrompt
    let apply: (FileNamePrompt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(prompt.kind == .createDirectory ? "新建文件夹" : "重命名").font(.title2.weight(.semibold))
            TextField("名称", text: $prompt.name).textFieldStyle(.roundedBorder).onSubmit { apply(prompt); dismiss() }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("完成") { apply(prompt); dismiss() }.buttonStyle(.borderedProminent).disabled(prompt.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 420).background(.regularMaterial)
    }
}
