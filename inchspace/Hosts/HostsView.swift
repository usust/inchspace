import SwiftUI

struct HostsView: View {
    let onBack: () -> Void
    @StateObject private var model = HostsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            controls
            Divider()
            if model.entries.isEmpty { ContentUnavailableView("没有匹配的 Hosts", systemImage: "network", description: Text("更改搜索或筛选条件，或新建一条记录。")) }
            else { list }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.editor) { draft in HostEditorSheet(draft: draft, save: model.saveEditor) }
        .sheet(isPresented: $model.showsRaw) { rawSheet }
        .sheet(isPresented: $model.showsBackups) { backupsSheet }
        .alert(item: $model.presentedError) { error in Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("好"))) }
        .alert("操作完成", isPresented: Binding(get: { model.successMessage != nil }, set: { if !$0 { model.successMessage = nil } })) { Button("好") { model.successMessage = nil } } message: { Text(model.successMessage ?? "") }
        .confirmationDialog("删除 \(model.pendingDeletion?.hostnameText ?? "此 Hosts 项")？", isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { model.deleteConfirmed() }; Button("取消", role: .cancel) { model.pendingDeletion = nil }
        } message: { if let entry = model.pendingDeletion { Text("\(entry.address)  \(entry.hostnameText)") } }
        .task { model.load() }
        .onKeyPress(.init("f"), phases: .down) { event in event.modifiers.contains(.command) ? .handled : .ignored }
        .onKeyPress(.init("n"), phases: .down) { event in guard event.modifiers.contains(.command) else { return .ignored }; model.newEntry(); return .handled }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) { Image(systemName: "chevron.left") }.buttonStyle(.glass).help("返回开发工具")
            VStack(alignment: .leading, spacing: 2) { Text("Hosts").font(.system(size: 26, weight: .bold, design: .rounded)); Text("管理本机 /etc/hosts").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if model.isSaving { ProgressView().controlSize(.small); Text("正在应用…").font(.caption).foregroundStyle(.secondary) }
            Button("新建", systemImage: "plus") { model.newEntry() }.buttonStyle(.glassProminent)
            Menu {
                Button("刷新", systemImage: "arrow.clockwise") { model.load() }
                Button("查看原始 Hosts", systemImage: "doc.plaintext") { model.showsRaw = true }
                Divider(); Button("查看与恢复备份", systemImage: "clock.arrow.circlepath") { model.loadBackups() }
                Button("刷新 DNS", systemImage: "arrow.triangle.2.circlepath") { model.flushDNS() }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(.glass)
        }.padding(.horizontal, 22).frame(height: 68).background(.ultraThinMaterial.opacity(0.58))
    }

    private var controls: some View {
        HStack(spacing: 14) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索 IP、Hostname 或备注", text: $model.searchText).textFieldStyle(.plain); if !model.searchText.isEmpty { Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary) } }
                .padding(.horizontal, 11).frame(maxWidth: 380).frame(height: 36).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
            Picker("状态", selection: $model.filter) { ForEach(HostsFilter.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 210)
            Spacer(); Text("\(model.entries.count) 项").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }

    private var list: some View {
        Table(model.entries) {
            TableColumn("状态") { entry in Button { model.toggle(entry) } label: { HStack(spacing: 6) { Circle().fill(entry.enabled ? Color.green : .secondary.opacity(0.45)).frame(width: 8, height: 8); Text(entry.enabled ? "启用" : "停用") } }.buttonStyle(.plain).disabled(entry.isSystem) }.width(80)
            TableColumn("IP") { entry in Text(entry.address).font(.system(.body, design: .monospaced)).textSelection(.enabled) }.width(min: 125, ideal: 180)
            TableColumn("Hostname") { entry in HStack { Text(entry.hostnameText).textSelection(.enabled); if entry.isSystem { Text("System").font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) } } }.width(min: 190, ideal: 310)
            TableColumn("备注") { entry in Text(entry.comment.isEmpty ? "—" : entry.comment).foregroundStyle(entry.comment.isEmpty ? .tertiary : .secondary) }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let entry = model.entries.first(where: { ids.contains($0.id) }) { Button("编辑") { model.edit(entry) }; Button(entry.enabled ? "停用" : "启用") { model.toggle(entry) }.disabled(entry.isSystem); Divider(); Button("复制 IP") { model.copy(entry.address) }; Button("复制 Hostname") { model.copy(entry.hostnameText) }; Divider(); Button("删除", role: .destructive) { model.pendingDeletion = entry }.disabled(entry.isSystem) }
        } primaryAction: { ids in if let entry = model.entries.first(where: { ids.contains($0.id) }) { model.edit(entry) } }
    }

    private var rawSheet: some View {
        VStack(spacing: 0) { HStack { Text("/etc/hosts").font(.headline); Spacer(); Button("完成") { model.showsRaw = false } }.padding(); Divider(); ScrollView([.horizontal, .vertical]) { Text(model.document.rendered).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding() } }
            .frame(minWidth: 680, minHeight: 500).background(.regularMaterial)
    }

    private var backupsSheet: some View {
        VStack(spacing: 0) { HStack { Text("Hosts 备份").font(.headline); Spacer(); Button("完成") { model.showsBackups = false } }.padding(); Divider(); if model.backups.isEmpty { ContentUnavailableView("暂无备份", systemImage: "clock.arrow.circlepath") } else { List(model.backups, id: \.self) { backup in HStack { VStack(alignment: .leading) { Text(backup.lastPathComponent); Text(backup.path).font(.caption2).foregroundStyle(.secondary) }; Spacer(); Button("恢复") { model.restore(backup) }.disabled(model.isSaving) } } } }
            .frame(width: 650, height: 440).background(.regularMaterial)
    }
}

private struct HostEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: HostEditorDraft
    let save: (HostEditorDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.entry == nil ? "新建 Host" : "编辑 Host").font(.title2.weight(.semibold))
            Form { TextField("IP 地址", text: $draft.address); TextField("Hostname", text: $draft.hostnames, axis: .vertical).lineLimit(2...4); TextField("备注", text: $draft.comment) }
            Text("多个 Hostname 可用空格、逗号或换行分隔。保存时会请求管理员授权。 ").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消", role: .cancel) { dismiss() }; Button("保存并应用") { save(draft); dismiss() }.buttonStyle(.borderedProminent).disabled(draft.address.trimmingCharacters(in: .whitespaces).isEmpty || draft.hostnames.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 480).background(.regularMaterial)
    }
}
