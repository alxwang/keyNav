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
    /// Called for each keyUp while a mode is active (the event is swallowed unless its keyDown passed through).
    var onKeyUp: ((_ keyCode: UInt16) -> Void)?
    /// Called for each mouse-down while a mode is active (type, button number). Return true to swallow
    /// the click (and its mouse-up); it must be quick, so defer real work.
    var onMouseDown: ((_ type: CGEventType, _ button: Int64) -> Bool)?
    /// Called when the left button is released while a mode is active (never swallowed).
    var onLeftMouseUp: (() -> Void)?
    /// Called for scroll-wheel events while a mode is active with whole steps (positive = toward the
    /// user / down, negative = up; 0 for events that don't complete a step). Return true to swallow.
    var onScroll: ((_ steps: Int) -> Bool)?
    /// Called (asynchronously, on main) when a shortcut is pressed while idle.
    var onHotkey: ((HotkeyAction) -> Void)?

    var windowHotkey: Hotkey?
    var elementHotkey: Hotkey?
    /// False while paused or while the settings window records a new shortcut.
    var hotkeysEnabled = true

    /// Holding the middle button opens window mode; a quick click is replayed to the app.
    var middleLongPressEnabled = true
    static let longPressDelay: TimeInterval = 0.4
    private static let dragSlop: CGFloat = 6
    /// Marks events KeyNav posts itself so the tap lets them through.
    private static let syntheticTag: Int64 = 0x4B4E_4156  // "KNAV"
    private var pendingMiddle: (location: CGPoint, work: DispatchWorkItem)?

    private var tap: CFMachPort?
    private(set) var isActive = false
    private var passedThroughKeys = Set<UInt16>()
    private var swallowedHotkeyKeys = Set<UInt16>()
    private var swallowedMouseUps = Set<Int64>()
    private var scrollAccumulator: Double = 0
    /// Trackpad points per highlight step.
    private let pointsPerStep: Double = 40

    var isRunning: Bool { tap != nil }

    /// Creates and enables the tap. Needs Accessibility permission; returns false without it.
    @discardableResult
    func start() -> Bool {
        if tap == nil {
            let types: [CGEventType] = [
                .keyDown, .keyUp, .flagsChanged, .scrollWheel,
                .leftMouseDown, .rightMouseDown, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .leftMouseUp,
            ]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
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
        scrollAccumulator = 0
        isActive = true
        return true
    }

    /// Stop capturing keys (the tap keeps running for shortcuts).
    func disable() {
        isActive = false
    }

    private static func postMiddle(_ types: [CGEventType], at location: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in types {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                                  mouseButton: .center) else { continue }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
            e.post(tap: .cgSessionEventTap)
        }
    }

    /// One step per wheel notch; trackpads step every `pointsPerStep` points, ignoring momentum.
    private func scrollSteps(_ event: CGEvent) -> Int {
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
            let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            return lines > 0 ? -1 : lines < 0 ? 1 : 0
        }
        if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return 0 }
        if event.getIntegerValueField(.scrollWheelEventScrollPhase) == 1 { scrollAccumulator = 0 }  // began
        scrollAccumulator -= event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let steps = Int(scrollAccumulator / pointsPerStep)
        scrollAccumulator -= Double(steps) * pointsPerStep
        return steps
    }

    private func matchHotkey(_ code: UInt16, _ flags: CGEventFlags) -> HotkeyAction? {
        guard hotkeysEnabled else { return nil }
        if windowHotkey?.matches(keyCode: code, flags: flags) == true { return .windows }
        if elementHotkey?.matches(keyCode: code, flags: flags) == true { return .elements }
        return nil
    }

    /// Returns true to swallow.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return false }
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

        case .otherMouseDown where !isActive:
            guard middleLongPressEnabled, hotkeysEnabled,
                  event.getIntegerValueField(.mouseEventButtonNumber) == 2 else { return false }
            let location = event.location
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pendingMiddle != nil else { return }
                self.pendingMiddle = nil
                self.swallowedMouseUps.insert(2)   // the eventual release belongs to us
                self.onHotkey?(.windows)
            }
            pendingMiddle?.work.cancel()
            pendingMiddle = (location, work)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressDelay, execute: work)
            return true

        case .otherMouseDragged:
            guard let pending = pendingMiddle else { return false }
            let p = event.location
            guard hypot(p.x - pending.location.x, p.y - pending.location.y) > Self.dragSlop else { return true }
            // It's a middle-drag: hand the press back to the app and let the drag continue.
            pending.work.cancel()
            pendingMiddle = nil
            Self.postMiddle([.otherMouseDown], at: pending.location)
            return true

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard isActive else { return false }
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            let swallow = onMouseDown?(type, button) ?? false
            if swallow { swallowedMouseUps.insert(button) }
            return swallow

        case .leftMouseUp:
            if isActive { onLeftMouseUp?() }
            return false

        case .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if button == 2, let pending = pendingMiddle {
                // Released before the long-press delay: replay it as an ordinary middle click.
                pending.work.cancel()
                pendingMiddle = nil
                Self.postMiddle([.otherMouseDown, .otherMouseUp], at: pending.location)
                return true
            }
            return swallowedMouseUps.remove(button) != nil

        case .scrollWheel:
            guard isActive, let onScroll else { return false }
            return onScroll(scrollSteps(event))

        case .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if swallowedHotkeyKeys.remove(code) != nil { return true }
            guard isActive else { return false }
            if passedThroughKeys.remove(code) != nil { return false }
            onKeyUp?(code)
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
