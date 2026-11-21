import AppKit

@MainActor
final class ElementActivator {
    enum ClickKind { case primary, secondary, command }

    func activate(_ el: ElementInfo, kind: ClickKind, settings: Settings) {
        let point = el.frame.center
        switch kind {
        case .secondary:
            if el.ax.actionNames.contains("AXShowMenu"), el.ax.perform("AXShowMenu") == .success { return }
            click(at: point, button: .right, flags: [], settings: settings)
        case .command:
            click(at: point, button: .left, flags: .maskCommand, settings: settings)
        case .primary:
            if el.category == .textInputs {
                if el.ax.set("AXFocused", true) == .success { return }
                click(at: point, button: .left, flags: [], settings: settings)
                return
            }
            let actions = el.ax.actionNames
            for action in ["AXPress", "AXConfirm", "AXPick", "AXOpen"] where actions.contains(action) {
                if el.ax.perform(action) == .success { return }
            }
            click(at: point, button: .left, flags: [], settings: settings)
        }
    }

    private func click(at p: CGPoint, button: CGMouseButton, flags: CGEventFlags, settings: Settings) {
        let original = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        let (downType, upType): (CGEventType, CGEventType) =
            button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)

        CGWarpMouseCursorPosition(p)
        for type in [downType, upType] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
            else { continue }
            e.flags = flags
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
            usleep(15_000)
        }
        CGAssociateMouseAndMouseCursorPosition(1)

        if !settings.leaveCursorOnClicked, let original {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                CGWarpMouseCursorPosition(original)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }
}
