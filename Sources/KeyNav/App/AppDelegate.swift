import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = SettingsStore.shared
    let ui = AppUIState.shared
    let perms = PermissionManager.shared
    lazy var coordinator = ModeCoordinator(store: store)

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var previousFrontPID: pid_t = 0
    private var tapRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        coordinator.router.onHotkey = { [weak self] action in
            guard let self else { return }
            switch action {
            case .windows: coordinator.toggleWindowMode()
            case .elements: coordinator.toggleElementMode()
            }
        }
        coordinator.onNeedsPermission = { [weak self] in self?.showOnboarding() }
        applyHotkeys()

        store.$settings
            .map { [$0.windowHotkey, $0.elementHotkey] }
            .combineLatest(store.$settings.map(\.paused), ui.$isRecordingHotkey)
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyHotkeys() } }
            .store(in: &cancellables)

        store.$settings.map(\.middleLongPress).removeDuplicates().sink { [weak self] on in
            self?.coordinator.router.middleLongPressEnabled = on
        }.store(in: &cancellables)

        store.$settings.map(\.snapshotCache).removeDuplicates().sink { [weak self] on in
            if !on { self?.coordinator.thumbnails.clear() }
        }.store(in: &cancellables)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appActivated(app) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coordinator.environmentChanged("screens")
                self?.coordinator.overlay.rebuildPanels()
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coordinator.environmentChanged()
                self?.coordinator.thumbnails.clear()
            }
        }
        NotificationCenter.default.addObserver(forName: .keyNavClearCache, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator.thumbnails.clear() }
        }

        if let front = NSWorkspace.shared.frontmostApplication { appActivated(front) }
        if !AXIsProcessTrusted() { showOnboarding() }
    }

    // MARK: Hotkeys

    private func applyHotkeys() {
        let s = store.settings
        let router = coordinator.router
        router.windowHotkey = s.windowHotkey
        router.elementHotkey = s.elementHotkey
        router.hotkeysEnabled = !s.paused && !ui.isRecordingHotkey
        ui.hotkeyErrors = s.windowHotkey == s.elementHotkey
            ? ["Both shortcuts are \(s.windowHotkey.displayString); pick different ones."] : []
        statusItem.button?.appearsDisabled = s.paused
        startTapWhenTrusted()
    }

    /// The shortcut tap needs Accessibility permission; keep retrying until it's granted.
    private func startTapWhenTrusted() {
        guard !coordinator.router.isRunning else { return }
        if coordinator.router.start() { tapRetryTimer?.invalidate(); tapRetryTimer = nil; return }
        guard tapRetryTimer == nil else { return }
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startTapWhenTrusted() }
        }
    }

    // MARK: App tracking

    private func appActivated(_ app: NSRunningApplication?) {
        guard let app else { return }
        let pid = app.processIdentifier
        guard pid != getpid() else { return }
        if previousFrontPID != 0, previousFrontPID != pid {
            coordinator.thumbnails.snapshotApp(pid: previousFrontPID)
        }
        previousFrontPID = pid
        coordinator.mru.removeAll { $0 == pid }
        coordinator.mru.insert(pid, at: 0)
        if coordinator.mru.count > 64 { coordinator.mru.removeLast() }
        coordinator.focusTracker.follow(pid: pid)
        coordinator.environmentChanged("activated \(app.bundleIdentifier ?? "?")")
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeyNav")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = store.settings

        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠︎ Accessibility permission needed…", #selector(openOnboarding)))
            menu.addItem(.separator())
        }
        if IsSecureEventInputEnabled() {
            let warn = NSMenuItem(title: "Secure input is on: shortcuts are blocked", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        menu.addItem(item("Show Windows    \(s.windowHotkey.displayString)", #selector(showWindows)))
        menu.addItem(item("Label Elements    \(s.elementHotkey.displayString)", #selector(labelElements)))
        menu.addItem(.separator())
        let pause = item("Pause KeyNav", #selector(togglePause))
        pause.state = s.paused ? .on : .off
        menu.addItem(pause)
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Permissions…", #selector(openPermissions)))
        menu.addItem(.separator())
        menu.addItem(item("Quit KeyNav", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    // Menu actions are deferred so the menu closes before the overlay appears.
    @objc private func showWindows() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.coordinator.toggleWindowMode() } }
    @objc private func labelElements() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.coordinator.toggleElementMode() } }
    @objc private func togglePause() { store.settings.paused.toggle() }
    @objc private func openSettings() { showSettings(tab: nil) }
    @objc private func openPermissions() { showSettings(tab: .permissions) }
    @objc private func openOnboarding() { showOnboarding() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Windows

    func showSettings(tab: SettingsTab?) {
        if let tab { ui.selectedTab = tab }
        if settingsWindow == nil {
            let view = SettingsView(store: store, ui: ui, perms: perms)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "KeyNav Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(perms: perms) { [weak self] in self?.onboardingWindow?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "KeyNav Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}
