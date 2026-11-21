import AppKit

struct ElementInfo {
    let ax: AXUIElement
    let role: String
    let subrole: String?
    /// Visible portion of the element, global CG coordinates.
    let frame: CGRect
    let category: RoleCategory
}

struct ElementScanResult {
    var elements: [ElementInfo]
    var windowFrame: CGRect
    var truncated: Int
}

/// Walks the focused window's AX tree and collects actionable elements.
final class ElementScanner: @unchecked Sendable {
    static let maxDepth = 40
    static let maxNodes = 5000
    static let timeBudget: TimeInterval = 0.6

    private static let roleMap: [String: RoleCategory] = [
        "AXButton": .buttons, "AXPopUpButton": .buttons, "AXMenuButton": .buttons,
        "AXDisclosureTriangle": .buttons, "AXIncrementor": .buttons,
        "AXLink": .links,
        "AXTextField": .textInputs, "AXTextArea": .textInputs, "AXComboBox": .textInputs,
        "AXCheckBox": .toggles, "AXRadioButton": .toggles, "AXSlider": .toggles,
        "AXTab": .tabs,
        "AXRow": .rows, "AXCell": .rows,
        "AXMenuItem": .menus,
    ]
    private static let pressableRoles: Set<String> = ["AXStaticText", "AXImage", "AXGroup"]
    private static let skipRoles: Set<String> = ["AXScrollBar", "AXMenuBar", "AXValueIndicator"]
    private static let clipRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXSplitGroup"]

    private let lock = NSLock()
    private var manualAXPids = Set<pid_t>()
    private var enhancedPids = Set<pid_t>()

    static func rank(_ c: RoleCategory) -> Int {
        switch c {
        case .textInputs: 6
        case .buttons, .links, .toggles, .tabs, .menus: 5
        case .rows: 3
        case .pressable: 2
        }
    }

