import AppKit
import SwiftUI
import SwiftTerm

struct TerminalCanvas: NSViewRepresentable {
    @ObservedObject var pane: TerminalPane
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.onActivate = { [weak pane] in pane?.focus() }
        pane.applyAppearance(systemIsDark: colorScheme == .dark)
        container.attach(pane.terminalView)
        container.updateSurfaceColor(pane.terminalView.nativeBackgroundColor)
        DispatchQueue.main.async {
            pane.startIfNeeded()
        }
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.onActivate = { [weak pane] in pane?.focus() }
        pane.applyAppearance(systemIsDark: colorScheme == .dark)
        container.attach(pane.terminalView)
        container.updateSurfaceColor(pane.terminalView.nativeBackgroundColor)
    }

    static func dismantleNSView(_ nsView: TerminalContainerView, coordinator: Void) {
        nsView.detachTerminal()
    }
}

enum TerminalContentLayout {
    static let insets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)

    static func contentFrame(in bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX + insets.left,
            y: bounds.minY + insets.bottom,
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - insets.top - insets.bottom)
        )
    }
}

@MainActor
final class TerminalContainerView: NSView {
    var onActivate: (() -> Void)?
    private final class MountRecord {
        weak var container: TerminalContainerView?
        let order: UInt64

        init(container: TerminalContainerView, order: UInt64) {
            self.container = container
            self.order = order
        }
    }

    private static var nextMountOrder: UInt64 = 0
    private static var mountRecords: [ObjectIdentifier: MountRecord] = [:]

    private let mountOrder: UInt64
    private weak var terminal: LocalProcessTerminalView?
    private var mouseMonitor: Any?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        Self.nextMountOrder &+= 1
        mountOrder = Self.nextMountOrder
        super.init(frame: frameRect)
        wantsLayer = true
        installMouseMonitor()
    }

    required init?(coder: NSCoder) {
        Self.nextMountOrder &+= 1
        mountOrder = Self.nextMountOrder
        super.init(coder: coder)
        wantsLayer = true
        installMouseMonitor()
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func attach(_ terminalView: LocalProcessTerminalView) {
        guard claimMount(for: terminalView) else { return }

        guard terminal !== terminalView || terminalView.superview !== self else {
            terminalView.frame = TerminalContentLayout.contentFrame(in: bounds)
            return
        }

        if let terminal {
            releaseMount(for: terminal)
            if terminal.superview === self {
                terminal.removeFromSuperview()
            }
        }
        terminal = nil

        // A split changes the SwiftUI view hierarchy and therefore creates a new
        // container for the existing primary terminal. Relinquish ownership from
        // the old container before moving the AppKit view. Otherwise the old
        // representable's later dismantle callback can remove the terminal from
        // its new (left-hand) pane and leave that pane blank.
        (terminalView.superview as? TerminalContainerView)?.relinquish(terminalView)
        terminalView.removeFromSuperview()
        terminalView.frame = TerminalContentLayout.contentFrame(in: bounds)
        terminalView.autoresizingMask = []
        addSubview(terminalView)
        terminal = terminalView
    }

    func updateSurfaceColor(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    func detachTerminal() {
        if let terminal {
            releaseMount(for: terminal)
            if terminal.superview === self {
                terminal.removeFromSuperview()
            }
        }
        terminal = nil
    }

    override func layout() {
        super.layout()
        if let terminal, ownsMount(for: terminal), terminal.superview === self {
            terminal.frame = TerminalContentLayout.contentFrame(in: bounds)
        }
    }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) { self.onActivate?() }
            return event
        }
    }

    private func relinquish(_ terminalView: LocalProcessTerminalView) {
        guard terminal === terminalView else { return }
        terminal = nil
    }

    private func claimMount(for terminalView: LocalProcessTerminalView) -> Bool {
        let key = ObjectIdentifier(terminalView)
        if let current = Self.mountRecords[key], let owner = current.container {
            if owner === self { return true }

            // SwiftUI can still send updateNSView to a container from the old
            // split hierarchy after the replacement hierarchy has mounted. A
            // newer container always wins, so a stale update cannot steal the
            // terminal back and later remove it during dismantling.
            guard current.order <= mountOrder else { return false }
            owner.relinquish(terminalView)
        }

        Self.mountRecords[key] = MountRecord(container: self, order: mountOrder)
        return true
    }

    private func releaseMount(for terminalView: LocalProcessTerminalView) {
        let key = ObjectIdentifier(terminalView)
        guard Self.mountRecords[key]?.container === self else { return }
        Self.mountRecords.removeValue(forKey: key)
    }

    private func ownsMount(for terminalView: LocalProcessTerminalView) -> Bool {
        Self.mountRecords[ObjectIdentifier(terminalView)]?.container === self
    }
}

/// Only the header's unoccupied background participates in window dragging.
/// Interactive SwiftUI controls remain above this view and receive their own events.
struct TerminalWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TerminalWindowDragRegionView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TerminalWindowDragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
