//
//  LaunchpadGridView.swift
//  inchspace
//
//  自适应分页网格、实时插入重排、中心悬停成组和边缘翻页。
//

import AppKit
import SwiftUI

struct LaunchpadGridView: View {
    let category: LaunchItemCategory
    @ObservedObject var repository: LaunchpadRepository
    @ObservedObject var dragCoordinator: LaunchpadDragCoordinator
    @Binding var openedGroupID: UUID?
    @Binding var capacity: Int
    let onOpenItem: (LaunchItem) -> Void
    let onRenameItem: (LaunchItem) -> Void
    let onRenameGroup: (LaunchGroup) -> Void
    let onAddItem: () -> Void
    let onEditWebsite: (LaunchItem) -> Void
    let onError: (Error) -> Void

    @State private var cellFrames = LaunchpadFrameStore()
    @State private var dragSlots: LaunchpadDragSlotSnapshot?
    @State private var showsInsertionGap = false
    @State private var lastScrollTurn = Date.distantPast
    @State private var groupPendingDissolution: LaunchGroup?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let metrics = LaunchpadGridMetrics(size: proxy.size)
            gridContent(metrics: metrics)
                .task(id: metrics.capacity) {
                    capacity = metrics.capacity
                    repository.normalize(category: category, capacity: metrics.capacity)
                }
        }
        .coordinateSpace(name: "launchpad-grid")
        .onDisappear {
            if dragCoordinator.state.phase != .idle {
                repository.cancelInteractiveMutation()
                dragCoordinator.reset()
            }
            dragSlots = nil
            showsInsertionGap = false
        }
        .confirmationDialog(
            groupPendingDissolution.map { "解散“\($0.name)”？" } ?? "解散程序组？",
            isPresented: Binding(
                get: { groupPendingDissolution != nil },
                set: { if !$0 { groupPendingDissolution = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("解散程序组，保留里面的程序") {
                guard let group = groupPendingDissolution else { return }
                performGroupDissolution(group.id, capacity: capacity)
                groupPendingDissolution = nil
            }
            Button("取消", role: .cancel) {
                groupPendingDissolution = nil
            }
        } message: {
            Text("组内程序会按当前顺序回到启动台，程序本身不会被删除。")
        }
    }

    @ViewBuilder
    private func gridContent(metrics: LaunchpadGridMetrics) -> some View {
        let pages = repository.pages(in: category, capacity: metrics.capacity)
        let currentPage = repository.selectedPage(for: category, capacity: metrics.capacity)
        let entries = pages[safe: currentPage]?.entries ?? []
        let displayedEntries = compactedEntries(entries)
        let availableGroups = repository.groups(in: category)

        VStack(spacing: 8) {
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: exitEditing)
                    .contextMenu {
                        Button(category.addTitle, systemImage: "plus", action: onAddItem)
                    }

                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("还没有\(category.title)", systemImage: emptySymbol)
                    } description: {
                        Text(category.emptyDescription)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVGrid(
                        columns: metrics.gridItems,
                        alignment: .center,
                        spacing: metrics.verticalSpacing
                    ) {
                        ForEach(displayedEntries) { entry in
                            entryCell(
                                entry,
                                availableGroups: availableGroups,
                                metrics: metrics,
                                pageIndex: currentPage
                            )
                                .frame(height: metrics.cellHeight)
                        }
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id("\(category.rawValue)-\(currentPage)")
                    .transition(.opacity.combined(with: .offset(x: 20)))
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.16),
                        value: displayedEntries.map(\.id)
                    )
                }

                if let draggedID = dragCoordinator.state.draggedEntryID,
                   let draggedEntry = entry(withID: draggedID) {
                    LaunchpadPositionedFloatingPreview(
                        entry: draggedEntry,
                        groupItems: groupItems(for: draggedEntry),
                        isGroupCandidate: dragCoordinator.state.isFolderMergeReady,
                        dragPosition: dragCoordinator.dragPosition
                    )
                    .allowsHitTesting(false)
                    .zIndex(20)
                }
            }
            .background {
                ScrollWheelMonitor { direction in
                    guard !dragCoordinator.state.isDragging,
                          dragCoordinator.state.phase != .pressing,
                          Date().timeIntervalSince(lastScrollTurn) > 0.45 else { return }
                    lastScrollTurn = Date()
                    turnPage(direction: direction, metrics: metrics, carriesDraggedEntry: false)
                }
            }

            LaunchpadPageIndicator(
                pageCount: pages.count,
                currentPage: currentPage,
                canGoBackward: currentPage > 0,
                canGoForward: currentPage + 1 < pages.count,
                selectPage: { page in
                    guard !dragCoordinator.state.isDragging else { return }
                    dragCoordinator.cancelPress()
                    withPageAnimation {
                        repository.setSelectedPage(page, for: category, capacity: metrics.capacity)
                    }
                },
                moveBackward: { turnPage(direction: -1, metrics: metrics, carriesDraggedEntry: false) },
                moveForward: { turnPage(direction: 1, metrics: metrics, carriesDraggedEntry: false) }
            )
            .padding(.bottom, 16)
        }
    }

    /// Keep the dragged cell alive so its gesture continues receiving events.
    /// Away from the grid its invisible placeholder moves to the end, closing
    /// the source gap. Over the grid it stays at the proposed model position,
    /// opening an insertion gap and pushing following icons backward.
    private func compactedEntries(_ entries: [LaunchEntry]) -> [LaunchEntry] {
        guard !showsInsertionGap else { return entries }
        guard let draggedID = dragCoordinator.state.draggedEntryID,
              let draggedIndex = entries.firstIndex(where: { $0.id == draggedID }),
              draggedIndex != entries.index(before: entries.endIndex) else { return entries }

        var result = entries
        result.append(result.remove(at: draggedIndex))
        return result
    }

    private func entryCell(
        _ entry: LaunchEntry,
        availableGroups: [LaunchGroup],
        metrics: LaunchpadGridMetrics,
        pageIndex: Int
    ) -> some View {
        let isDragged = dragCoordinator.state.draggedEntryID == entry.id
        let isCandidate = dragCoordinator.state.isFolderMergeReady
            && dragCoordinator.state.folderMergeTargetID == entry.id

        return LaunchpadEntryCell(
            entry: entry,
            groupItems: groupItems(for: entry),
            availableGroups: availableGroups,
            isDragged: isDragged,
            isGroupCandidate: isCandidate,
            isEditing: dragCoordinator.state.isEditing,
            onOpen: { open(entry) },
            onRename: { rename(entry) },
            onMoveToGroup: { groupID in
                repository.moveItem(entry.id, toGroup: groupID, category: category, capacity: metrics.capacity)
            },
            onDelete: { removeShortcut(entry.id, capacity: metrics.capacity) },
            onReveal: { reveal(entry) },
            onEditWebsite: {
                if case let .item(item) = entry { onEditWebsite(item) }
            },
            onDissolveGroup: {
                requestGroupDissolution(entry.id)
            }
        )
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("launchpad-grid"))
        } action: { frame in
            cellFrames[entry.id] = frame
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("launchpad-grid"))
                .onChanged { value in
                    handlePointerChanged(entry: entry, value: value, metrics: metrics, pageIndex: pageIndex)
                }
                .onEnded { _ in
                    handlePointerEnded(entry: entry, metrics: metrics)
                }
        )
    }

    private func handlePointerChanged(
        entry: LaunchEntry,
        value: DragGesture.Value,
        metrics: LaunchpadGridMetrics,
        pageIndex: Int
    ) {
        guard !pointerStartsOnRemoveControl(entry: entry, value: value) else { return }

        if dragCoordinator.state.phase == .idle {
            dragCoordinator.beginPress(entryID: entry.id, location: value.startLocation)
            return
        }

        if dragCoordinator.state.phase == .pressing {
            guard dragCoordinator.state.pressedEntryID == entry.id else { return }
            dragCoordinator.updatePress(entryID: entry.id, location: value.location)
            return
        }

        if dragCoordinator.state.phase == .editing {
            let distance = hypot(
                value.location.x - value.startLocation.x,
                value.location.y - value.startLocation.y
            )
            guard distance > LaunchpadInteractionConstants.dragStartDistance else { return }
            repository.beginInteractiveMutation()
            let flatIndex = repository.rootEntries(in: category).firstIndex { $0.id == entry.id } ?? 0
            dragSlots = makeDragSlots(pageIndex: pageIndex, capacity: metrics.capacity)
            let dragCenterOffset: CGSize
            if let sourceFrame = cellFrames[entry.id] {
                dragCenterOffset = CGSize(
                    width: sourceFrame.midX - value.startLocation.x,
                    height: sourceFrame.minY
                        + LaunchpadInteractionConstants.rootIconSize / 2
                        - value.startLocation.y
                )
            } else {
                dragCenterOffset = .zero
            }
            dragCoordinator.beginDrag(
                entryID: entry.id,
                pageIndex: pageIndex,
                proposedIndex: flatIndex,
                dragCenterOffset: dragCenterOffset
            )
        }
        guard dragCoordinator.state.draggedEntryID == entry.id else { return }

        let dragCenter = dragCoordinator.dragCenter(for: value.location)
        handleDragChanged(location: dragCenter, metrics: metrics)
    }

    private func pointerStartsOnRemoveControl(
        entry: LaunchEntry,
        value: DragGesture.Value
    ) -> Bool {
        guard dragCoordinator.state.isEditing,
              dragCoordinator.state.draggedEntryID != entry.id,
              case .item = entry,
              let cellFrame = cellFrames[entry.id] else { return false }
        return LaunchpadRemoveControlLayout.hitFrame(in: cellFrame, iconSize: 68)
            .insetBy(dx: -2, dy: -2)
            .contains(value.startLocation)
    }

    private func handlePointerEnded(entry: LaunchEntry, metrics: LaunchpadGridMetrics) {
        if dragCoordinator.state.draggedEntryID == entry.id {
            finishDrag(metrics: metrics)
        } else {
            let endedTrackedPress = dragCoordinator.state.pressedEntryID == entry.id
            if dragCoordinator.finishPress(entryID: entry.id) {
                open(entry)
            } else if !endedTrackedPress,
                      dragCoordinator.state.phase == .editing,
                      case .group = entry {
                open(entry)
            }
        }
    }

    private func handleDragChanged(location: CGPoint, metrics: LaunchpadGridMetrics) {
        guard dragCoordinator.state.isDragging else { return }

        let currentPage = repository.selectedPage(for: category, capacity: metrics.capacity)
        if dragSlots?.pageIndex != currentPage {
            dragSlots = makeDragSlots(pageIndex: currentPage, capacity: metrics.capacity)
        }
        guard let slots = dragSlots else {
            showsInsertionGap = false
            dragCoordinator.updatePointer(location, pageIndex: currentPage)
            return
        }

        dragCoordinator.updatePointer(location, pageIndex: currentPage)
        showsInsertionGap = isNearReorderSlot(location, slots: slots)
        let centerCandidate = folderCandidate(
            at: location,
            slots: slots
        )

        dragCoordinator.hoverOver(candidateID: centerCandidate, location: location)

        // A candidate owns the interaction from the first frame in the merge
        // zone. The hover delay confirms the drop; it must not delay the
        // reorder lock or the destination will move before it can spring-load.
        if showsInsertionGap,
           dragCoordinator.state.folderMergeTargetID == nil,
           let proposedIndex = proposedFlatIndex(
               at: location,
               slots: slots,
               pageIndex: currentPage,
               capacity: metrics.capacity
           ),
           proposedIndex != dragCoordinator.state.proposedIndex,
           let draggedID = dragCoordinator.state.draggedEntryID {
            repository.moveRootEntry(
                id: draggedID,
                toFlatIndex: proposedIndex,
                category: category,
                capacity: metrics.capacity
            )
            dragCoordinator.updateProposedIndex(proposedIndex, pageIndex: currentPage)
        }

        let edgeDirection: Int?
        if location.x < metrics.edgePagingWidth {
            edgeDirection = -1
        } else if location.x > metrics.size.width - metrics.edgePagingWidth {
            edgeDirection = 1
        } else {
            edgeDirection = nil
        }
        dragCoordinator.scheduleEdgeTurn(direction: edgeDirection) { direction in
            turnPage(direction: direction, metrics: metrics, carriesDraggedEntry: true)
        }
    }

    private func isNearReorderSlot(
        _ location: CGPoint,
        slots: LaunchpadDragSlotSnapshot
    ) -> Bool {
        let proximity: CGFloat = 12
        return slots.frames.contains {
            $0.insetBy(dx: -proximity, dy: -proximity).contains(location)
        }
    }

    private func folderCandidate(
        at location: CGPoint,
        slots: LaunchpadDragSlotSnapshot
    ) -> UUID? {
        guard category == .application,
              let draggedID = dragCoordinator.state.draggedEntryID,
              let draggedItem = repository.item(withID: draggedID),
              draggedItem.category == .application,
              draggedItem.groupID == nil else { return nil }

        if let lockedID = dragCoordinator.state.folderMergeTargetID,
           let lockedIndex = slots.entryIDs.firstIndex(of: lockedID),
           slots.frames.indices.contains(lockedIndex) {
            let lockedFrame = cellFrames[lockedID] ?? slots.frames[lockedIndex]
            let exitFrame = LaunchpadLayoutEngine.folderActivationFrame(
                in: lockedFrame,
                iconSize: LaunchpadInteractionConstants.rootIconSize,
                activationFraction: LaunchpadInteractionConstants.folderMergeZoneScale,
                expansion: LaunchpadInteractionConstants.folderExitTolerance
            )
            if exitFrame.contains(location) { return lockedID }
        }

        for (index, targetID) in slots.entryIDs.enumerated() where targetID != draggedID {
            guard let target = entry(withID: targetID), isValidFolderTarget(target) else { continue }
            let currentFrame = cellFrames[targetID] ?? slots.frames[index]
            let activationFrame = LaunchpadLayoutEngine.folderActivationFrame(
                in: currentFrame,
                iconSize: LaunchpadInteractionConstants.rootIconSize,
                activationFraction: LaunchpadInteractionConstants.folderMergeZoneScale
            )
            if activationFrame.contains(location) { return targetID }
        }
        return nil
    }

    private func isValidFolderTarget(_ entry: LaunchEntry) -> Bool {
        switch entry {
        case let .item(item):
            return item.category == .application && item.groupID == nil
        case let .group(group):
            return group.category == .application
        }
    }

    private func proposedFlatIndex(
        at location: CGPoint,
        slots: LaunchpadDragSlotSnapshot,
        pageIndex: Int,
        capacity: Int
    ) -> Int? {
        let currentLocalIndex = dragCoordinator.state.proposedIndex.map { $0 - pageIndex * capacity }
        guard let localIndex = LaunchpadLayoutEngine.proposedSlotIndex(
            at: location,
            in: slots.frames,
            currentIndex: currentLocalIndex,
            hysteresis: LaunchpadInteractionConstants.reorderHysteresis,
            commitFraction: LaunchpadInteractionConstants.reorderCommitFraction
        ) else { return nil }
        let lastIndex = max(repository.rootEntries(in: category).count - 1, 0)
        return min(pageIndex * capacity + localIndex, lastIndex)
    }

    private func finishDrag(metrics: LaunchpadGridMetrics) {
        guard let draggedID = dragCoordinator.state.draggedEntryID else { return }
        do {
            if let groupTarget = dragCoordinator.committedGroupTarget {
                try repository.completeGroupDrop(
                    draggedID: draggedID,
                    targetID: groupTarget,
                    category: category,
                    capacity: metrics.capacity
                )
            } else if !showsInsertionGap {
                let lastIndex = max(repository.rootEntries(in: category).count - 1, 0)
                repository.moveRootEntry(
                    id: draggedID,
                    toFlatIndex: lastIndex,
                    category: category,
                    capacity: metrics.capacity
                )
            }
            repository.commitInteractiveMutation(category: category, capacity: metrics.capacity)
        } catch {
            repository.cancelInteractiveMutation()
            onError(error)
        }
        dragSlots = nil
        showsInsertionGap = false
        dragCoordinator.finishDrag()
    }

    private func turnPage(direction: Int, metrics: LaunchpadGridMetrics, carriesDraggedEntry: Bool) {
        if !carriesDraggedEntry {
            guard !dragCoordinator.state.isDragging else { return }
            dragCoordinator.cancelPress()
        }
        let pages = repository.pages(in: category, capacity: metrics.capacity)
        let current = repository.selectedPage(for: category, capacity: metrics.capacity)
        let destination = min(max(current + direction, 0), max(pages.count - 1, 0))
        guard destination != current else { return }

        dragSlots = nil
        withPageAnimation {
            repository.setSelectedPage(destination, for: category, capacity: metrics.capacity)
            if carriesDraggedEntry, let draggedID = dragCoordinator.state.draggedEntryID {
                let rootCount = repository.rootEntries(in: category).count
                let destinationIndex = direction > 0
                    ? min(destination * metrics.capacity, rootCount - 1)
                    : min((destination + 1) * metrics.capacity - 1, rootCount - 1)
                repository.moveRootEntry(
                    id: draggedID,
                    toFlatIndex: max(destinationIndex, 0),
                    category: category,
                    capacity: metrics.capacity
                )
                dragCoordinator.updateProposedIndex(max(destinationIndex, 0), pageIndex: destination)
            }
        }
    }

    private func makeDragSlots(pageIndex: Int, capacity: Int) -> LaunchpadDragSlotSnapshot? {
        let entries = repository.pages(in: category, capacity: capacity)[safe: pageIndex]?.entries ?? []
        let frames = entries.compactMap { cellFrames[$0.id] }
        guard !frames.isEmpty, frames.count == entries.count else { return nil }
        return LaunchpadDragSlotSnapshot(
            pageIndex: pageIndex,
            entryIDs: entries.map(\.id),
            frames: frames
        )
    }

    private func exitEditing() {
        guard dragCoordinator.state.phase != .idle else { return }
        repository.cancelInteractiveMutation()
        dragSlots = nil
        showsInsertionGap = false
        dragCoordinator.reset()
    }

    private func withPageAnimation(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.easeInOut(duration: 0.22), changes)
        }
    }

    private func entry(withID id: UUID) -> LaunchEntry? {
        if let item = repository.item(withID: id), item.groupID == nil { return .item(item) }
        if let group = repository.group(withID: id) { return .group(group) }
        return nil
    }

    private func groupItems(for entry: LaunchEntry) -> [LaunchItem] {
        if case let .group(group) = entry { return repository.items(in: group.id) }
        return []
    }

    private func open(_ entry: LaunchEntry) {
        switch entry {
        case let .item(item): onOpenItem(item)
        case let .group(group): openedGroupID = group.id
        }
    }

    private func rename(_ entry: LaunchEntry) {
        switch entry {
        case let .item(item): onRenameItem(item)
        case let .group(group): onRenameGroup(group)
        }
    }

    private func removeShortcut(_ itemID: UUID, capacity: Int) {
        dragCoordinator.cancelPress()
        withRemovalAnimation {
            repository.deleteItem(itemID, capacity: capacity)
        }
    }

    private func requestGroupDissolution(_ groupID: UUID) {
        dragCoordinator.cancelPress()
        groupPendingDissolution = repository.group(withID: groupID)
    }

    private func performGroupDissolution(_ groupID: UUID, capacity: Int) {
        withRemovalAnimation {
            repository.dissolveGroup(groupID, capacity: capacity)
        }
    }

    private func withRemovalAnimation(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.easeOut(duration: 0.16), changes)
        }
    }

    private func reveal(_ entry: LaunchEntry) {
        guard case let .item(item) = entry else { return }
        do { try LaunchpadOpenService.revealInFinder(item) } catch { onError(error) }
    }

    private var emptySymbol: String {
        switch category {
        case .application: "square.grid.3x3"
        case .directory: "folder"
        case .website: "globe"
        }
    }
}

