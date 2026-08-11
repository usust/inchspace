//
//  GlobalHotKey.swift
//  inchspace
//
//  Carbon 的 RegisterEventHotKey 不需要辅助功能权限，适合注册全局唤起键。
//

import AppKit
import Carbon.HIToolbox
import Foundation

struct AppGlobalShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = AppGlobalShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey),
        keyLabel: "Space"
    )

    var displayName: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols.isEmpty ? keyLabel : "\(symbols) \(keyLabel)"
    }

    static func from(_ event: NSEvent) -> AppGlobalShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        // 全局注册裸字母或数字会妨碍正常输入，因此至少要求一个修饰键。
        guard carbonModifiers != 0,
              let keyLabel = Self.label(for: event) else { return nil }
        return AppGlobalShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers,
            keyLabel: keyLabel
        )
    }

    private static func label(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"
        case kVK_UpArrow: return "↑"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            guard let characters = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !characters.isEmpty else { return nil }
            return characters.uppercased()
        }
    }
}

/// 对 Carbon 热键注册做一个很薄的封装，并在新组合注册失败时恢复旧组合。
final class GlobalHotKeyManager {
    private static let signature: OSType = 0x494E4348 // "INCH"
    private static let identifier: UInt32 = 1

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private(set) var registeredShortcut: AppGlobalShortcut?
    var action: (() -> Void)?

    init() {}

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == GlobalHotKeyManager.signature,
                      hotKeyID.id == GlobalHotKeyManager.identifier else { return status }

                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async { manager.action?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        return status == noErr
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(_ shortcut: AppGlobalShortcut) -> Bool {
        if registeredShortcut == shortcut, hotKey != nil { return true }

        let previous = registeredShortcut
        unregister()
        let status = registerWithoutFallback(shortcut)
        guard status != noErr else { return true }

        if let previous {
            _ = registerWithoutFallback(previous)
        }
        return false
    }

    func suspend() {
        unregister()
    }

    private func registerWithoutFallback(_ shortcut: AppGlobalShortcut) -> OSStatus {
        guard installEventHandlerIfNeeded() else { return OSStatus(eventInternalErr) }
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr {
            hotKey = reference
            registeredShortcut = shortcut
        }
        return status
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredShortcut = nil
    }
}
