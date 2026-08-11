import AppKit
import SwiftUI

struct RunnerServersView: View {
    @ObservedObject var store: RunnerStore
    @State private var selection: UUID?
    @State private var showsAddServer = false
    @State private var pendingAction: RemotePendingAction?
    @State private var logPresentation: ServiceLogPresentation?

    var body: some View {
        HStack(spacing: 0) {
            serverList
            Divider()
            if let server = selectedServer { serverDetail(server) }
            else { emptyDetail }
        }
        .sheet(isPresented: $showsAddServer) {
            RunnerServerEditor { server in
                store.addServer(server)
                selection = server.id
                Task { await store.refreshServer(server) }
            }
        }
        .confirmationDialog(
            pendingAction?.title ?? "确认操作",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(pendingAction.buttonTitle, role: pendingAction.action == .stop ? .destructive : nil) {
                    Task { await store.operateRemoteService(pendingAction.service, on: pendingAction.server, action: pendingAction.action) }
                    self.pendingAction = nil
                }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: { Text("操作会立即应用到远程服务器，请确认没有正在进行的重要工作。") }
        .sheet(item: $logPresentation) { ServiceTextLogView(title: $0.title, text: $0.text) }
        .onAppear { if selection == nil { selection = store.servers.first?.id } }
    }

    private var selectedServer: RunnerServer? { store.servers.first { $0.id == selection } }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("服务器").font(.title3.weight(.semibold))
                Spacer()
                Button { showsAddServer = true } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 18).padding(.top, 22)
            if store.servers.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "server.rack").font(.title).foregroundStyle(.secondary)
                    Text("尚未添加服务器").font(.caption).foregroundStyle(.secondary)
                    Button("添加服务器") { showsAddServer = true }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.servers) { server in
                            Button {
                                selection = server.id
                                Task { await store.refreshServer(server) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "server.rack")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name).font(.subheadline.weight(.medium))
                                        Text(server.host).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 11).frame(height: 52)
                                .background(selection == server.id ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 9)
                }
            }
        }
        .frame(width: 220)
        .background(.ultraThinMaterial.opacity(0.55))
    }

    private func serverDetail(_ server: RunnerServer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name).font(.title2.weight(.semibold))
                        Label("\(server.username)@\(server.host):\(server.port)", systemImage: "lock.shield.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("移除", role: .destructive) {
                        store.deleteServer(server.id); selection = store.servers.first?.id
                    }.buttonStyle(.bordered)
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refreshServer(server) } }
                        .buttonStyle(.borderedProminent)
                }

                let services = store.remoteServices[server.id] ?? []
                if services.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "network").font(.system(size: 35)).foregroundStyle(Color.accentColor)
                        Text("连接服务器以查看服务").font(.headline)
                        Button("连接", systemImage: "link") { Task { await store.refreshServer(server) } }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300).runnerGlassCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                            remoteServiceRow(service, server: server)
                            if index < services.count - 1 { Divider().padding(.leading, 60) }
                        }
                    }
                    .padding(.vertical, 5).runnerGlassCard()
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 26)
        }
    }

    private func remoteServiceRow(_ service: RunnerService, server: RunnerServer) -> some View {
        let busyID = "\(server.id):\(service.id)"
        return HStack(spacing: 13) {
            Image(systemName: "gearshape.2.fill").foregroundStyle(runnerStatusColor(service.state)).frame(width: 34, height: 34)
                .background(runnerStatusColor(service.state).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName).font(.body.weight(.medium))
                Text(service.detail ?? "服务器服务").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            StatusBadge(state: service.state)
            if store.busyServiceIDs.contains(busyID) { ProgressView().controlSize(.small).frame(width: 70) }
            else {
                if service.state == .running {
                    Button("停止") { pendingAction = RemotePendingAction(server: server, service: service, action: .stop) }.buttonStyle(.bordered)
                    Button("重启") { pendingAction = RemotePendingAction(server: server, service: service, action: .restart) }.buttonStyle(.bordered)
                } else {
                    Button("启动") { pendingAction = RemotePendingAction(server: server, service: service, action: .start) }.buttonStyle(.borderedProminent)
                }
                Button("日志") {
                    Task {
                        let text = await store.remoteServiceLogs(service, on: server)
                        logPresentation = ServiceLogPresentation(title: "\(service.displayName) · \(server.name)", text: text)
                    }
                }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small).padding(.horizontal, 18).frame(minHeight: 64)
    }

    private var emptyDetail: some View {
        ContentUnavailableView("选择一台服务器", systemImage: "server.rack")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RemotePendingAction: Identifiable {
    let id = UUID()
    let server: RunnerServer
    let service: RunnerService
    let action: RunnerServiceAction
    var buttonTitle: String { switch action { case .start: "启动"; case .stop: "停止"; case .restart: "重启" } }
    var title: String { "在“\(server.name)”上\(buttonTitle)“\(service.displayName)”？" }
}

private struct RunnerServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = RunnerServer(name: "", host: "", username: "")
    @State private var password = ""
    @State private var errorMessage: String?
    let onSave: (RunnerServer) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加服务器").font(.title2.weight(.bold))
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(22)
            Divider()
            Form {
                TextField("名称", text: $server.name, prompt: Text("生产服务器"))
                TextField("地址", text: $server.host, prompt: Text("192.168.1.100"))
                TextField("用户名", text: $server.username, prompt: Text("root"))
                TextField("端口", value: $server.port, format: .number)
                Picker("认证方式", selection: $server.authentication) {
                    ForEach(RunnerServerAuthentication.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                if server.authentication == .password {
                    SecureField("密码", text: $password, prompt: Text("服务器登录密码"))
                } else {
                    LabeledContent("SSH Key") {
                        HStack {
                            Text(server.keyPath.isEmpty ? "尚未选择" : URL(fileURLWithPath: server.keyPath).lastPathComponent)
                                .foregroundStyle(server.keyPath.isEmpty ? .secondary : .primary)
                            Button("选择…", action: selectKey)
                        }
                    }
                }
                if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            .formStyle(.grouped).padding(10)
        }
        .frame(width: 540, height: 430).background(.regularMaterial)
    }

    private func selectKey() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                server.keyPath = url.path
                server.keyBookmark = try SecurityScopedBookmarkService.makeBookmark(for: url)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func save() {
        let hasAuthentication = server.authentication == .password ? !password.isEmpty : !server.keyPath.isEmpty
        guard !server.name.isEmpty, !server.host.isEmpty, !server.username.isEmpty, hasAuthentication, (1...65535).contains(server.port) else {
            errorMessage = RunnerError.serverConfiguration.localizedDescription
            return
        }
        do {
            if server.authentication == .password {
                try RunnerServerCredentialStore.savePassword(password, for: server.id)
            }
            onSave(server)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
