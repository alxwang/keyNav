import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var ui: AppUIState
    @ObservedObject var perms: PermissionManager

    var body: some View {
        TabView(selection: $ui.selectedTab) {
            GeneralTab(store: store, ui: ui)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            AppearanceTab(store: store)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
            BehaviorTab(store: store)
                .tabItem { Label("Behavior", systemImage: "cursorarrow.click.2") }.tag(SettingsTab.behavior)
            ThumbnailsTab(store: store, perms: perms)
                .tabItem { Label("Thumbnails", systemImage: "rectangle.on.rectangle") }.tag(SettingsTab.thumbnails)
            ExclusionsTab(store: store)
                .tabItem { Label("Exclusions", systemImage: "nosign") }.tag(SettingsTab.exclusions)
            Form { PermissionRows(perms: perms) }.formStyle(.grouped)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(SettingsTab.permissions)
            AboutTab(store: store)
                .tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 640, height: 540)
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var ui: AppUIState
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @State private var alphabet = ""
    @State private var alphabetError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch KeyNav at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LaunchAtLogin.set(on); loginError = nil } catch { loginError = error.localizedDescription }
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                if LaunchAtLogin.status == .requiresApproval {
                    Text("Approve KeyNav in System Settings › General › Login Items.").font(.callout).foregroundStyle(.orange)
                }
                if let loginError { Text(loginError).font(.callout).foregroundStyle(.red) }
            }
            Section("Shortcuts") {
                HotkeyRecorder(title: "Show windows", hotkey: $store.settings.windowHotkey, ui: ui)
                HotkeyRecorder(title: "Label elements", hotkey: $store.settings.elementHotkey, ui: ui)
                ForEach(ui.hotkeyErrors, id: \.self) { Text($0).font(.callout).foregroundStyle(.red) }
                Toggle("Hold the middle mouse button to show windows", isOn: $store.settings.middleLongPress)
                Text("While labels are shown: type a label to pick it, ⌫ to undo a letter, Esc to cancel, hold Space to peek. In window mode, scroll to highlight a window and middle-click (or Return) to open it. In element mode Tab switches between important and all controls; hold ⇧ on the last letter for right-click, ⌘ for ⌘-click, ⌥ to keep labeling after the click.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Labels") {
                HStack {
                    TextField("Label characters", text: $alphabet)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(applyAlphabet)
                    Button("Apply", action: applyAlphabet)
                    Button("Reset") {
                        alphabet = LabelGenerator.defaultAlphabet
                        applyAlphabet()
                    }
                }
                Text("Characters earliest in the list get single-letter labels. Two-letter labels start with the last ones.")
                    .font(.callout).foregroundStyle(.secondary)
                if let alphabetError { Text(alphabetError).font(.callout).foregroundStyle(.red) }
            }
            Section {
                Toggle("Pause KeyNav", isOn: $store.settings.paused)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            alphabet = store.settings.alphabet
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    private func applyAlphabet() {
        let chars = alphabet.lowercased().filter { !$0.isWhitespace }
        guard Set(chars).count == chars.count else { alphabetError = "Characters must be unique."; return }
        guard chars.count >= 2 else { alphabetError = "Use at least 2 characters."; return }
        let typeable = Set(KeyLayout.currentMap().values)
        if let bad = chars.first(where: { !typeable.contains($0) }) {
            alphabetError = "“\(bad)” can't be typed with a single key on this keyboard layout."
            return
        }
        alphabetError = nil
        store.settings.alphabet = chars
        alphabet = chars
    }
}

struct HotkeyRecorder: View {
    let title: String
    @Binding var hotkey: Hotkey
    @ObservedObject var ui: AppUIState
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type shortcut… (Esc cancels)" : hotkey.displayString)
                    .frame(minWidth: 180)
                    .foregroundStyle(recording ? Color.accentColor : Color.primary)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        ui.isRecordingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = Hotkey.carbonModifiers(from: event.modifierFlags)
            if event.keyCode == KeyLayout.escape && mods == 0 { stop(); return nil }
            let needsModifier = mods & UInt32(0x0100 | 0x0800 | 0x1000) == 0 // cmd | option | control
            if needsModifier && !KeyLayout.functionKeyCodes.contains(event.keyCode) {
                NSSound.beep()
                return nil
            }
            hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { ui.isRecordingHotkey = false }
        recording = false
    }
}

// MARK: - Appearance

struct AppearanceTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Size") {
                LabeledContent("Window labels: \(Int(store.settings.windowFontSize)) pt") {
                    Slider(value: $store.settings.windowFontSize, in: 24...96, step: 2)
                }
                LabeledContent("Element labels: \(Int(store.settings.elementFontSize)) pt") {
                    Slider(value: $store.settings.elementFontSize, in: 10...32, step: 1)
                }
            }
            Section("Colors") {
                ColorPicker("Background", selection: color(\.badgeBackground))
                ColorPicker("Text", selection: color(\.badgeText))
                ColorPicker("Border", selection: color(\.badgeBorder))
                LabeledContent("Opacity: \(Int(store.settings.badgeOpacity * 100))%") {
                    Slider(value: $store.settings.badgeOpacity, in: 0.4...1, step: 0.05)
                }
            }
            Section("Preview") {
                HStack(spacing: 24) {
                    preview("A", size: store.settings.windowFontSize)
                    preview("JK", size: store.settings.elementFontSize)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .background(LinearGradient(colors: [.blue.opacity(0.4), .purple.opacity(0.4)], startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .formStyle(.grouped)
    }

    private func preview(_ label: String, size: Double) -> some View {
        Text(label)
            .font(.system(size: size, weight: .heavy, design: .monospaced))
            .foregroundStyle(Color(nsColor: store.settings.badgeText.nsColor))
            .padding(.horizontal, size * 0.35)
            .padding(.vertical, size * 0.12)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3)
                    .fill(Color(nsColor: store.settings.badgeBackground.nsColor))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.3)
                        .stroke(Color(nsColor: store.settings.badgeBorder.nsColor), lineWidth: 1))
            )
            .opacity(store.settings.badgeOpacity)
            .shadow(radius: 3)
    }

    private func color(_ kp: WritableKeyPath<Settings, RGBA>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: store.settings[keyPath: kp].nsColor) },
            set: { store.settings[keyPath: kp] = RGBA(NSColor($0)) }
        )
    }
}

