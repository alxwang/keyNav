import AppKit

/// Remembers the last focused element of each window of the frontmost app.
/// Only one AXObserver exists at a time (re-attached on every app activation).
@MainActor
final class FocusTracker {
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private(set) var lastFocused: [CGWindowID: AXUIElement] = [:]

    func follow(pid: pid_t) {
        guard pid != observedPID, pid != getpid(), AX.isTrusted else { return }
        stop()
        var obs: AXObserver?
        guard AXObserverCreate(pid, focusCallback, &obs) == .success, let obs else { return }
        let app = AX.app(pid)
        AXObserverAddNotification(obs, app, "AXFocusedUIElementChanged" as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPID = pid
        if let current = app.element("AXFocusedUIElement") { record(current) }
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = 0
    }

    fileprivate func record(_ element: AXUIElement) {
        guard element.role != "AXWindow",
              let window = element.element("AXWindow"), let id = window.windowID else { return }
        if lastFocused.count > 300 { lastFocused.removeAll() }
        lastFocused[id] = element
    }
}

private let focusCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { tracker.record(element) }
}

@MainActor
final class FocusResolver {
    private let tracker: FocusTracker
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    init(tracker: FocusTracker) { self.tracker = tracker }

    func resolve(window: AXUIElement, windowID: CGWindowID, app: AXUIElement, settings: Settings) async {
        try? await Task.sleep(nanoseconds: 60_000_000)

        // 1. The app restored a sensible focus itself.
        if let current = app.element("AXFocusedUIElement"), current.role != "AXWindow",
           window.isSame(current.element("AXWindow")) {
            return
        }
        // 2. Restore what was focused last time in this window.
        if settings.restoreLastFocus, windowID != 0, let last = tracker.lastFocused[windowID],
           window.isSame(last.element("AXWindow")), last.set("AXFocused", true) == .success {
            return
        }
        // 3. First text input in reading order.
        if settings.fallbackFirstTextField, let field = Self.firstTextInput(in: window) {
            field.set("AXFocused", true)
        }
    }

    static func firstTextInput(in window: AXUIElement) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(0.15)
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var head = 0
        var found: [(AXUIElement, CGRect)] = []
        while head < queue.count, head < 2000, Date() < deadline, found.count < 30 {
            let (el, depth) = queue[head]; head += 1
            let v = el.multi(["AXRole", "AXPosition", "AXSize", "AXEnabled", "AXChildren"])
            if let role = v[0] as? String, textRoles.contains(role), (v[3] as? Bool) != false,
               let p = AX.point(v[1]), let s = AX.size(v[2]), s.width > 4, s.height > 4 {
                found.append((el, CGRect(origin: p, size: s)))
                continue
            }
            if depth < 25, let kids = v[4] as? [AXUIElement] {
                queue.append(contentsOf: kids.map { ($0, depth + 1) })
            }
        }
        return found.min { a, b in
            abs(a.1.minY - b.1.minY) > 8 ? a.1.minY < b.1.minY : a.1.minX < b.1.minX
        }?.0
    }
}

@MainActor
final class WindowActivator {
    private let focus: FocusResolver

    init(focus: FocusResolver) { self.focus = focus }

    func activate(_ w: WindowInfo, settings: Settings) async {
        guard let app = NSRunningApplication(processIdentifier: w.pid) else { return }
        if app.isHidden { app.unhide() }

        guard let win = w.ax else {
            app.activate()
            return
        }
        win.setTimeout(0.5)

        if win.bool("AXMinimized") == true {
            win.set("AXMinimized", false)
            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                if win.bool("AXMinimized") == false { break }
            }
        }

        let axApp = AX.app(w.pid, timeout: 0.5)
        raise(win, app: axApp)
        try? await Task.sleep(nanoseconds: 80_000_000)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != w.pid {
            // macOS 14+ cooperative activation can refuse; retry through NSRunningApplication.
            app.activate()
            raise(win, app: axApp)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        if settings.restoreLastFocus || settings.fallbackFirstTextField {
            await focus.resolve(window: win, windowID: w.id, app: axApp, settings: settings)
        }

        if settings.moveCursorToWindow, let f = win.frame ?? Optional(w.frame) {
            CGWarpMouseCursorPosition(f.center)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    private func raise(_ win: AXUIElement, app: AXUIElement) {
        win.perform("AXRaise")
        win.set("AXMain", true)
        app.set("AXFrontmost", true)
    }
}
