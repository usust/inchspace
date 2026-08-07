//
//  LaunchpadDragCoordinator.swift
//  inchspace
//
//  拖动状态机只保存临时交互状态，不直接持久化模型。
//

import Combine
import CoreGraphics
import Foundation

enum LaunchpadInteractionConstants {
    static let longPressDuration: TimeInterval = 0.6
    static let longPressMovementTolerance: CGFloat = 6
    static let dragStartDistance: CGFloat = 6
    static let reorderHysteresis: CGFloat = 10
    static let reorderCommitFraction: CGFloat = 1
    static let folderHoverDelay: TimeInterval = 0.45
    static let folderMergeZoneScale: CGFloat = 0.68
    static let folderMovementTolerance: CGFloat = 10
    static let folderExitTolerance: CGFloat = 8
    static let folderReadyScale: CGFloat = 1.07
    static let rootIconSize: CGFloat = 68
}

@MainActor
final class LaunchpadDragCoordinator: ObservableObject {
    @Published private(set) var state = LaunchDragState.idle
    let dragPosition = LaunchpadDragPosition()

    private var longPressTask: Task<Void, Never>?
    private var groupHoverTask: Task<Void, Never>?
    private var edgePagingTask: Task<Void, Never>?
    private var pendingEdgeDirection: Int?
    private var lastEdgeTurnAt = Date.distantPast
    private var dragCenterOffset = CGSize.zero
    private let longPressDuration: TimeInterval
    private let folderHoverDelay: TimeInterval

    let edgeHoverDelay: UInt64 = 600_000_000
    let edgeCooldown: TimeInterval = 0.75

    init(
        longPressDuration: TimeInterval? = nil,
        folderHoverDelay: TimeInterval? = nil
    ) {
        self.longPressDuration = max(
            longPressDuration ?? LaunchpadInteractionConstants.longPressDuration,
            0
        )
        self.folderHoverDelay = max(
            folderHoverDelay ?? LaunchpadInteractionConstants.folderHoverDelay,
            0
        )
    }

