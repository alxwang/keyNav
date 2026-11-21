import AppKit

/// AX and CoreGraphics use global coordinates with the origin at the top-left of the
/// primary screen (y grows downward). AppKit uses bottom-left origin. All model types in
/// KeyNav use the CG convention; conversion happens only at the AppKit boundary.
enum ScreenGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cgFrame(of screen: NSScreen) -> CGRect {
        flip(screen.frame)
    }

    static func cgVisibleFrame(of screen: NSScreen) -> CGRect {
        flip(screen.visibleFrame)
    }

    /// Converts between CG (top-left) and AppKit (bottom-left) rects. The operation is its own inverse.
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static var allScreensCG: [CGRect] { NSScreen.screens.map(cgFrame(of:)) }

    /// The screen with the menu bar.
    static var mainScreen: NSScreen? { NSScreen.screens.first }

    static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { cgFrame(of: $0).contains(p) }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func iou(_ other: CGRect) -> CGFloat {
        let i = intersection(other)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        let union = width * height + other.width * other.height - inter
        return union > 0 ? inter / union : 0
    }
}
