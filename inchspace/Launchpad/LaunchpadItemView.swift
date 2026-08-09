//
//  LaunchpadItemView.swift
//  inchspace
//

import AppKit
import SwiftUI

struct LaunchpadEntryCell: View {
    let entry: LaunchEntry
    let groupItems: [LaunchItem]
    let availableGroups: [LaunchGroup]
    let isDragged: Bool
    let isGroupCandidate: Bool
    let isEditing: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMoveToGroup: (UUID) -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void
    let onEditWebsite: () -> Void
    let onDissolveGroup: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            iconContainer
                .launchpadJiggle(
                    id: entry.id,
                    isActive: isEditing && !isDragged,
                    reduceMotion: reduceMotion
                )

            Text(entry.displayName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isAvailable ? .primary : .secondary)
                .frame(maxWidth: 106)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(isDragged ? 0 : 1)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard !isEditing else { return .ignored }
            onOpen()
            return .handled
        }
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityLabel(entry.displayName)
        .accessibilityHint(entryHint)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.75), value: isGroupCandidate)
    }

    private var iconContainer: some View {
        icon
            .frame(width: LaunchpadInteractionConstants.rootIconSize, height: LaunchpadInteractionConstants.rootIconSize)
            .scaleEffect(
                isGroupCandidate ? LaunchpadInteractionConstants.folderReadyScale
                    : (isHovering && !isEditing ? 1.035 : 1)
            )
            .shadow(
                color: .black.opacity(isHovering || isGroupCandidate ? 0.18 : 0.08),
                radius: isHovering || isGroupCandidate ? 10 : 4,
                y: isHovering || isGroupCandidate ? 5 : 2
            )
            .overlay {
                if isGroupCandidate {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                        .padding(-4)
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.75), lineWidth: 2)
                                .padding(-4)
                        }
                }
            }
            .overlay(alignment: .topTrailing) {
                if isEditing && !isDragged, case .item = entry {
                    LaunchpadRemoveButton(
                        accessibilityLabel: removeAccessibilityLabel,
                        helpText: removeHelpText,
                        action: removeFromWorkbench
                    )
                    .offset(LaunchpadRemoveControlLayout.badgeOffset)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .zIndex(2)
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isEditing && !isDragged
            )
    }

    @ViewBuilder
    private var icon: some View {
        switch entry {
        case let .item(item):
            LaunchpadIconImage(item: item, size: 68)
                .saturation(item.isAvailable ? 1 : 0)
        case .group:
            LaunchpadGroupIcon(items: groupItems)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        switch entry {
        case let .item(item):
            Button("打开", systemImage: "arrow.up.forward.app", action: onOpen)
            Button("重命名…", systemImage: "pencil", action: onRename)

            if !availableGroups.isEmpty {
                Menu("移动到分组", systemImage: "folder.badge.plus") {
                    ForEach(availableGroups) { group in
                        Button(group.name) { onMoveToGroup(group.id) }
                    }
                }
            }

            switch item.target {
            case .application, .directory:
                Button("在 Finder 中显示", systemImage: "finder", action: onReveal)
            case .website:
                Button("编辑网站…", systemImage: "slider.horizontal.3", action: onEditWebsite)
            }

            Divider()
            Button("从工作台移除", systemImage: "trash", role: .destructive, action: onDelete)

        case .group:
            Button("打开分组", systemImage: "folder", action: onOpen)
            Button("重命名…", systemImage: "pencil", action: onRename)
            Divider()
            Button("解散分组", systemImage: "square.grid.2x2", action: onDissolveGroup)
        }
    }

    private var isAvailable: Bool {
        if case let .item(item) = entry { return item.isAvailable }
        return true
    }

    private var entryHint: String {
        if isEditing { return "拖动以重新排列，点按空白处或按 Esc 完成" }
        return switch entry {
        case .item: "按 Return 打开，长按进入编辑模式"
        case .group: "按 Return 打开分组，长按进入编辑模式"
        }
    }

    private var removeAccessibilityLabel: String {
        switch entry {
        case .item: "从工作台移除 \(entry.displayName)"
        case .group: "解散分组 \(entry.displayName)"
        }
    }

    private var removeHelpText: String {
        switch entry {
        case .item: "从工作台移除快捷入口"
        case .group: "解散分组并保留其中的快捷入口"
        }
    }

    private func removeFromWorkbench() {
        switch entry {
        case .item: onDelete()
        case .group: onDissolveGroup()
        }
    }
}

/// Stable per-ID values keep neighboring icons from moving in lockstep. The
/// transforms are render-only and never feed back into grid measurements.
struct LaunchpadJiggleProfile: Equatable {
    let angle: Double
    let horizontalOffset: CGFloat
    let cycleDuration: TimeInterval
    let phaseOffset: Double

