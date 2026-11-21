import AppKit

enum HotkeyAction { case windows, elements }

/// One always-on session event tap does two jobs:
///  1. Detects the global shortcuts (Carbon's RegisterEventHotKey drops the first press on
///     recent macOS, so it is not used).
///  2. While an overlay is showing, swallows keystrokes and hands them to the coordinator,
///     so KeyNav never becomes the active app and the target window keeps focus.
@MainActor
final class KeyRouter {
    /// Called for each keyDown while a mode is active. Return true to swallow the event.
    var onKeyDown: ((_ keyCode: UInt16, _ flags: CGEventFlags) -> Bool)?
    /// Called (asynchronously, on main) when a shortcut is pressed while idle.
    var onHotkey: ((HotkeyAction) -> Void)?

    var windowHotkey: Hotkey?
    var elementHotkey: Hotkey?
    /// False while paused or while the settings window records a new shortcut.
    var hotkeysEnabled = true

    private var tap: CFMachPort?
    private(set) var isActive = false
    private var passedThroughKeys = Set<UInt16>()
    private var swallowedHotkeyKeys = Set<UInt16>()

    var isRunning: Bool { tap != nil }

    /// Creates and enables the tap. Needs Accessibility permission; returns false without it.
    @discardableResult
    func start() -> Bool {
        if tap == nil {
            let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: keyTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
            else { return false }
            tap = port
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
            log.notice("event tap started")
        }
        CGEvent.tapEnable(tap: tap!, enable: true)
        return true
    }

    /// Start capturing keys for an overlay.
    @discardableResult
    func enable() -> Bool {
        guard start() else { return false }
        passedThroughKeys.removeAll()
        isActive = true
        return true
    }

    /// Stop capturing keys (the tap keeps running for shortcuts).
    func disable() {
        isActive = false
    }

    private func matchHotkey(_ code: UInt16, _ flags: CGEventFlags) -> HotkeyAction? {
        guard hotkeysEnabled else { return nil }
        if windowHotkey?.matches(keyCode: code, flags: flags) == true { return .windows }
        if elementHotkey?.matches(keyCode: code, flags: flags) == true { return .elements }
        return nil
    }

    /// Returns true to swallow.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            if !isActive {
                guard let action = matchHotkey(code, event.flags) else { return false }
                swallowedHotkeyKeys.insert(code)
                if !isRepeat {
                    DispatchQueue.main.async { [weak self] in self?.onHotkey?(action) }
                }
                return true
            }

            if isRepeat { return !passedThroughKeys.contains(code) }
            let swallow = onKeyDown?(code, event.flags) ?? true
            if !swallow { passedThroughKeys.insert(code) }
            return swallow

        case .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if swallowedHotkeyKeys.remove(code) != nil { return true }
            guard isActive else { return false }
            if passedThroughKeys.remove(code) != nil { return false }
            return true

        default:
            return false
        }
    }
}

private let keyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let router = Unmanaged<KeyRouter>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { router.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