    func beginPress(entryID: UUID, location: CGPoint) {
        guard state.phase == .idle else { return }
        longPressTask?.cancel()
        state = LaunchDragState(
            phase: .pressing,
            pressedEntryID: entryID,
            pressStartLocation: location,
            isLongPressEligible: true
        )

        longPressTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(self.longPressDuration))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.state.phase == .pressing,
                  self.state.pressedEntryID == entryID,
                  self.state.isLongPressEligible else { return }
            self.state.phase = .editing
            self.state.isLongPressEligible = false
            self.longPressTask = nil
        }
    }

    func updatePress(entryID: UUID, location: CGPoint) {
        guard state.phase == .pressing,
              state.pressedEntryID == entryID,
              state.isLongPressEligible,
              let start = state.pressStartLocation else { return }
        let distance = hypot(location.x - start.x, location.y - start.y)
        guard distance > LaunchpadInteractionConstants.longPressMovementTolerance else { return }
        longPressTask?.cancel()
        longPressTask = nil
        state.isLongPressEligible = false
    }

    /// Returns true only when the interaction remained a normal short click.
    func finishPress(entryID: UUID) -> Bool {
        longPressTask?.cancel()
        longPressTask = nil
        guard state.pressedEntryID == entryID else { return false }

        if state.phase == .pressing {
            let shouldOpen = state.isLongPressEligible
            state = .idle
            return shouldOpen
        }

        if state.phase == .editing {
            state.pressedEntryID = nil
            state.pressStartLocation = nil
            state.isLongPressEligible = false
        }
        return false
    }

    func cancelPress() {
        longPressTask?.cancel()
        longPressTask = nil
        switch state.phase {
        case .pressing:
            state = .idle
        case .editing:
            state.pressedEntryID = nil
            state.pressStartLocation = nil
            state.isLongPressEligible = false
        case .idle, .dragging, .hoveringForFolder, .folderReady, .edgePaging:
            break
        }
    }

    func beginDrag(
        entryID: UUID,
        pageIndex: Int,
        proposedIndex: Int,
        fromGroup: Bool = false,
        dragCenterOffset: CGSize = .zero
    ) {
        guard state.phase == .editing else { return }
        state = LaunchDragState(
            phase: .dragging,
            draggedEntryID: entryID,
            currentPageIndex: pageIndex,
            proposedIndex: proposedIndex,
            isDraggingFromGroup: fromGroup
        )
        self.dragCenterOffset = dragCenterOffset
        dragPosition.reset()
    }

    func dragCenter(for pointerLocation: CGPoint) -> CGPoint {
        CGPoint(
            x: pointerLocation.x + dragCenterOffset.width,
            y: pointerLocation.y + dragCenterOffset.height
        )
    }

    func updatePointer(_ location: CGPoint, pageIndex: Int) {
        guard state.isDragging else { return }
        dragPosition.update(location)
        if state.currentPageIndex != pageIndex {
            state.currentPageIndex = pageIndex
        }
    }

    func updateProposedIndex(_ proposedIndex: Int, pageIndex: Int) {
        guard state.isDragging,
              state.proposedIndex != proposedIndex || state.currentPageIndex != pageIndex else { return }
        state.proposedIndex = proposedIndex
        state.currentPageIndex = pageIndex
    }

    func hoverOver(candidateID: UUID?, location: CGPoint) {
        guard state.isDragging, candidateID != state.draggedEntryID else {
            clearGroupHover()
            return
        }
        guard let candidateID else {
            clearGroupHover()
            return
        }

        if state.folderMergeTargetID == candidateID,
           let anchor = state.folderHoverStartLocation {
            let movement = hypot(location.x - anchor.x, location.y - anchor.y)
            guard movement > LaunchpadInteractionConstants.folderMovementTolerance else { return }
        }

        beginGroupHover(candidateID: candidateID, location: location)
    }

    private func beginGroupHover(candidateID: UUID, location: CGPoint) {
        groupHoverTask?.cancel()
        state.folderMergeTargetID = candidateID
        state.folderHoverStartLocation = location
        state.phase = .hoveringForFolder

        groupHoverTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(self.folderHoverDelay))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.state.phase == .hoveringForFolder,
                  self.state.folderMergeTargetID == candidateID else { return }
            self.groupHoverTask = nil
            self.state.phase = .folderReady
        }
    }

    func clearGroupHover() {
        guard groupHoverTask != nil
            || state.folderMergeTargetID != nil
            || state.phase == .hoveringForFolder
            || state.phase == .folderReady else { return }
        groupHoverTask?.cancel()
        groupHoverTask = nil
        state.folderMergeTargetID = nil
        state.folderHoverStartLocation = nil
        if state.phase == .hoveringForFolder || state.phase == .folderReady {
            state.phase = .dragging
        }
    }

    func scheduleEdgeTurn(direction: Int?, action: @escaping (Int) -> Void) {
        guard state.isDragging else { return }
        guard direction != pendingEdgeDirection else { return }

        edgePagingTask?.cancel()
        pendingEdgeDirection = direction
        guard let direction else {
            if state.phase == .edgePaging { state.phase = .dragging }
            return
        }

        edgePagingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.edgeHoverDelay)
            guard !Task.isCancelled,
                  self.pendingEdgeDirection == direction,
                  Date().timeIntervalSince(self.lastEdgeTurnAt) >= self.edgeCooldown else { return }
            self.state.phase = .edgePaging
            self.lastEdgeTurnAt = Date()
            action(direction)
            self.pendingEdgeDirection = nil
            self.state.phase = .dragging
        }
    }

    var committedGroupTarget: UUID? {
        state.phase == .folderReady ? state.folderMergeTargetID : nil
    }

    func finishDrag() {
        groupHoverTask?.cancel()
        edgePagingTask?.cancel()
        groupHoverTask = nil
        edgePagingTask = nil
        pendingEdgeDirection = nil
        dragCenterOffset = .zero
        dragPosition.reset()
        state = LaunchDragState(phase: .editing)
    }

    func reset() {
        longPressTask?.cancel()
        groupHoverTask?.cancel()
        edgePagingTask?.cancel()
        longPressTask = nil
        groupHoverTask = nil
        edgePagingTask = nil
        pendingEdgeDirection = nil
        dragCenterOffset = .zero
        dragPosition.reset()
        state = .idle
    }
}

@MainActor
final class LaunchpadDragPosition: ObservableObject {
    @Published private(set) var location: CGPoint?

    func update(_ location: CGPoint) {
        self.location = location
    }

    func reset() {
        location = nil
    }
}
