//
//  WorkbenchView.swift
//  inchspace
//
//  工作台页面：分类、添加入口、网格与分组浮层的组合层。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchView: View {
    @ObservedObject var repository: LaunchpadRepository
    @StateObject private var dragCoordinator = LaunchpadDragCoordinator()
    @State private var category: LaunchItemCategory = .application
    @State private var openedGroupID: UUID?
    @State private var renameRequest: RenameRequest?
    @State private var websiteRequest: WebsiteEditRequest?
    @State private var presentedError: PresentedError?
    @State private var applicationOpenPanel: NSOpenPanel?
    @State private var currentCapacity = 24
    @EnvironmentObject private var visibilityController: AppVisibilityController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LaunchpadHeaderView(category: $category)
                    .padding(.horizontal, 34)
                    .padding(.top, 26)
                    .padding(.bottom, 16)

                LaunchpadGridView(
                    category: category,
                    repository: repository,
                    dragCoordinator: dragCoordinator,
                    openedGroupID: $openedGroupID,
                    capacity: $currentCapacity,
                    onOpenItem: open,
                    onRenameItem: { item in
                        renameRequest = RenameRequest(kind: .item(item.id), name: item.name)
                    },
                    onRenameGroup: { group in
                        renameRequest = RenameRequest(kind: .group(group.id), name: group.name)
                    },
                    onAddItem: addCurrentCategory,
                    onEditWebsite: { websiteRequest = WebsiteEditRequest(item: $0) },
                    onError: present
                )
            }
            .background {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.045), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .blur(radius: openedGroupID == nil ? 0 : 3)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: openedGroupID)

            if let openedGroupID,
               let group = repository.group(withID: openedGroupID) {
                LaunchpadGroupOverlay(
                    group: group,
                    repository: repository,
                    dragCoordinator: dragCoordinator,
                    pageCapacity: currentCapacity,
                    onOpenItem: open,
                    onRenameItem: { item in
                        renameRequest = RenameRequest(kind: .item(item.id), name: item.name)
                    },
                    onDismiss: { self.openedGroupID = nil }
                )
                .transition(.scale(scale: 0.94).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .onChange(of: category) { _, _ in
            repository.cancelInteractiveMutation()
            dragCoordinator.reset()
            openedGroupID = nil
        }
        .onChange(of: repository.library) { _, _ in
            if let openedGroupID, repository.group(withID: openedGroupID) == nil {
                self.openedGroupID = nil
            }
        }
        .onChange(of: repository.persistenceError) { _, message in
            if let message {
                presentedError = PresentedError(title: "持久化错误", message: message)
            }
        }
        .sheet(item: $renameRequest) { request in
            RenameSheet(request: request) { name in
                switch request.kind {
                case let .item(id): repository.renameItem(id: id, to: name)
                case let .group(id): repository.renameGroup(id: id, to: name)
                }
            }
        }
        .sheet(item: $websiteRequest) { request in
            WebsiteEditorSheet(item: request.item) { name, url, iconReference in
                saveWebsite(request.item, name: name, url: url, iconReference: iconReference)
            }
        }
        .alert(item: $presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("好")))
        }
        .onExitCommand {
            if openedGroupID != nil {
                openedGroupID = nil
            } else if dragCoordinator.state.phase != .idle {
                repository.cancelInteractiveMutation()
                dragCoordinator.reset()
            }
        }
    }

    private func addCurrentCategory() {
        switch category {
        case .application: chooseApplications()
        case .directory: chooseDirectory()
        case .website: websiteRequest = WebsiteEditRequest(item: nil)
        }
    }

    private func chooseApplications() {
        // Reuse the panel so AppKit keeps the browser's icon presentation between
        // consecutive additions instead of rebuilding it with a different view mode.
        let panel = applicationOpenPanel ?? NSOpenPanel()
        applicationOpenPanel = panel
        panel.title = "添加程序"
        panel.prompt = "添加"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                let bundle = Bundle(url: url)
                let bundleIdentifier = bundle?.bundleIdentifier ?? ""
                let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let bookmark = try? SecurityScopedBookmarkService.makeBookmark(for: url)
                let item = LaunchItem(
                    name: displayName,
                    category: .application,
                    target: .application(bundleIdentifier: bundleIdentifier, path: url.path),
                    bookmarkData: bookmark
                )
                do {
                    try repository.add(item, capacity: currentCapacity)
                } catch {
                    present(error)
                }
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "添加目录"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let bookmark = try SecurityScopedBookmarkService.makeBookmark(for: url)
                let item = LaunchItem(
                    name: url.lastPathComponent,
                    category: .directory,
                    target: .directory(path: url.path),
                    bookmarkData: bookmark
                )
                try repository.add(item, capacity: currentCapacity)
            } catch {
                present(error)
            }
        }
    }

    private func saveWebsite(_ existing: LaunchItem?, name: String, url: URL, iconReference: String?) {
        do {
            if let existing {
                LaunchpadIconProvider.shared.invalidate(existing)
                try repository.updateItem(
                    id: existing.id,
                    name: name,
                    target: .website(url: url.absoluteString),
                    iconReference: .some(iconReference)
                )
            } else {
                try repository.add(
                    LaunchItem(
                        name: name,
                        category: .website,
                        target: .website(url: url.absoluteString),
                        iconReference: iconReference
                    ),
                    capacity: currentCapacity
                )
            }
        } catch {
            present(error)
        }
    }

    private func open(_ item: LaunchItem) {
        Task {
            do {
                let destination = try await LaunchpadOpenService.open(item)
                repository.markOpened(itemID: item.id)
                visibilityController.hideAfterSuccessfulOpen(destination)
            } catch {
                repository.markUnavailable(itemID: item.id)
                present(error)
            }
        }
    }

    private func present(_ error: Error) {
        presentedError = PresentedError(title: "无法完成操作", message: error.localizedDescription)
    }
}