    /// Asks Electron / Chromium apps to expose their accessibility tree.
    /// Returns true if the tree was just switched on (callers should give it a moment).
    private func enableAccessibility(app: AXUIElement, pid: pid_t, bundleID: String?, settings: Settings) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var justEnabled = false
        if !manualAXPids.contains(pid) {
            manualAXPids.insert(pid)
            if app.set("AXManualAccessibility", true) == .success { justEnabled = true }
        }
        if let bundleID, settings.chromiumBundleIDs.contains(bundleID), !enhancedPids.contains(pid) {
            enhancedPids.insert(pid)
            app.set("AXEnhancedUserInterface", true)
            justEnabled = true
        }
        return justEnabled
    }

    /// AXEnhancedUserInterface interferes with window animations / window managers; turn it off after use.
    func resetEnhancedUI(pid: pid_t) {
        lock.lock()
        let had = enhancedPids.remove(pid) != nil
        lock.unlock()
        if had { AX.app(pid).set("AXEnhancedUserInterface", false) }
    }

    /// Blocking: call off the main thread.
    func scan(pid: pid_t, bundleID: String?, settings: Settings, screens: [CGRect]) -> ElementScanResult? {
        let app = AX.app(pid)
        if enableAccessibility(app: app, pid: pid, bundleID: bundleID, settings: settings) {
            Thread.sleep(forTimeInterval: 0.3)
        }
        guard let window = app.element("AXFocusedWindow") ?? app.element("AXMainWindow"),
              let windowFrame = window.frame else { return nil }

        let attrs = ["AXRole", "AXSubrole", "AXPosition", "AXSize", "AXEnabled", "AXChildren"]
        let deadline = Date().addingTimeInterval(Self.timeBudget)

        struct Node { let el: AXUIElement; let depth: Int; let clip: CGRect }
        var stack = [Node(el: window, depth: 0, clip: windowFrame)]
        var found: [ElementInfo] = []
        var nodes = 0

        while let n = stack.popLast() {
            nodes += 1
            if nodes > Self.maxNodes || Date() > deadline { break }

            let v = n.el.multi(attrs)
            guard let role = v[0] as? String else { continue }
            if Self.skipRoles.contains(role) { continue }
            let subrole = v[1] as? String
            var frame: CGRect?
            if let p = AX.point(v[2]), let s = AX.size(v[3]), s.width > 0, s.height > 0 {
                frame = CGRect(origin: p, size: s)
            }

            var clip = n.clip
            if let f = frame {
                if n.depth > 0 && !f.intersects(clip) { continue }
                if Self.clipRoles.contains(role) { clip = clip.intersection(f) }
            }

            if n.depth > 0, let f = frame,
               let category = category(role: role, subrole: subrole, element: n.el, settings: settings),
               settings.showDisabled || (v[4] as? Bool) != false {
                let visible = f.intersection(clip)
                if !visible.isNull, visible.width >= 6, visible.height >= 6,
                   screens.contains(where: { $0.contains(visible.center) }) {
                    found.append(ElementInfo(ax: n.el, role: role, subrole: subrole, frame: visible, category: category))
                }
            }

            guard n.depth < Self.maxDepth else { continue }
            var kids = (v[5] as? [AXUIElement]) ?? []
            if role == "AXTable" || role == "AXOutline" {
                let rows = n.el.elements("AXVisibleRows")
                if !rows.isEmpty {
                    kids = rows + kids.filter { let r = $0.role; return r != "AXRow" && r != "AXColumn" }
                }
            }
            for k in kids.reversed() { stack.append(Node(el: k, depth: n.depth + 1, clip: clip)) }
        }

        var elements = Self.dedupe(found)
        var truncated = 0
        if elements.count > settings.maxElements {
            let c = windowFrame.center
            elements.sort { hypot($0.frame.midX - c.x, $0.frame.midY - c.y) < hypot($1.frame.midX - c.x, $1.frame.midY - c.y) }
            truncated = elements.count - settings.maxElements
            elements = Array(elements.prefix(settings.maxElements))
        }
        return ElementScanResult(elements: Self.readingOrder(elements), windowFrame: windowFrame, truncated: truncated)
    }

    private func category(role: String, subrole: String?, element: AXUIElement, settings: Settings) -> RoleCategory? {
        if role == "AXRadioButton", subrole == "AXTabButton" {
            return settings.roleCategories.contains(.tabs) ? .tabs : nil
        }
        if let c = Self.roleMap[role] {
            return settings.roleCategories.contains(c) ? c : nil
        }
        if settings.roleCategories.contains(.pressable), Self.pressableRoles.contains(role),
           element.actionNames.contains("AXPress") {
            return .pressable
        }
        return nil
    }

    /// Collapses wrapper/child pairs that cover the same area, keeping the stronger role
    /// (ties go to the later, i.e. deeper, element).
    static func dedupe(_ items: [ElementInfo]) -> [ElementInfo] {
        var keep = [Bool](repeating: true, count: items.count)
        for i in items.indices where keep[i] {
            for j in (i + 1)..<max(i + 1, items.count) where keep[j] {
                guard items[i].frame.iou(items[j].frame) >= 0.85 else { continue }
                if rank(items[i].category) > rank(items[j].category) { keep[j] = false } else { keep[i] = false; break }
            }
        }
        return items.indices.filter { keep[$0] }.map { items[$0] }
    }

    /// Top-to-bottom bands, left-to-right within a band.
    static func readingOrder(_ items: [ElementInfo]) -> [ElementInfo] {
        let sorted = items.sorted { $0.frame.minY < $1.frame.minY }
        var bands: [[ElementInfo]] = []
        var bandTop: CGFloat = -.infinity
        var tolerance: CGFloat = 0
        for item in sorted {
            if item.frame.minY > bandTop + tolerance || bands.isEmpty {
                bands.append([item])
                bandTop = item.frame.minY
                tolerance = max(4, item.frame.height / 2)
            } else {
                bands[bands.count - 1].append(item)
            }
        }
        return bands.flatMap { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }
}
