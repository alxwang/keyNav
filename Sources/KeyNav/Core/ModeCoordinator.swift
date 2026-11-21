import AppKit

/// State machine for window mode / element mode.
@MainActor
final class ModeCoordinator {
    enum Mode { case idle, windows, elements }
    private enum Target { case window(WindowInfo), element(ElementInfo) }

    private(set) var mode: Mode = .idle
    private var targets: [String: Target] = [:]
    private var labels: [String] = []
    private var prefix = ""
    private var keyMap: [UInt16: Character] = [:]
    private var token = 0
    private var lastToggle = Date.distantPast
    private var elementPID: pid_t = 0
    private var elementResult: ElementScanResult?
    private var showingAllElements = false
    /// Window mode: label highlighted by the scroll wheel, and frames of windows labeled in place.
    private var highlighted: String?
    private var windowFrames: [String: CGRect] = [:]
    /// After a macOS screenshot shortcut, clicks (area selection, the ⌘⇧5 toolbar) don't close the labels.
    private var screenshotGraceUntil = Date.distantPast
    private static let screenshotGrace: TimeInterval = 20
    /// Key codes of 3, 4, 5, 6: ⌘⇧3 / ⌘⇧4 / ⌘⇧5 / ⌘⇧6 (with or without ⌃).
    private static let screenshotKeys: Set<UInt16> = [20, 21, 23, 22]

    let overlay = OverlayController()
    let router = KeyRouter()
    let store: SettingsStore
    let thumbnails: ThumbnailService
    let focusTracker = FocusTracker()
    private let windowActivator: WindowActivator
    private let elementActivator = ElementActivator()
    private let scanner = ElementScanner()

    /// Most-recently-activated app PIDs, newest first (maintained by AppDelegate).
    var mru: [pid_t] = []
    /// Called when Accessibility permission is missing.
    var onNeedsPermission: (() -> Void)?

    init(store: SettingsStore) {
        self.store = store
        thumbnails = ThumbnailService(store: store)
        windowActivator = WindowActivator(focus: FocusResolver(tracker: focusTracker))
        router.onKeyDown = { [weak self] code, flags in self?.handleKey(code: code, flags: flags) ?? false }
        router.onKeyUp = { [weak self] code in
            if code == KeyLayout.space { self?.overlay.setPeek(false) }
        }
        router.onMouseDown = { [weak self] type, button in self?.handleMouseDown(type: type, button: button) ?? false }
        router.onScroll = { [weak self] steps in self?.handleScroll(steps) ?? false }
    }

    // MARK: Entry points

    func toggleWindowMode() {
        log.notice("toggleWindowMode mode=\(String(describing: self.mode), privacy: .public)")
        guard debounce() else { log.notice("debounced"); return }
        mode == .windows ? cancel() : startWindowMode()
    }

    func toggleElementMode() {
        log.notice("toggleElementMode mode=\(String(describing: self.mode), privacy: .public)")
        guard debounce() else { log.notice("debounced"); return }
        mode == .elements ? cancel() : startElementMode()
    }

    private func debounce() -> Bool {
        // Guards against accidental double presses.
        guard Date().timeIntervalSince(lastToggle) > 0.15 else { return false }
        lastToggle = Date()
        return true
    }

    private func begin(_ newMode: Mode) -> Int? {
        guard !store.settings.paused else { return nil }
        guard AX.isTrusted else { onNeedsPermission?(); return nil }
        cancel()
        guard router.enable() else { onNeedsPermission?(); return nil }
        mode = newMode
        keyMap = KeyLayout.currentMap()
        prefix = ""
        token += 1
        return token
    }

    func startWindowMode() {
        guard let t = begin(.windows) else { return }
        let settings = store.settings
        Task {
            let snap = await Task.detached(priority: .userInitiated) { WindowCatalog.snapshot(settings: settings) }.value
            guard t == token, mode == .windows else { return }
            presentWindows(snap, settings: settings)
        }
    }

    func startElementMode() {
        guard let front = NSWorkspace.shared.frontmostApplication else { log.notice("no frontmost app"); return }
        log.notice("startElementMode front=\(front.bundleIdentifier ?? "?", privacy: .public)")
        if front.processIdentifier == getpid() {
            overlay.flashHUD("Element labels aren't available for KeyNav itself")
            return
        }
        if store.settings.isExcluded(bundleID: front.bundleIdentifier, forElements: true) {
            overlay.flashHUD("\(front.localizedName ?? "This app") is excluded")
            return
        }
        guard let t = begin(.elements) else { return }
        let settings = store.settings
        let pid = front.processIdentifier
        let bundleID = front.bundleIdentifier
        let screens = ScreenGeometry.allScreensCG
        let scanner = self.scanner
        elementPID = pid
        Task {
            let started = Date()
            let result = await Task.detached(priority: .userInitiated) {
                scanner.scan(pid: pid, bundleID: bundleID, settings: settings, screens: screens)
            }.value
            log.notice("scan done in \(Date().timeIntervalSince(started), privacy: .public)s elements=\(result?.elements.count ?? -1, privacy: .public) token=\(t == self.token, privacy: .public) mode=\(String(describing: self.mode), privacy: .public)")
            guard t == token, mode == .elements else { return }
            presentElements(result, settings: settings)
        }
    }