struct LaunchpadHeaderView: View {
    @Binding var category: LaunchItemCategory
    @Namespace private var selectionAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LaunchItemCategory.allCases) { category in
                categoryButton(category)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("分类")
        .frame(maxWidth: .infinity, minHeight: 38)
    }

    private func categoryButton(_ item: LaunchItemCategory) -> some View {
        Button {
            guard category != item else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                category = item
            }
        } label: {
            Text(item.title)
                .font(.system(size: 13, weight: category == item ? .semibold : .medium))
                .foregroundStyle(category == item ? Color.white : Color.primary.opacity(0.68))
                .frame(width: 72, height: 27)
                .background {
                    if category == item {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.90))
                            .matchedGeometryEffect(id: "selected-category", in: selectionAnimation)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(category == item ? .isSelected : [])
    }
}

struct PresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct RenameRequest: Identifiable {
    enum Kind { case item(UUID), group(UUID) }
    let id = UUID()
    let kind: Kind
    let name: String
}

struct RenameSheet: View {
    let request: RenameRequest
    let onSave: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(request: RenameRequest, onSave: @escaping (String) -> Void) {
        self.request = request
        self.onSave = onSave
        _name = State(initialValue: request.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名").font(.title2.weight(.semibold))
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

struct WebsiteEditRequest: Identifiable {
    let id = UUID()
    let item: LaunchItem?
}

struct WebsiteEditorSheet: View {
    let item: LaunchItem?
    let onSave: (String, URL, String?) -> Void
    @State private var name: String
    @State private var address: String
    @State private var iconAddress: String
    @State private var validationMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(item: LaunchItem?, onSave: @escaping (String, URL, String?) -> Void) {
        self.item = item
        self.onSave = onSave
        _name = State(initialValue: item?.name ?? "")
        if case let .website(url) = item?.target {
            _address = State(initialValue: url)
        } else {
            _address = State(initialValue: "")
        }
        _iconAddress = State(initialValue: item?.iconReference ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item == nil ? "添加网站" : "编辑网站")
                .font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $name)
                TextField("网址", text: $address, prompt: Text("example.com"))
                TextField("图标网址（可选）", text: $iconAddress)
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "请输入名称。"
            return
        }
        guard let url = LaunchpadOpenService.normalizedWebsiteURL(from: address) else {
            validationMessage = "请输入有效的 HTTP 或 HTTPS 地址。"
            return
        }
        let trimmedIcon = iconAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIcon = trimmedIcon.isEmpty ? nil : LaunchpadOpenService.normalizedWebsiteURL(from: trimmedIcon)
        if !trimmedIcon.isEmpty, normalizedIcon == nil {
            validationMessage = "图标网址无效。"
            return
        }
        onSave(trimmedName, url, normalizedIcon?.absoluteString)
        dismiss()
    }
}
