//
//  LaunchpadLayoutEngine.swift
//  inchspace
//
//  不依赖 UI 的排列、分页和分组算法，便于单元测试覆盖。
//

import CoreGraphics
import Foundation

enum LaunchpadLayoutEngine {
    struct Location: Equatable {
        let pageIndex: Int
        let orderIndex: Int
    }

    /// 按数组插入语义移动元素，而不是交换两个位置。
    static func moving<T: Equatable>(_ values: [T], value: T, to proposedIndex: Int) -> [T] {
        guard let sourceIndex = values.firstIndex(of: value) else { return values }
        let destination = min(max(proposedIndex, 0), values.count - 1)
        guard sourceIndex != destination else { return values }

        var result = values
        result.remove(at: sourceIndex)
        result.insert(value, at: min(destination, result.count))
        return result
    }

    /// Resolves a pointer to a stable slot captured at drag start. The pointer
    /// must cross the perpendicular midpoint by `hysteresis` before changing
    /// away from the current slot, preventing boundary oscillation.
    static func proposedSlotIndex(
        at location: CGPoint,
        in slotFrames: [CGRect],
        currentIndex: Int?,
        hysteresis: CGFloat,
        commitFraction: CGFloat = 0.5
    ) -> Int? {
        guard !slotFrames.isEmpty else { return nil }
        let candidate = slotFrames.indices.min { lhs, rhs in
            squaredDistance(from: location, to: slotFrames[lhs].center)
                < squaredDistance(from: location, to: slotFrames[rhs].center)
        }
        guard let candidate else { return nil }
        guard let currentIndex,
              slotFrames.indices.contains(currentIndex),
              currentIndex != candidate else { return candidate }

        let currentCenter = slotFrames[currentIndex].center
        let candidateCenter = slotFrames[candidate].center
        let dx = candidateCenter.x - currentCenter.x
        let dy = candidateCenter.y - currentCenter.y
        let centerDistance = hypot(dx, dy)
        guard centerDistance > 0 else { return candidate }

        let pointerDX = location.x - currentCenter.x
        let pointerDY = location.y - currentCenter.y
        let projection = (pointerDX * dx + pointerDY * dy) / centerDistance
        let safeCommitFraction = min(max(commitFraction, 0.5), 1)
        let threshold = centerDistance * safeCommitFraction + max(hysteresis, 0)
        return projection >= threshold ? candidate : currentIndex
    }

    static func pages<T>(from values: [T], capacity: Int) -> [[T]] {
        let safeCapacity = max(capacity, 1)
        guard !values.isEmpty else { return [[]] }

        return stride(from: 0, to: values.count, by: safeCapacity).map { start in
            Array(values[start..<min(start + safeCapacity, values.count)])
        }
    }

    static func locations(count: Int, capacity: Int) -> [Location] {
        let safeCapacity = max(capacity, 1)
        return (0..<count).map { index in
            Location(pageIndex: index / safeCapacity, orderIndex: index % safeCapacity)
        }
    }

    /// 目标项目被分组替代；拖动项目从原位置移除，保留目标所在的视觉槽位。
    static func replacingWithGroup<T: Equatable>(
        _ values: [T],
        dragged: T,
        target: T,
        group: T
    ) -> [T] {
        guard dragged != target, values.contains(dragged), values.contains(target) else { return values }

        var result: [T] = []
        result.reserveCapacity(values.count - 1)
        for value in values {
            if value == dragged { continue }
            result.append(value == target ? group : value)
        }
        return result
    }

    static func removingDuplicates<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Returns the center activation area of the visible icon, excluding the
    /// label and the rest of the grid cell. `expansion` is used only after a
    /// folder target is ready to provide a small exit hysteresis.
    static func folderActivationFrame(
        in cellFrame: CGRect,
        iconSize: CGFloat,
        activationFraction: CGFloat,
        expansion: CGFloat = 0
    ) -> CGRect {
        let safeIconSize = min(max(iconSize, 0), min(cellFrame.width, cellFrame.height))
        let iconFrame = CGRect(
            x: cellFrame.midX - safeIconSize / 2,
            y: cellFrame.minY,
            width: safeIconSize,
            height: safeIconSize
        )
        let fraction = min(max(activationFraction, 0), 1)
        let inset = safeIconSize * (1 - fraction) / 2
        return iconFrame
            .insetBy(dx: inset, dy: inset)
            .insetBy(dx: -max(expansion, 0), dy: -max(expansion, 0))
    }

    private static func squaredDistance(from point: CGPoint, to center: CGPoint) -> CGFloat {
        let dx = center.x - point.x
        let dy = center.y - point.y
        return dx * dx + dy * dy
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