// MARK: - Behavior

struct BehaviorTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Window switching") {
                Toggle("Move mouse cursor to the window's center", isOn: $store.settings.moveCursorToWindow)
                Toggle("Restore the window's last focused control", isOn: $store.settings.restoreLastFocus)
                Toggle("Otherwise focus the first text field", isOn: $store.settings.fallbackFirstTextField)
            }
            Section("Element labels: what counts as clickable") {
                ForEach(RoleCategory.allCases) { cat in
                    Toggle(cat.title, isOn: Binding(
                        get: { store.settings.roleCategories.contains(cat) },
                        set: { on in
                            if on { store.settings.roleCategories.insert(cat) } else { store.settings.roleCategories.remove(cat) }
                        }))
                }
            }
            Section("Element labels: options") {
                Toggle("Label only important controls first (Tab shows all)", isOn: $store.settings.smartElements)
                Toggle("Label disabled controls", isOn: $store.settings.showDisabled)
                Toggle("Outline labeled controls", isOn: $store.settings.showOutlines)
                Toggle("Leave cursor on the clicked control", isOn: $store.settings.leaveCursorOnClicked)
                Stepper("Maximum labels: \(store.settings.maxElements)", value: $store.settings.maxElements, in: 50...1000, step: 50)
            }
            Section("Chromium browsers") {
                TextField("Bundle IDs (comma separated)", text: Binding(
                    get: { store.settings.chromiumBundleIDs.joined(separator: ", ") },
                    set: { store.settings.chromiumBundleIDs = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ), axis: .vertical)
                .lineLimit(2...4)
                Toggle("Keep enhanced accessibility on after labeling", isOn: $store.settings.keepEnhancedUI)
                Text("Chromium browsers hide their controls from accessibility until asked. KeyNav turns it on while labeling and off 2 seconds later.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Thumbnails

struct ThumbnailsTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var perms: PermissionManager

    var body: some View {
        Form {
            Section("Thumbnail strip") {
                LabeledContent("Thumbnail height: \(Int(store.settings.thumbnailHeight)) pt") {
                    Slider(value: $store.settings.thumbnailHeight, in: 80...320, step: 10)
                }
                Toggle("Include minimized windows", isOn: $store.settings.includeMinimized)
                Toggle("Include windows of hidden apps", isOn: $store.settings.includeHidden)
            }
            Section("Snapshot cache") {
                Toggle("Remember snapshots of windows (memory only, never saved to disk)", isOn: $store.settings.snapshotCache)
                Stepper("Cache size: \(store.settings.cacheSize) windows", value: $store.settings.cacheSize, in: 20...300, step: 10)
                Button("Clear Cache") { NotificationCenter.default.post(name: .keyNavClearCache, object: nil) }
            }
            Section("Screen Recording") {
                if perms.screenRecording {
                    Label("Granted: live thumbnails enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Without Screen Recording permission the strip shows app icons instead of thumbnails.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Grant Screen Recording…") { perms.requestScreenRecording() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { perms.refresh() }
    }
}

// MARK: - Exclusions

struct ExclusionsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                if store.settings.exclusions.isEmpty {
                    Text("No excluded apps.").foregroundStyle(.secondary)
                }
                ForEach($store.settings.exclusions) { $ex in
                    HStack {
                        Text(ex.name)
                        Text(ex.bundleID).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Windows", isOn: $ex.windows).toggleStyle(.checkbox)
                        Toggle("Elements", isOn: $ex.elements).toggleStyle(.checkbox)
                        Button {
                            store.settings.exclusions.removeAll { $0.bundleID == ex.bundleID }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Apps whose windows or controls never get labels")
            }
            Section {
                HStack {
                    Menu("Add Running App") {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                                add(bundleID: app.bundleIdentifier, name: app.localizedName)
                            }
                        }
                    }
                    Button("Choose App…", action: chooseApp)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var runningApps: [NSRunningApplication] {
        let existing = Set(store.settings.exclusions.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !existing.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func add(bundleID: String?, name: String?) {
        guard let bundleID, !store.settings.exclusions.contains(where: { $0.bundleID == bundleID }) else { return }
        store.settings.exclusions.append(Exclusion(bundleID: bundleID, name: name ?? bundleID))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        add(bundleID: bundle.bundleIdentifier, name: name)
    }
}

// MARK: - About

struct AboutTab: View {
    @ObservedObject var store: SettingsStore
    @State private var confirmReset = false
    @State private var message: String?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("KeyNav", value: "Version \(version)")
            }
            Section("Settings") {
                HStack {
                    Button("Export…", action: exportSettings)
                    Button("Import…", action: importSettings)
                    Spacer()
                    Button("Reset All Settings", role: .destructive) { confirmReset = true }
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all KeyNav settings to defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.reset(); message = "Settings reset." }
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KeyNav Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = store.exportData() else { return }
        do { try data.write(to: url); message = "Exported." } catch { message = error.localizedDescription }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.importData(Data(contentsOf: url)); message = "Imported." } catch { message = "Import failed: \(error.localizedDescription)" }
    }
}