    init(id: UUID) {
        let seed = id.uuidString.utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        angle = 1.15 + Double((seed >> 8) % 5) * 0.1
        horizontalOffset = 0.45 + CGFloat((seed >> 16) % 4) * 0.1
        cycleDuration = 0.30
        phaseOffset = Double((seed >> 32) % 360) * .pi / 180
    }
}

private struct LaunchpadJiggleModifier: ViewModifier {
    let profile: LaunchpadJiggleProfile
    let isActive: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let shouldAnimate = isActive && !reduceMotion
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: !shouldAnimate
            )
        ) { context in
            let phase = phase(at: context.date)
            let wave = shouldAnimate ? sin(phase) : 0
            content
                .rotationEffect(.degrees(wave * profile.angle))
                .offset(x: CGFloat(wave) * profile.horizontalOffset)
        }
    }

    private func phase(at date: Date) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate
        return elapsed / profile.cycleDuration * 2 * .pi + profile.phaseOffset
    }
}

extension View {
    func launchpadJiggle(id: UUID, isActive: Bool, reduceMotion: Bool) -> some View {
        modifier(
            LaunchpadJiggleModifier(
                profile: LaunchpadJiggleProfile(id: id),
                isActive: isActive,
                reduceMotion: reduceMotion
            )
        )
    }
}

enum LaunchpadRemoveControlLayout {
    static let visualSize: CGFloat = 18
    static let symbolSize: CGFloat = visualSize / 2
    static let hitSize: CGFloat = 40
    private static let cornerInset = visualSize * 0.45

    static var badgeOffset: CGSize {
        CGSize(
            width: hitSize / 2 - cornerInset,
            height: cornerInset - hitSize / 2
        )
    }

    static func hitFrame(in cellFrame: CGRect, iconSize: CGFloat) -> CGRect {
        CGRect(
            x: cellFrame.midX + iconSize / 2 - cornerInset - hitSize / 2,
            y: cellFrame.minY + cornerInset - hitSize / 2,
            width: hitSize,
            height: hitSize
        )
    }
}

struct LaunchpadRemoveButton: View {
    let accessibilityLabel: String
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.red)
                Image(systemName: "xmark")
                    .font(.system(size: LaunchpadRemoveControlLayout.symbolSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(
                width: LaunchpadRemoveControlLayout.visualSize,
                height: LaunchpadRemoveControlLayout.visualSize
            )
            .frame(
                width: LaunchpadRemoveControlLayout.hitSize,
                height: LaunchpadRemoveControlLayout.hitSize
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.05 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.2 : 0.14), radius: 2, y: 1)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }
}

struct LaunchpadIconImage: View {
    let item: LaunchItem
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.16)
                    .foregroundStyle(.secondary)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: size * 0.22))
            }
        }
        .frame(width: size, height: size)
        .task(id: item.iconCacheKey) {
            image = await LaunchpadIconProvider.shared.image(for: item)
        }
    }

    private var fallbackSymbol: String {
        switch item.category {
        case .application: "app.dashed"
        case .directory: "folder.fill"
        case .website: "globe"
        }
    }
}

struct LaunchpadGroupIcon: View {
    let items: [LaunchItem]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

            if items.isEmpty {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(16), spacing: 2), count: 3),
                    spacing: 2
                ) {
                    ForEach(0..<9, id: \.self) { index in
                        if items.indices.contains(index) {
                            LaunchpadIconImage(item: items[index], size: 16)
                        } else {
                            Color.clear
                                .frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .frame(width: 60, height: 60)
        .frame(width: 68, height: 68)
    }
}

struct LaunchpadFloatingPreview: View {
    let entry: LaunchEntry
    let groupItems: [LaunchItem]
    let isGroupCandidate: Bool

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                Group {
                    switch entry {
                    case let .item(item): LaunchpadIconImage(item: item, size: 72)
                    case .group: LaunchpadGroupIcon(items: groupItems)
                    }
                }
                .frame(width: 72, height: 72)
                Text(entry.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 110)
            }
            // The outer view is positioned by the dragged icon center. Moving
            // the inner icon down by 20pt aligns its 36pt center with the
            // 112pt container center used by SwiftUI's `position` modifier.
            .offset(y: 20)
        }
        .frame(
            width: 112,
            height: 112,
            alignment: .top
        )
        .scaleEffect(isGroupCandidate ? 1.08 : 1.04)
        .opacity(0.94)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 9)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

struct LaunchpadPositionedFloatingPreview: View {
    let entry: LaunchEntry
    let groupItems: [LaunchItem]
    let isGroupCandidate: Bool
    @ObservedObject var dragPosition: LaunchpadDragPosition

    var body: some View {
        if let location = dragPosition.location {
            LaunchpadFloatingPreview(
                entry: entry,
                groupItems: groupItems,
                isGroupCandidate: isGroupCandidate
            )
            .position(location)
        }
    }
}
