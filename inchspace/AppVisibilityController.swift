//
//  AppVisibilityController.swift
//  inchspace
//
//  主窗口、Dock、菜单栏与全局快捷键的唯一协调入口。
//

import AppKit
import Combine
import Foundation
import SwiftUI

enum AppVisibilityState: Equatable {
    case visible
    case hidden
    case background
}

enum WindowPositionPreference: String, Codable, CaseIterable, Identifiable {
    case lastPosition
    case screenCenter
    case nearPointer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastPosition: "上一次位置"
        case .screenCenter: "屏幕中央"
        case .nearPointer: "当前鼠标位置附近"
        }
    }
}

/// 可以安全地在多台 Mac 之间共享的用户偏好。
/// Dock、菜单栏和快捷键属于设备运行方式，刻意不包含在这里。
struct SyncedAppPreferences: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    var hidesAfterOpen: Bool
    var windowPosition: WindowPositionPreference

    private enum CodingKeys: String, CodingKey {
        case version
        case hidesAfterOpen
        case windowPosition
    }

    init(
        version: Int = Self.currentVersion,
        hidesAfterOpen: Bool,
        windowPosition: WindowPositionPreference
    ) {
        self.version = version
        self.hidesAfterOpen = hidesAfterOpen
        self.windowPosition = windowPosition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        hidesAfterOpen = try container.decodeIfPresent(Bool.self, forKey: .hidesAfterOpen) ?? true
        windowPosition = try container.decodeIfPresent(
            WindowPositionPreference.self,
            forKey: .windowPosition
        ) ?? .nearPointer
    }
}

@MainActor
final class AppWindowPreferences: ObservableObject {
    private enum Key {
        static let hidesAfterOpen = "window.hidesAfterOpen"
        static let showsDockIcon = "window.showsDockIcon"
        static let showsMenuBarIcon = "window.showsMenuBarIcon"
        static let position = "window.position"
        static let shortcut = "window.globalShortcut"
        static let syncedModifiedAt = "window.syncedPreferencesModifiedAt"
    }

    @Published private(set) var hidesAfterOpen: Bool
    @Published private(set) var showsDockIcon: Bool
    @Published private(set) var showsMenuBarIcon: Bool
    @Published private(set) var position: WindowPositionPreference
    @Published private(set) var shortcut: AppGlobalShortcut
    @Published private(set) var syncedModifiedAt: Date?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hidesAfterOpen: true,
            Key.showsDockIcon: true,
            Key.showsMenuBarIcon: true,
            Key.position: WindowPositionPreference.nearPointer.rawValue,
        ])
        hidesAfterOpen = defaults.bool(forKey: Key.hidesAfterOpen)
        showsDockIcon = defaults.bool(forKey: Key.showsDockIcon)
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
        position = WindowPositionPreference(rawValue: defaults.string(forKey: Key.position) ?? "")
            ?? .nearPointer
        if let data = defaults.data(forKey: Key.shortcut),
           let stored = try? JSONDecoder().decode(AppGlobalShortcut.self, from: data) {
            shortcut = stored
        } else {
            shortcut = .defaultShortcut
        }
        syncedModifiedAt = defaults.object(forKey: Key.syncedModifiedAt) as? Date
    }

    var syncedPreferences: SyncedAppPreferences {
        SyncedAppPreferences(
            hidesAfterOpen: hidesAfterOpen,
            windowPosition: position
        )
    }

    func setHidesAfterOpen(_ value: Bool) {
        guard hidesAfterOpen != value else { return }
        hidesAfterOpen = value
        defaults.set(value, forKey: Key.hidesAfterOpen)
        markSyncedPreferencesModified()
    }

    func setShowsDockIcon(_ value: Bool) {
        showsDockIcon = value
        defaults.set(value, forKey: Key.showsDockIcon)
    }

    func setShowsMenuBarIcon(_ value: Bool) {
        showsMenuBarIcon = value
        defaults.set(value, forKey: Key.showsMenuBarIcon)
    }

    func setPosition(_ value: WindowPositionPreference) {
        guard position != value else { return }
        position = value
        defaults.set(value.rawValue, forKey: Key.position)
        markSyncedPreferencesModified()
    }

    func setShortcut(_ value: AppGlobalShortcut) {
        shortcut = value
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Key.shortcut)
        }
    }

    /// 接收云端偏好时不改变当前设备的 Dock、菜单栏和快捷键配置。
    func applySyncedPreferences(_ value: SyncedAppPreferences, modifiedAt: Date) {
        hidesAfterOpen = value.hidesAfterOpen
        position = value.windowPosition
        defaults.set(value.hidesAfterOpen, forKey: Key.hidesAfterOpen)
        defaults.set(value.windowPosition.rawValue, forKey: Key.position)
        syncedModifiedAt = modifiedAt
        defaults.set(modifiedAt, forKey: Key.syncedModifiedAt)
    }

    private func markSyncedPreferencesModified() {
        let now = Date()
        syncedModifiedAt = now
        defaults.set(now, forKey: Key.syncedModifiedAt)
    }
}