private struct LaunchpadGridMetrics {
    let size: CGSize
    let columns: Int
    let rows: Int
    let capacity: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat = 112
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat = 18
    let horizontalPadding: CGFloat = 28
    let edgePagingWidth: CGFloat = 32

    init(size: CGSize) {
        self.size = size
        let usableWidth = max(size.width - 56, 220)
        let targetCellWidth: CGFloat = 112
        let targetSpacing: CGFloat = 22
        columns = max(2, Int((usableWidth + targetSpacing) / (targetCellWidth + targetSpacing)))
        horizontalSpacing = max(12, min(32, (usableWidth - CGFloat(columns) * targetCellWidth) / CGFloat(max(columns - 1, 1))))
        cellWidth = targetCellWidth
        let gridHeight = max(size.height - 58, cellHeight)
        rows = max(1, Int((gridHeight + verticalSpacing) / (cellHeight + verticalSpacing)))
        capacity = max(columns * rows, 1)
    }

    var gridItems: [GridItem] {
        Array(
            repeating: GridItem(.fixed(cellWidth), spacing: horizontalSpacing, alignment: .top),
            count: columns
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Layout measurement cache used by drag hit-testing. It intentionally does not
/// publish mutations, because frame changes must not invalidate the layout that
/// produced them.
@MainActor
final class LaunchpadFrameStore {
    private var frames: [UUID: CGRect] = [:]

    subscript(id: UUID) -> CGRect? {
        get { frames[id] }
        set { frames[id] = newValue }
    }
}

struct LaunchpadDragSlotSnapshot {
    let pageIndex: Int
    let entryIDs: [UUID]
    let frames: [CGRect]
}

struct LaunchpadPageIndicator: View {
    let pageCount: Int
    let currentPage: Int
    let canGoBackward: Bool
    let canGoForward: Bool
    let selectPage: (Int) -> Void
    let moveBackward: () -> Void
    let moveForward: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: moveBackward) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(!canGoBackward)
            .keyboardShortcut(.leftArrow, modifiers: [.command])

            HStack(spacing: 7) {
                ForEach(0..<max(pageCount, 1), id: \.self) { page in
                    Button { selectPage(page) } label: {
                        Circle()
                            .fill(page == currentPage ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.25))
                            .frame(width: 7, height: 7)
                            .contentShape(Rectangle().inset(by: -5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("第 \(page + 1) 页")
                }
            }

            Button(action: moveForward) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)
            .keyboardShortcut(.rightArrow, modifiers: [.command])
        }
        .foregroundStyle(.secondary)
    }
}

/// 仅监听位于网格范围内的横向触控板/滚轮事件，不参与命中测试。
private struct ScrollWheelMonitor: NSViewRepresentable {
    let onTurn: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTurn: onTurn) }

    func makeNSView(context: Context) -> PassiveEventView {
        let view = PassiveEventView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: PassiveEventView, context: Context) {
        context.coordinator.onTurn = onTurn
    }

    static func dismantleNSView(_ nsView: PassiveEventView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        weak var view: NSView?
        var onTurn: (Int) -> Void
        private var monitor: Any?

        init(onTurn: @escaping (Int) -> Void) { self.onTurn = onTurn }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view, event.window == view.window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                let horizontal = event.scrollingDeltaX
                let shiftedVertical = event.modifierFlags.contains(.shift) ? event.scrollingDeltaY : 0
                let delta = abs(horizontal) >= abs(shiftedVertical) ? horizontal : shiftedVertical
                if abs(delta) > 8 { self.onTurn(delta > 0 ? -1 : 1) }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }

    final class PassiveEventView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
