//
//  LaunchpadGroupOverlay.swift
//  inchspace
//
//  分组浮层：内部插入排序、拖出主页面、重命名和 Esc/外部点击关闭。
//

import SwiftUI

struct LaunchpadGroupOverlay: View {
    let group: LaunchGroup
    @ObservedObject var repository: LaunchpadRepository
    @ObservedObject var dragCoordinator: LaunchpadDragCoordinator
    let pageCapacity: Int
    let onOpenItem: (LaunchItem) -> Void
    let onRenameItem: (LaunchItem) -> Void
    let onDismiss: () -> Void

    @State private var name: String
    @State private var itemFrames = LaunchpadFrameStore()
    @State private var dragSlots: LaunchpadDragSlotSnapshot?
    @State private var isOutside = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        group: LaunchGroup,
        repository: LaunchpadRepository,
        dragCoordinator: LaunchpadDragCoordinator,
        pageCapacity: Int,
        onOpenItem: @escaping (LaunchItem) -> Void,
        onRenameItem: @escaping (LaunchItem) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.group = group
        self.repository = repository
        self.dragCoordinator = dragCoordinator
        self.pageCapacity = pageCapacity
        self.onOpenItem = onOpenItem
        self.onRenameItem = onRenameItem
        self.onDismiss = onDismiss
        _name = State(initialValue: group.name)
    }

    var body: some View {
        GeometryReader { outerProxy in
            ZStack {
                Color.black.opacity(0.20)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)

                VStack(spacing: 22) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.accentColor)
                        TextField("分组名称", text: $name)
                            .font(.title2.weight(.semibold))
                            .textFieldStyle(.plain)
                            .onSubmit(saveName)
                        Spacer()
                    }

                    groupGrid
                }
                .padding(28)
                .frame(
                    width: min(max(outerProxy.size.width * 0.68, 470), 720),
                    height: min(max(outerProxy.size.height * 0.62, 390), 570),
                    alignment: .top
                )
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.24), radius: 32, y: 16)
                .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .onTapGesture { }
            }
        }
        .onExitCommand(perform: close)
        .onDisappear {
            if dragCoordinator.state.isDraggingFromGroup {
                repository.cancelInteractiveMutation()
                dragCoordinator.finishDrag()
            }
            dragSlots = nil
            saveName()
        }
    }

    private var groupGrid: some View {
        GeometryReader { proxy in
            let members = repository.items(in: group.id)
            let columns = max(3, min(6, Int(proxy.size.width / 105)))

            ZStack {
                Color.clear
                    .contentShape(Rectangle())

                if members.isEmpty {
                    ContentUnavailableView("空分组", systemImage: "folder")
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns),
                            spacing: 22
                        ) {
                            ForEach(members) { item in
                                groupItemCell(item, bounds: CGRect(origin: .zero, size: proxy.size))
                            }
                        }
                        .padding(12)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.16),
                            value: group.itemIDs
                        )
                    }
                }

                if dragCoordinator.state.isDraggingFromGroup,
                   let draggedItemID = dragCoordinator.state.draggedEntryID,
                   let item = repository.item(withID: draggedItemID) {
                    LaunchpadPositionedGroupPreview(
                        item: item,
                        isOutside: isOutside,
                        dragPosition: dragCoordinator.dragPosition
                    )
                    .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "group-grid")
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("group-grid"))
                    .onEnded { value in
                        guard dragCoordinator.state.isEditing else { return }
                        let tappedItem = members.contains { item in
                            itemFrames[item.id]?.contains(value.location) == true
                        }
                        if !tappedItem { finishEditing() }
                    }
            )
        }
    }

    private func groupItemCell(_ item: LaunchItem, bounds: CGRect) -> some View {
        let isDragged = dragCoordinator.state.isDraggingFromGroup
            && dragCoordinator.state.draggedEntryID == item.id

        return VStack(spacing: 7) {
            LaunchpadIconImage(item: item, size: 58)
                .overlay(alignment: .topTrailing) {
                    if dragCoordinator.state.isEditing && !isDragged {
                        LaunchpadRemoveButton(
                            accessibilityLabel: "从工作台移除 \(item.name)",
                            helpText: "从工作台移除快捷入口",
                            action: { removeGroupItem(item.id) }
                        )
                        .offset(LaunchpadRemoveControlLayout.badgeOffset)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .zIndex(2)
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: dragCoordinator.state.isEditing && !isDragged
                )
                .launchpadJiggle(
                    id: item.id,
                    isActive: dragCoordinator.state.isEditing && !isDragged,
                    reduceMotion: reduceMotion
                )

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 88)
        }
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .top)
        .opacity(isDragged ? 0 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("打开", systemImage: "arrow.up.forward.app") { onOpenItem(item) }
            Button("重命名…", systemImage: "pencil") { onRenameItem(item) }
            Button("移出分组", systemImage: "arrowshape.turn.up.right") {
                moveOut(item.id)
            }
            Divider()
            Button("从工作台移除", systemImage: "trash", role: .destructive) {
                removeGroupItem(item.id)
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("group-grid"))
        } action: { frame in
            itemFrames[item.id] = frame
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("group-grid"))
                .onChanged { value in
                    handlePointerChanged(item: item, value: value, bounds: bounds)
                }
                .onEnded { _ in handlePointerEnded(item) }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard !dragCoordinator.state.isEditing else { return .ignored }
            onOpenItem(item)
            return .handled
        }
    }

    private func handlePointerChanged(item: LaunchItem, value: DragGesture.Value, bounds: CGRect) {
        guard !pointerStartsOnRemoveControl(item: item, value: value) else { return }

        if dragCoordinator.state.phase == .idle {
            dragCoordinator.beginPress(entryID: item.id, location: value.startLocation)
            return
        }

        if dragCoordinator.state.phase == .pressing {
            guard dragCoordinator.state.pressedEntryID == item.id else { return }
            dragCoordinator.updatePress(entryID: item.id, location: value.location)
            return
        }

        if dragCoordinator.state.phase == .editing {
            let distance = hypot(
                value.location.x - value.startLocation.x,
                value.location.y - value.startLocation.y
            )
            guard distance > LaunchpadInteractionConstants.dragStartDistance else { return }
            let members = repository.items(in: group.id)
            guard let sourceIndex = members.firstIndex(where: { $0.id == item.id }) else { return }
            repository.beginInteractiveMutation()
            dragSlots = makeDragSlots()
            dragCoordinator.beginDrag(
                entryID: item.id,
                pageIndex: 0,
                proposedIndex: sourceIndex,
                fromGroup: true
            )
        }

        guard dragCoordinator.state.isDraggingFromGroup,
              dragCoordinator.state.draggedEntryID == item.id else { return }
        dragCoordinator.updatePointer(value.location, pageIndex: 0)
        let pointerIsOutside = !bounds.insetBy(dx: -34, dy: -34).contains(value.location)
        if isOutside != pointerIsOutside {
            isOutside = pointerIsOutside
        }

        if dragSlots == nil { dragSlots = makeDragSlots() }
        guard !isOutside,
              let slots = dragSlots,
              let proposedIndex = LaunchpadLayoutEngine.proposedSlotIndex(
                  at: value.location,
                  in: slots.frames,
                  currentIndex: dragCoordinator.state.proposedIndex,
                  hysteresis: LaunchpadInteractionConstants.reorderHysteresis
              ),
              proposedIndex != dragCoordinator.state.proposedIndex else { return }
        repository.reorderItem(in: group.id, itemID: item.id, to: proposedIndex)
        dragCoordinator.updateProposedIndex(proposedIndex, pageIndex: 0)
    }

    private func pointerStartsOnRemoveControl(
        item: LaunchItem,
        value: DragGesture.Value
    ) -> Bool {
        guard dragCoordinator.state.isEditing,
              dragCoordinator.state.draggedEntryID != item.id,
              let cellFrame = itemFrames[item.id] else { return false }
        return LaunchpadRemoveControlLayout.hitFrame(in: cellFrame, iconSize: 58)
            .insetBy(dx: -2, dy: -2)
            .contains(value.startLocation)
    }

    private func handlePointerEnded(_ item: LaunchItem) {
        if dragCoordinator.state.isDraggingFromGroup,
           dragCoordinator.state.draggedEntryID == item.id {
            finishGroupDrag(item.id)
        } else if dragCoordinator.finishPress(entryID: item.id) {
            onOpenItem(item)
        }
    }

    private func makeDragSlots() -> LaunchpadDragSlotSnapshot? {
        let members = repository.items(in: group.id)
        let frames = members.compactMap { itemFrames[$0.id] }
        guard !frames.isEmpty, frames.count == members.count else { return nil }
        return LaunchpadDragSlotSnapshot(
            pageIndex: 0,
            entryIDs: members.map(\.id),
            frames: frames
        )
    }

    private func finishGroupDrag(_ itemID: UUID) {
        if isOutside {
            moveOut(itemID)
        }
        repository.commitInteractiveMutation(category: group.category, capacity: pageCapacity)
        dragSlots = nil
        isOutside = false
        dragCoordinator.finishDrag()
        if repository.group(withID: group.id) == nil { onDismiss() }
    }

    private func moveOut(_ itemID: UUID) {
        let page = repository.selectedPage(for: group.category, capacity: pageCapacity)
        let insertionIndex = min(
            (page + 1) * pageCapacity,
            repository.rootEntries(in: group.category).count
        )
        repository.moveItemOutOfGroup(itemID, insertAt: insertionIndex, capacity: pageCapacity)
    }

    private func removeGroupItem(_ itemID: UUID) {
        dragCoordinator.cancelPress()
        if reduceMotion {
            repository.deleteItem(itemID, capacity: pageCapacity)
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                repository.deleteItem(itemID, capacity: pageCapacity)
            }
        }
        if repository.group(withID: group.id) == nil { onDismiss() }
    }

    private func saveName() {
        repository.renameGroup(id: group.id, to: name)
    }

    private func finishEditing() {
        repository.cancelInteractiveMutation()
        dragSlots = nil
        isOutside = false
        dragCoordinator.reset()
        saveName()
        repository.saveImmediately()
    }

    private func close() {
        if dragCoordinator.state.isDraggingFromGroup {
            repository.cancelInteractiveMutation()
            dragCoordinator.finishDrag()
        } else {
            dragCoordinator.cancelPress()
        }
        dragSlots = nil
        isOutside = false
        saveName()
        onDismiss()
    }
}

private struct LaunchpadPositionedGroupPreview: View {
    let item: LaunchItem
    let isOutside: Bool
    @ObservedObject var dragPosition: LaunchpadDragPosition

    var body: some View {
        if let location = dragPosition.location {
            VStack(spacing: 6) {
                LaunchpadIconImage(item: item, size: 62)
                Text(item.name).font(.caption).lineLimit(1)
            }
            .opacity(0.95)
            .scaleEffect(isOutside ? 1.10 : 1.04)
            .shadow(color: .black.opacity(0.25), radius: 14, y: 7)
            .position(location)
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }
}
