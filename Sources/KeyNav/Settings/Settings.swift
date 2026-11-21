import AppKit
import Carbon
import Combine

struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
}

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey | optionKey | controlKey | shiftKey).
    var modifiers: UInt32

    static let defaultWindow = Hotkey(keyCode: 49, modifiers: UInt32(optionKey)) // ⌥Space
    static let defaultElement = Hotkey(keyCode: 3, modifiers: UInt32(optionKey))  // ⌥F

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyLayout.displayName(keyCode: keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.maskCommand) { m |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { m |= UInt32(optionKey) }
        if flags.contains(.maskControl) { m |= UInt32(controlKey) }
        if flags.contains(.maskShift) { m |= UInt32(shiftKey) }
        return m
    }

    func matches(keyCode code: UInt16, flags: CGEventFlags) -> Bool {
        UInt32(code) == keyCode && Hotkey.carbonModifiers(from: flags) == modifiers
    }
}

enum RoleCategory: String, Codable, CaseIterable, Identifiable {
    case buttons, links, textInputs, toggles, tabs, rows, menus, pressable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buttons: "Buttons & pop-ups"
        case .links: "Links"
        case .textInputs: "Text inputs"
        case .toggles: "Checkboxes, radios & sliders"
        case .tabs: "Tabs"
        case .rows: "Table / list rows & cells"
        case .menus: "Menu items"
        case .pressable: "Text, images & groups with a press action"
        }
    }
}

struct Exclusion: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var windows: Bool = true
    var elements: Bool = true
    var id: String { bundleID }
}

struct Settings: Codable, Equatable {
    // General
    var windowHotkey = Hotkey.defaultWindow
    var elementHotkey = Hotkey.defaultElement
    var alphabet = LabelGenerator.defaultAlphabet
    var paused = false

    // Appearance
    var windowFontSize: Double = 48
    var elementFontSize: Double = 14
    var badgeBackground = RGBA(r: 1.0, g: 0.839, b: 0.039)  // #FFD60A
    var badgeText = RGBA(r: 0, g: 0, b: 0)
    var badgeBorder = RGBA(r: 0.2, g: 0.16, b: 0, a: 0.8)
    var badgeOpacity: Double = 1.0

    // Behavior
    var moveCursorToWindow = true
    var restoreLastFocus = true
    var fallbackFirstTextField = true
    var roleCategories: Set<RoleCategory> = Set(RoleCategory.allCases).subtracting([.pressable])
    var showDisabled = false
    var showOutlines = false
    var maxElements = 300
    var leaveCursorOnClicked = false
    var chromiumBundleIDs = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "org.chromium.Chromium", "com.operasoftware.Opera",
    ]
    var keepEnhancedUI = false

    // Thumbnails
    var thumbnailHeight: Double = 160
    var includeMinimized = true
    var includeHidden = true
    var snapshotCache = true
    var cacheSize = 100

    // Exclusions
    var exclusions: [Exclusion] = []

    func isExcluded(bundleID: String?, forElements: Bool) -> Bool {
        guard let bundleID else { return false }
        return exclusions.contains { $0.bundleID == bundleID && (forElements ? $0.elements : $0.windows) }
    }
}

// Tolerant decoding: missing keys fall back to defaults so new settings never wipe old ones.
extension Settings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? current
        }
        windowHotkey = v(.windowHotkey, windowHotkey)
        elementHotkey = v(.elementHotkey, elementHotkey)
        alphabet = v(.alphabet, alphabet)
        paused = v(.paused, paused)
        windowFontSize = v(.windowFontSize, windowFontSize)
        elementFontSize = v(.elementFontSize, elementFontSize)
        badgeBackground = v(.badgeBackground, badgeBackground)
        badgeText = v(.badgeText, badgeText)
        badgeBorder = v(.badgeBorder, badgeBorder)
        badgeOpacity = v(.badgeOpacity, badgeOpacity)
        moveCursorToWindow = v(.moveCursorToWindow, moveCursorToWindow)
        restoreLastFocus = v(.restoreLastFocus, restoreLastFocus)
        fallbackFirstTextField = v(.fallbackFirstTextField, fallbackFirstTextField)
        roleCategories = v(.roleCategories, roleCategories)
        showDisabled = v(.showDisabled, showDisabled)
        showOutlines = v(.showOutlines, showOutlines)
        maxElements = v(.maxElements, maxElements)
        leaveCursorOnClicked = v(.leaveCursorOnClicked, leaveCursorOnClicked)
        chromiumBundleIDs = v(.chromiumBundleIDs, chromiumBundleIDs)
        keepEnhancedUI = v(.keepEnhancedUI, keepEnhancedUI)
        thumbnailHeight = v(.thumbnailHeight, thumbnailHeight)
        includeMinimized = v(.includeMinimized, includeMinimized)
        includeHidden = v(.includeHidden, includeHidden)
        snapshotCache = v(.snapshotCache, snapshotCache)
        cacheSize = v(.cacheSize, cacheSize)
        exclusions = v(.exclusions, exclusions)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let key = "settings.v1"

    @Published var settings: Settings {
        didSet { if settings != oldValue { save() } }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = s
        } else {
            settings = Settings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func reset() { settings = Settings() }

    func exportData() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(settings)
    }

    func importData(_ data: Data) throws {
        settings = try JSONDecoder().decode(Settings.self, from: data)
    }
}

/// UI state shared between the settings window and the app delegate.
@MainActor
final class AppUIState: ObservableObject {
    static let shared = AppUIState()
    @Published var selectedTab: SettingsTab = .general
    @Published var isRecordingHotkey = false
    @Published var hotkeyErrors: [String] = []
}

enum SettingsTab: Hashable {
    case general, appearance, behavior, thumbnails, exclusions, permissions, about
}

extension Notification.Name {
    static let keyNavClearCache = Notification.Name("keyNavClearCache")
}
