import AppKit

enum WindowState { case onScreen, minimized, hidden }

struct WindowInfo {
    /// CGWindowID, or 0 when it couldn't be determined.
    let id: CGWindowID
    let pid: pid_t
    let ax: AXUIElement?
    let title: String
    let appName: String
    let bundleID: String?
    let frame: CGRect
    let state: WindowState
    /// Front-to-back index in the on-screen window list (onScreen windows only).
    let zIndex: Int?
}

struct CGWin {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let frame: CGRect
    let owner: String
    let title: String?
}

struct WindowSnapshot {
    var windows: [WindowInfo]
    /// All on-screen windows, front to back (used for occlusion tests).
    var stack: [CGWin]
    var focusedID: CGWindowID?
}

enum WindowCatalog {
    private static let ignoredOwners: Set<String> = ["Dock", "Window Server", "WindowServer", "SystemUIServer", "Control Center", "Notification Center"]

    /// On-screen windows of the current Space, front to back.
    static func onScreenStack() -> [CGWin] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let selfPID = getpid()
        return list.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID,
                  let layer = d[kCGWindowLayer as String] as? Int,
                  let bounds = d[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.01
            else { return nil }
            return CGWin(id: id, pid: pid, layer: layer, frame: frame,
                         owner: d[kCGWindowOwnerName as String] as? String ?? "",
                         title: d[kCGWindowName as String] as? String)
        }
    }

    /// Windows that can cover other windows (normal + floating layers, not system chrome).
    static func occluders(from stack: [CGWin]) -> [CGWin] {
        stack.filter { (0..<20).contains($0.layer) && !ignoredOwners.contains($0.owner) }
    }

    /// Builds the full catalog. Blocking AX IPC: call off the main thread.
    static func snapshot(settings: Settings) -> WindowSnapshot {
        let stack = onScreenStack()
        var zIndex: [CGWindowID: Int] = [:]
        for (i, w) in stack.enumerated() { zIndex[w.id] = i }
        let layer0 = stack.filter { $0.layer == 0 }

        let selfPID = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID
                && !settings.isExcluded(bundleID: $0.bundleIdentifier, forElements: false)
        }

        var results = [[WindowInfo]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let r = windows(for: apps[i], layer0: layer0, zIndex: zIndex, settings: settings)
            lock.lock(); results[i] = r; lock.unlock()
        }

        var focusedID: CGWindowID?
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != selfPID {
            focusedID = AX.app(front.processIdentifier).element("AXFocusedWindow")?.windowID
        }
        return WindowSnapshot(windows: results.flatMap { $0 }, stack: stack, focusedID: focusedID)
    }

    private static func windows(for app: NSRunningApplication, layer0: [CGWin],
                                zIndex: [CGWindowID: Int], settings: Settings) -> [WindowInfo] {
        let pid = app.processIdentifier
        let axApp = AX.app(pid)
        let hidden = app.isHidden
        let appName = app.localizedName ?? "App"
        let ownOnScreen = layer0.filter { $0.pid == pid }

        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &raw)
        guard err == .success, let axWindows = raw as? [AXUIElement] else {
            // App not responding to AX: fall back to CG data for its visible windows.
            guard err == .cannotComplete else { return [] }
            return ownOnScreen.filter { $0.frame.width >= 100 && $0.frame.height >= 100 }.map {
                WindowInfo(id: $0.id, pid: pid, ax: nil, title: $0.title ?? appName, appName: appName,
                           bundleID: app.bundleIdentifier, frame: $0.frame, state: .onScreen, zIndex: zIndex[$0.id])
            }
        }

        var out: [WindowInfo] = []
        for w in axWindows {
            let v = w.multi(["AXRole", "AXSubrole", "AXTitle", "AXPosition", "AXSize", "AXMinimized"])
            guard (v[0] as? String) == "AXWindow",
                  let subrole = v[1] as? String, subrole == "AXStandardWindow" || subrole == "AXDialog",
                  let pos = AX.point(v[3]), let size = AX.size(v[4]),
                  size.width >= 40, size.height >= 40
            else { continue }
            let frame = CGRect(origin: pos, size: size)
            let minimized = (v[5] as? Bool) ?? false
            let id = w.windowID ?? ownOnScreen.first { $0.frame.equalTo(frame) }?.id ?? 0

            let state: WindowState
            if minimized {
                guard settings.includeMinimized else { continue }
                state = .minimized
            } else if hidden {
                guard settings.includeHidden else { continue }
                state = .hidden
            } else if id != 0, zIndex[id] != nil {
                state = .onScreen
            } else {
                continue // lives on another Space
            }
            let title = (v[2] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? appName
            out.append(WindowInfo(id: id, pid: pid, ax: w, title: title, appName: appName,
                                  bundleID: app.bundleIdentifier, frame: frame, state: state,
                                  zIndex: state == .onScreen ? zIndex[id] : nil))
        }
        return out
    }
}
