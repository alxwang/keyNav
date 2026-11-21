import AppKit
import ApplicationServices

/// Thin typed helpers over the Accessibility C API.
extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &v) == .success ? v : nil
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }
    func bool(_ attribute: String) -> Bool? { value(attribute) as? Bool }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        (value(attribute) as? [AXUIElement]) ?? []
    }

    var role: String? { string("AXRole") }
    var subrole: String? { string("AXSubrole") }

    var frame: CGRect? {
        guard let p = AX.point(value("AXPosition")), let s = AX.size(value("AXSize")) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    func set(_ attribute: String, _ v: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, v)
    }

    @discardableResult
    func set(_ attribute: String, _ flag: Bool) -> AXError {
        set(attribute, (flag ? kCFBooleanTrue : kCFBooleanFalse)!)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success, let names else { return [] }
        return (names as? [String]) ?? []
    }

    var pid: pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(self, &p) == .success ? p : nil
    }

    /// The CGWindowID for a window element (private but widely used API; nil if unavailable).
    var windowID: CGWindowID? {
        guard let fn = AX.getWindowFn else { return nil }
        var id: CGWindowID = 0
        return fn(self, &id) == .success && id != 0 ? id : nil
    }

    /// Batch-reads attributes in one IPC round trip. Missing values come back as nil.
    func multi(_ attributes: [String]) -> [CFTypeRef?] {
        var result: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            self, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result)
        guard err == .success, let arr = result as? [AnyObject], arr.count == attributes.count else {
            return Array(repeating: nil, count: attributes.count)
        }
        return arr.map { v -> CFTypeRef? in
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
    }

    func setTimeout(_ seconds: Float) { AXUIElementSetMessagingTimeout(self, seconds) }

    func isSame(_ other: AXUIElement?) -> Bool {
        guard let other else { return false }
        return CFEqual(self, other)
    }
}

enum AX {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let getWindowFn: GetWindowFn? = {
        // RTLD_DEFAULT == (void *)-2 on Darwin
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func app(_ pid: pid_t, timeout: Float = 0.25) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        el.setTimeout(timeout)
        return el
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }
}