extension Notification.Name {
    static let inchspaceOpenSettings = Notification.Name("inchspace.openSettings")
}

@MainActor
final class AppVisibilityController: NSObject, ObservableObject {
    static let shared = AppVisibilityController()

    @Published private(set) var state: AppVisibilityState = .background
    @Published private(set) var shortcutRegistrationError: String?

    let preferences: AppWindowPreferences

    private let hotKeyManager = GlobalHotKeyManager()
    private weak var mainWindow: NSWindow?
    private var openMainWindow: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var observedWindowNumber: Int?
    private var hasStarted = false

    private override init() {
        preferences = AppWindowPreferences()
        super.init()
        hotKeyManager.action = { [weak self] in
            self?.toggleFromGlobalShortcut()
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        observeApplicationVisibility()
        applyActivationPolicy()
        updateStatusItem()
        registerStoredShortcut()
        refreshState()
    }

    func registerMainWindow(_ window: NSWindow) {
        let isNewWindow = mainWindow !== window
        if let previousWindow = mainWindow, previousWindow !== window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: previousWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didMiniaturizeNotification,
                object: previousWindow
            )
        }
        mainWindow = window
        window.identifier = NSUserInterfaceItemIdentifier("inchspace.mainWindow")
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("inchspace.mainWindow")