    func cancel(_ reason: String = "", file: String = #function) {
        if mode != .idle { log.notice("cancel from \(file, privacy: .public) \(reason, privacy: .public)") }
        let wasElements = mode == .elements
        mode = .idle
        token += 1
        router.disable()
        overlay.hide()
        targets = [:]
        labels = []
        prefix = ""
        elementResult = nil
        screenshotGraceUntil = .distantPast
        highlighted = nil
        windowFrames = [:]
        if wasElements { scheduleEnhancedUIReset() }
    }

    /// Cancel if the user switches apps or screens change mid-mode.
    func environmentChanged(_ reason: String = "") {
        if mode != .idle { cancel("environmentChanged \(reason)") }
    }

    // MARK: Presentation

    private func presentWindows(_ snap: WindowSnapshot, settings: Settings) {
        let screens = ScreenGeometry.allScreensCG
        let occluders = WindowCatalog.occluders(from: snap.stack)
        var zOf: [CGWindowID: Int] = [:]
        for (i, w) in snap.stack.enumerated() { zOf[w.id] = i }

        var visible: [(WindowInfo, CGPoint)] = []
        var strip: [WindowInfo] = []
        for w in snap.windows {
            if w.state == .onScreen, let z = w.zIndex {
                let above = occluders.filter { (zOf[$0.id] ?? .max) < z }.map(\.frame)
                if let p = VisibilityAnalyzer.labelPoint(frame: w.frame, occluders: above, screens: screens) {
                    visible.append((w, p))
                    continue
                }
            }
            strip.append(w)
        }
        visible.sort { ($0.0.zIndex ?? .max) < ($1.0.zIndex ?? .max) }
        let mruIndex = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        strip.sort {
            let a = mruIndex[$0.pid] ?? .max, b = mruIndex[$1.pid] ?? .max
            return a != b ? a < b : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        // Priority: visible (front to back), then strip; the focused window goes last.
        var ordered: [(WindowInfo, CGPoint?)] = visible.map { ($0.0, $0.1) } + strip.map { ($0, nil) }
        if let fid = snap.focusedID, let i = ordered.firstIndex(where: { $0.0.id == fid }) {
            ordered.append(ordered.remove(at: i))
        }
        guard !ordered.isEmpty else {
            cancel()
            overlay.flashHUD("No windows")
            return
        }

        labels = LabelGenerator.labels(count: ordered.count, alphabet: settings.alphabet)
        var windowBadges: [(String, CGPoint)] = []
        var cards: [StripCard] = []
        for (label, item) in zip(labels, ordered) {
            let (w, point) = item
            targets[label] = .window(w)
            if let point {
                windowBadges.append((label, point))
                windowFrames[label] = w.frame
            } else {
                let icon = NSRunningApplication(processIdentifier: w.pid)?.icon
                let aspect = w.frame.height > 0 ? w.frame.width / w.frame.height : 1.5
                cards.append(StripCard(label: label, windowID: w.id, title: w.title, icon: icon,
                                       image: thumbnails.cached(w.id), aspect: aspect))
            }
        }
        overlay.show(windowBadges: windowBadges, elementBadges: [], cards: cards, style: OverlayStyle(settings))

        let stripWindows = strip
        let t = token
        thumbnails.captureLive(stripWindows) { [weak self] id, image in
            guard let self, t == self.token else { return }
            self.overlay.updateImage(windowID: id, image: image)
        }
    }

    private func presentElements(_ result: ElementScanResult?, settings: Settings) {
        guard let result, !result.elements.isEmpty else {
            cancel()
            overlay.flashHUD("No clickable elements")
            return
        }
        elementResult = result
        let hasSmaller = settings.smartElements && !result.important.isEmpty && result.important.count < result.elements.count
        showingAllElements = !hasSmaller
        showElementLabels(settings: settings, announce: true)
    }

    private func showElementLabels(settings: Settings, announce: Bool) {
        guard let result = elementResult else { return }
        let items = showingAllElements ? result.elements : result.important
        targets = [:]
        prefix = ""
        labels = LabelGenerator.labels(count: items.count, alphabet: settings.alphabet)
        var badges: [(String, CGRect)] = []
        for (label, el) in zip(labels, items) {
            targets[label] = .element(el)
            badges.append((label, el.frame))
        }
        overlay.show(windowBadges: [], elementBadges: badges, cards: [], style: OverlayStyle(settings))
        if !showingAllElements {
            if announce { overlay.flashHUD("\(items.count) of \(result.elements.count) · Tab shows all") }
        } else if !announce {
            overlay.flashHUD("All \(items.count) elements")
        }
        if showingAllElements, result.truncated > 0 { overlay.flashHUD("+\(result.truncated) more elements not labeled") }
    }

    /// Tab in element mode: switch between important and all labels.
    private func toggleElementDetail() {
        guard let result = elementResult, result.important.count < result.elements.count, !result.important.isEmpty else { return }
        showingAllElements.toggle()
        showElementLabels(settings: store.settings, announce: false)
    }

    // MARK: Mouse

    /// Window mode: middle button activates the highlighted window. Any other click cancels and
    /// goes through to the app.
    private func handleMouseDown(type: CGEventType, button: Int64) -> Bool {
        if mode == .windows, type == .otherMouseDown, button == 2 {
            if let label = highlighted, let target = targets[label] {
                DispatchQueue.main.async { [weak self] in self?.fire(target, flags: []) }
            }
            return true
        }
        if Date() < screenshotGraceUntil { return false }   // selecting a screenshot area
        DispatchQueue.main.async { [weak self] in self?.cancel("mouse click") }
        return false
    }

    /// Window mode: the wheel moves the highlight through the (matching) labels, looping.
    private func handleScroll(_ steps: Int) -> Bool {
        guard mode == .windows else { return false }
        if steps != 0 { moveHighlight(by: steps) }
        return true
    }

    private func moveHighlight(by steps: Int) {
        let candidates = labels.filter { $0.hasPrefix(prefix) }
        guard !candidates.isEmpty else { return }
        let n = candidates.count
        let next: Int
        if let h = highlighted, let i = candidates.firstIndex(of: h) {
            next = ((i + steps) % n + n) % n
        } else {
            next = steps > 0 ? (steps - 1) % n : ((n + steps) % n + n) % n
        }
        highlighted = candidates[next]
        overlay.setHighlight(candidates[next], frame: windowFrames[candidates[next]])
    }

    // MARK: Keys

    /// Returns true to swallow the key.
    private func handleKey(code: UInt16, flags: CGEventFlags) -> Bool {
        guard mode != .idle else { return false }
        // macOS screenshot shortcuts go through and leave the labels up, so they can be captured.
        if flags.contains([.maskCommand, .maskShift]), Self.screenshotKeys.contains(code) {
            screenshotGraceUntil = Date().addingTimeInterval(Self.screenshotGrace)
            return false
        }
        if code == KeyLayout.escape {
            if Date() < screenshotGraceUntil {
                screenshotGraceUntil = .distantPast   // first Esc cancels the screenshot, the next one the labels
                return false
            }
            cancel()
            return true
        }
        if mode == .windows, code == KeyLayout.returnKey || code == KeyLayout.keypadEnter,
           let label = highlighted, let target = targets[label] {
            fire(target, flags: [])
            return true
        }
        if code == KeyLayout.backspace {
            if !prefix.isEmpty { prefix.removeLast(); overlay.update(prefix: prefix) }
            return true
        }

        let candidate = keyMap[code].map { prefix + String($0) }
        let isLabelKey = candidate.map { c in labels.contains { $0.hasPrefix(c) } } ?? false

        if !isLabelKey {
            let s = store.settings
            let mods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            if code == KeyLayout.space, flags.intersection(mods).isEmpty {
                overlay.setPeek(true)   // hold Space to see under the labels
                return true
            }
            if code == KeyLayout.tab, mode == .elements, flags.intersection(mods).isEmpty {
                toggleElementDetail()
                return true
            }
            if s.windowHotkey.matches(keyCode: code, flags: flags) { toggleWindowMode(); return true }
            if s.elementHotkey.matches(keyCode: code, flags: flags) { toggleElementMode(); return true }
            if flags.contains(.maskCommand) && mode == .windows {
                cancel()          // let ⌘-shortcuts (e.g. ⌘Tab) through
                return false
            }
            return true           // ignore stray keys
        }

        prefix = candidate!
        if let target = targets[prefix] {
            fire(target, flags: flags)
        } else {
            overlay.update(prefix: prefix)
        }
        return true
    }

    private func fire(_ target: Target, flags: CGEventFlags) {
        let settings = store.settings
        switch target {
        case .window(let w):
            cancel()
            Task { await windowActivator.activate(w, settings: settings) }
        case .element(let el):
            let kind: ElementActivator.ClickKind =
                flags.contains(.maskShift) ? .secondary : flags.contains(.maskCommand) ? .command : .primary
            let chain = flags.contains(.maskAlternate)
            cancel()
            elementActivator.activate(el, kind: kind, settings: settings)
            if chain {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, self.mode == .idle,
                          CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) else { return }
                    self.lastToggle = .distantPast
                    self.startElementMode()
                }
            }
        }
    }

    private func scheduleEnhancedUIReset() {
        guard !store.settings.keepEnhancedUI else { return }
        let pid = elementPID
        let scanner = self.scanner
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.mode != .elements else { return }
            DispatchQueue.global(qos: .utility).async { scanner.resetEnhancedUI(pid: pid) }
        }
    }
}
