import AppKit
import Carbon

/// Maps virtual key codes to the characters they produce without modifiers in the user's
/// ASCII-capable keyboard layout. Matching labels by key code keeps held modifiers (⌥ for
/// chaining, ⇧ for right-click) from changing which label is typed, and keeps working when
/// a non-Latin input method (e.g. Pinyin) is active.
enum KeyLayout {
    static let escape: UInt16 = 53
    static let backspace: UInt16 = 51

    private static let ansiFallback: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
        39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
        50: "`",
    ]

    private static let specialNames: [UInt32: String] = [
        49: "Space", 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]

    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113]

    static func currentMap() -> [UInt16: Character] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return ansiFallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return ansiFallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var map: [UInt16: Character] = [:]
        for code in ansiFallback.keys {
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
            )
            guard status == noErr, length > 0,
                  let s = String(utf16CodeUnits: chars, count: length).lowercased().first,
                  !s.isWhitespace
            else { continue }
            map[code] = s
        }
        return map.isEmpty ? ansiFallback : map
    }

    static func displayName(keyCode: UInt32) -> String {
        if let name = specialNames[keyCode] { return name }
        if let c = currentMap()[UInt16(keyCode)] { return String(c).uppercased() }
        return "Key\(keyCode)"
    }
}