        if observedWindowNumber != window.windowNumber {
            observedWindowNumber = window.windowNumber
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(windowBecameUnavailable),
                name: NSWindow.willCloseNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowBecameUnavailable),
                name: NSWindow.didMiniaturizeNotification,
                object: window
            )
        }

        if isNewWindow, !window.isVisible {
            applyInitialPosition(to: window)
        }
        refreshState()
    }

    func registerWindowOpeningAction(_ action: @escaping () -> Void) {
        openMainWindow = action
    }

    func showMainWindow() {
        start()
        let wasVisible = mainWindow?.isVisible == true && !NSApp.isHidden
        NSApp.unhide(nil)

        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            show(window, animated: !wasVisible)
        } else {
            openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
        state = .visible
    }

    func hide() {
        guard !NSApp.isHidden else { return }
        NSApp.hide(nil)
        state = .hidden
    }

    func hideAfterSuccessfulOpen(_ destination: LaunchpadOpenService.OpenedDestination) {
        guard preferences.hidesAfterOpen else { return }
        hide()
        // Workspace 的打开回调代表系统已接受请求；短暂让出事件循环后再次
        // 激活目标，避免正在隐藏的工具窗口抢回前台。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            destination.activate()
        }
    }

    func openSettings() {
        showMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .inchspaceOpenSettings, object: nil)
        }
    }

    func setHidesAfterOpen(_ value: Bool) {
        preferences.setHidesAfterOpen(value)
    }

    func setShowsDockIcon(_ value: Bool) {
        preferences.setShowsDockIcon(value)
        applyActivationPolicy()
    }

    func setShowsMenuBarIcon(_ value: Bool) {
        preferences.setShowsMenuBarIcon(value)
        updateStatusItem()
    }

    func setWindowPosition(_ value: WindowPositionPreference) {
        preferences.setPosition(value)
    }

    @discardableResult
    func setGlobalShortcut(_ shortcut: AppGlobalShortcut) -> Bool {
        guard hotKeyManager.register(shortcut) else {
            shortcutRegistrationError = "该快捷键可能已被系统或其他应用占用"
            return false
        }
        preferences.setShortcut(shortcut)
        shortcutRegistrationError = nil
        return true
    }

    func beginShortcutRecording() {
        // 防止录入当前组合时同时触发全局唤起动作。
        hotKeyManager.suspend()
    }

    func endShortcutRecording() {
        registerStoredShortcut()
    }

    private func toggleFromGlobalShortcut() {
        if mainWindow?.isVisible == true, NSApp.isActive, !NSApp.isHidden {
            hide()
        } else {
            showMainWindow()
        }
    }

    private func registerStoredShortcut() {
        if hotKeyManager.register(preferences.shortcut) {
            shortcutRegistrationError = nil
        } else {
            if !preferences.showsDockIcon && !preferences.showsMenuBarIcon {
                preferences.setShowsMenuBarIcon(true)
                updateStatusItem()
                shortcutRegistrationError = "快捷键注册失败，已自动显示菜单栏图标"
            } else {
                shortcutRegistrationError = "该快捷键可能已被系统或其他应用占用"
            }
        }
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = preferences.showsDockIcon ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }

    private func updateStatusItem() {
        if preferences.showsMenuBarIcon {
            if statusItem == nil { statusItem = makeStatusItem() }
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let menuBarImage = NSImage(named: "MenuBarIcon")
            menuBarImage?.isTemplate = true
            menuBarImage?.size = NSSize(width: 18, height: 18)
            button.image = menuBarImage
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.toolTip = applicationName
        }

        let menu = NSMenu()
        let title = NSMenuItem(title: applicationName, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开窗口", action: #selector(statusOpenWindow), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(statusOpenSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(statusQuit), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        return item
    }

    @objc private func statusOpenWindow() {
        showMainWindow()
    }

    @objc private func statusOpenSettings() {
        openSettings()
    }

    @objc private func statusQuit() {
        NSApp.terminate(nil)
    }

    private var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "inchspace"
    }

    private func observeApplicationVisibility() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationDidHide),
            name: NSApplication.didHideNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidUnhide),
            name: NSApplication.didUnhideNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func windowBecameUnavailable(_ notification: Notification) {
        state = .background
    }

    @objc private func applicationDidHide(_ notification: Notification) {
        state = .hidden
    }

    @objc private func applicationDidUnhide(_ notification: Notification) {
        refreshState()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        refreshState()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        if !NSApp.isHidden { state = .background }
    }

    private func refreshState() {
        if NSApp.isHidden {
            state = .hidden
        } else if NSApp.isActive,
                  mainWindow?.isVisible == true,
                  mainWindow?.isMiniaturized == false {
            state = .visible
        } else {
            state = .background
        }
    }

    private func show(_ window: NSWindow, animated: Bool) {
        guard animated else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// Position is an initialization policy, not persistent layout state. After
    /// this one call, the Window Server owns the user's dragged frame.
    private func applyInitialPosition(to window: NSWindow) {
        switch preferences.position {
        case .lastPosition:
            _ = window.setFrameUsingName("inchspace.mainWindow")
        case .screenCenter:
            window.center()
        case .nearPointer:
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
                ?? NSScreen.main
            guard let visibleFrame = screen?.visibleFrame else { return }
            let insetFrame = visibleFrame.insetBy(dx: 12, dy: 12)
            let size = window.frame.size
            let proposed = CGPoint(
                x: pointer.x - size.width / 2,
                y: pointer.y - size.height / 2
            )
            let maximumX = max(insetFrame.minX, insetFrame.maxX - size.width)
            let maximumY = max(insetFrame.minY, insetFrame.maxY - size.height)
            window.setFrameOrigin(CGPoint(
                x: min(max(proposed.x, insetFrame.minX), maximumX),
                y: min(max(proposed.y, insetFrame.minY), maximumY)
            ))
        }
    }
}

/// SwiftUI 的 WindowGroup 不暴露 NSWindow；用一个不可见视图只做一次桥接。
struct MainWindowBridge: NSViewRepresentable {
    @ObservedObject var controller: AppVisibilityController

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                controller.registerMainWindow(window)
            }
        }
    }
}

/// 保存 SwiftUI 的 openWindow 动作，使关闭主窗口后仍可通过热键重新创建窗口。
struct WindowOpeningBridge: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: AppVisibilityController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                controller.registerWindowOpeningAction {
                    openWindow(id: "main")
                }
            }
    }
}

final class InchspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppVisibilityController.shared.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppVisibilityController.shared.showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
