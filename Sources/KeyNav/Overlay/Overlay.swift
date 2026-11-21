import AppKit

struct OverlayStyle {
    var windowFontSize: CGFloat
    var elementFontSize: CGFloat
    var background: NSColor
    var text: NSColor
    var border: NSColor
    var opacity: CGFloat
    var thumbnailHeight: CGFloat
    var showOutlines: Bool

    init(_ s: Settings) {
        windowFontSize = s.windowFontSize
        elementFontSize = s.elementFontSize
        background = s.badgeBackground.nsColor
        text = s.badgeText.nsColor
        border = s.badgeBorder.nsColor
        opacity = s.badgeOpacity
        thumbnailHeight = s.thumbnailHeight
        showOutlines = s.showOutlines
    }
}

struct Badge {
    enum Kind { case window, element }
    let label: String
    let kind: Kind
    /// Global CG rect of the badge (computed at layout time).
    var rect: CGRect
    var outline: CGRect?
}

struct StripCard {
    let label: String
    let windowID: CGWindowID
    let title: String
    let icon: NSImage?
    var image: NSImage?
    let aspect: CGFloat
    var rect: CGRect = .zero        // card rect, global CG
    var imageRect: CGRect = .zero   // thumbnail area, global CG
}

@MainActor
final class OverlayController {

    private var panels: [(screen: NSScreen, panel: OverlayPanel)] = []
    private var hudPanel: NSPanel?
    private(set) var badges: [Badge] = []
    private(set) var cards: [StripCard] = []
    private(set) var stripBackground: CGRect?
    private(set) var prefix = ""
    private(set) var style: OverlayStyle?
    /// Label picked with the scroll wheel, and the frame of its window when labeled in place.
    private(set) var highlight: String?
    private(set) var highlightFrame: CGRect?

    init() { rebuildPanels() }

    func rebuildPanels() {
        panels.forEach { $0.panel.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(screen: screen)
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            view.screenOrigin = ScreenGeometry.cgFrame(of: screen).origin
            view.isMainScreen = screen == ScreenGeometry.mainScreen
            panel.contentView = view
            return (screen, panel)
        }
    }

    var isVisible: Bool { panels.contains { $0.panel.isVisible } }

    // MARK: Showing

    /// `windowBadges`: label + anchor (center). `elementBadges`: label + element frame (badge at top-left).
    func show(windowBadges: [(String, CGPoint)], elementBadges: [(String, CGRect)],
              cards newCards: [StripCard], style: OverlayStyle) {
        self.style = style
        prefix = ""
        highlight = nil
        highlightFrame = nil
        badges = layoutWindowBadges(windowBadges, style: style) + layoutElementBadges(elementBadges, style: style)
        cards = newCards
        layoutStrip(style: style)
        for (_, panel) in panels {
            panel.contentView?.needsDisplay = true
            panel.orderFrontRegardless()
        }
    }

    func setHighlight(_ label: String?, frame: CGRect?) {
        highlight = label
        highlightFrame = frame
        redraw()
    }

    func update(prefix: String) {
        self.prefix = prefix
        redraw()
    }

    func updateImage(windowID: CGWindowID, image: NSImage) {
        guard let i = cards.firstIndex(where: { $0.windowID == windowID }) else { return }
        cards[i].image = image
        redraw()
    }

    /// Temporarily hide the labels so the controls underneath can be seen.
    func setPeek(_ peeking: Bool) {
        panels.forEach { $0.panel.alphaValue = peeking ? 0 : 1 }
    }

    func hide() {
        setPeek(false)
        panels.forEach { $0.panel.orderOut(nil) }
        badges = []
        cards = []
        stripBackground = nil
    }

    private func redraw() { panels.forEach { $0.panel.contentView?.needsDisplay = true } }

    // MARK: HUD

    func flashHUD(_ text: String) {
        hudPanel?.orderOut(nil)
        guard let screen = ScreenGeometry.mainScreen else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: label.frame.height + 24)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + screen.frame.height * 0.3)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        label.frame.origin = NSPoint(x: 20, y: 12)
        bg.addSubview(label)
        panel.contentView = bg
        panel.orderFrontRegardless()
        hudPanel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.hudPanel === panel { self?.hudPanel = nil }
        }
    }

    // MARK: Layout

    static func badgeFont(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .heavy) }

    static func badgeSize(_ label: String, fontSize: CGFloat) -> CGSize {
        let text = NSAttributedString(string: label.uppercased(), attributes: [.font: badgeFont(fontSize)])
        let s = text.size()
        return CGSize(width: ceil(s.width + fontSize * 0.7), height: ceil(s.height + fontSize * 0.24))
    }

    private func layoutWindowBadges(_ items: [(String, CGPoint)], style: OverlayStyle) -> [Badge] {
        var placed: [CGRect] = []
        return items.map { label, anchor in
            let size = Self.badgeSize(label, fontSize: style.windowFontSize)
            var rect = CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2, width: size.width, height: size.height)
            // Push apart badges that share a spot (e.g. two windows with the same center).
            var tries = 0
            while placed.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(rect) }), tries < 12 {
                rect.origin.y += size.height + 8
                tries += 1
            }
            placed.append(rect)
            return Badge(label: label, kind: .window, rect: rect)
        }
    }

    private func layoutElementBadges(_ items: [(String, CGRect)], style: OverlayStyle) -> [Badge] {
        let screens = ScreenGeometry.allScreensCG
        let frames = items.map(\.1)
        var placed: [CGRect] = []
        return items.enumerated().map { index, item in
            let (label, frame) = item
            let size = Self.badgeSize(label, fontSize: style.elementFontSize)
            let rect = Self.elementBadgeRect(index: index, frame: frame, size: size, frames: frames,
                                             placed: placed, screens: screens)
            placed.append(rect)
            return Badge(label: label, kind: .element, rect: rect, outline: style.showOutlines ? frame : nil)
        }
    }

    /// Small controls (icons) get the badge beside them so the icon stays readable; it goes on the
    /// first side that covers no other labeled control. Large controls get it inside the top-left corner.
    nonisolated static func elementBadgeRect(index: Int, frame: CGRect, size: CGSize, frames: [CGRect],
                                 placed: [CGRect], screens: [CGRect]) -> CGRect {
        let inside = CGRect(x: frame.minX + 2, y: frame.minY + 2, width: size.width, height: size.height)
        let isLarge = frame.width >= size.width * 3 && frame.height >= size.height * 1.6
        if isLarge { return nudge(inside, placed: placed) }

        let gap: CGFloat = 2
        let candidates = [
            CGRect(x: frame.minX - size.width - gap, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: frame.midX - size.width / 2, y: frame.minY - size.height - gap, width: size.width, height: size.height),
            CGRect(x: frame.maxX + gap, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: frame.midX - size.width / 2, y: frame.maxY + gap, width: size.width, height: size.height),
        ]
        for c in candidates {
            guard screens.contains(where: { $0.contains(c) }) else { continue }
            if placed.contains(where: { $0.intersects(c) }) { continue }
            let hitsControl = frames.indices.contains { j in
                guard j != index else { return false }
                let other = frames[j]
                // Containers (a row around this button) don't count as being covered.
                if other.contains(CGPoint(x: frame.midX, y: frame.midY)) { return false }
                return other.insetBy(dx: 1, dy: 1).intersects(c)
            }
            if !hitsControl { return c }
        }
        return nudge(inside, placed: placed)
    }

    nonisolated private static func nudge(_ start: CGRect, placed: [CGRect]) -> CGRect {
        var rect = start
        var tries = 0
        while placed.contains(where: { $0.intersects(rect) }), tries < 3 {
            rect.origin.x += rect.width + 2
            tries += 1
        }
        return rect
    }

    private func layoutStrip(style: OverlayStyle) {
        stripBackground = nil
        guard !cards.isEmpty, let screen = ScreenGeometry.mainScreen else { return }
        let visible = ScreenGeometry.cgVisibleFrame(of: screen)
        let spacing: CGFloat = 16, titleH: CGFloat = 26, margin: CGFloat = 24
        let available = visible.width - 2 * margin

        func cardWidth(_ c: StripCard, _ h: CGFloat) -> CGFloat {
            min(max(h * c.aspect, h * 0.8), h * 1.75)
        }
        var h = style.thumbnailHeight
        let total = cards.reduce(0) { $0 + cardWidth($1, h) } + spacing * CGFloat(cards.count - 1)
        if total > available { h = max(h * 0.6, h * available / total) }

        // Greedy rows, growing upward from the bottom.
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for i in cards.indices {
            let w = cardWidth(cards[i], h)
            if x > 0 && x + w > available { rows.append([]); x = 0 }
            rows[rows.count - 1].append(i)
            x += w + spacing
        }

        let badgeOverhang = Self.badgeSize("W", fontSize: max(18, style.windowFontSize * 0.6)).height / 2
        let rowHeight = h + titleH + badgeOverhang + spacing
        var bottom = visible.maxY - margin - badgeOverhang
        var union = CGRect.null
        for row in rows {
            let widths = row.map { cardWidth(cards[$0], h) }
            let rowWidth = widths.reduce(0, +) + spacing * CGFloat(row.count - 1)
            var cx = visible.midX - rowWidth / 2
            for (k, i) in row.enumerated() {
                let rect = CGRect(x: cx, y: bottom - h - titleH, width: widths[k], height: h + titleH)
                cards[i].rect = rect
                cards[i].imageRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h).insetBy(dx: 6, dy: 6)
                union = union.union(rect)
                cx += widths[k] + spacing
            }
            bottom -= rowHeight
        }
        var bg = union.insetBy(dx: -14, dy: -14)
        bg.size.height += badgeOverhang  // room for the badges hanging off the bottom edge
        stripBackground = bg
    }
}

final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Click-through: the app underneath keeps its hover state (hover-only buttons stay visible).
        // Clicks are noticed by KeyRouter's event tap instead.
        ignoresMouseEvents = true
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    weak var controller: OverlayController?
    var screenOrigin: CGPoint = .zero
    var isMainScreen = false

    override var isFlipped: Bool { true }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y) }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = controller, let style = c.style else { return }
        let screenRect = CGRect(origin: screenOrigin, size: bounds.size)

        if let frame = c.highlightFrame, screenRect.intersects(frame) {
            let path = NSBezierPath(roundedRect: local(frame).insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
            style.background.withAlphaComponent(0.12).setFill()
            path.fill()
            style.background.setStroke()
            path.lineWidth = 5
            path.stroke()
        }

        for badge in c.badges where screenRect.intersects(badge.rect) {
            if let outline = badge.outline {
                style.background.withAlphaComponent(0.8).setStroke()
                let p = NSBezierPath(rect: local(outline).insetBy(dx: 0.5, dy: 0.5))
                p.lineWidth = 1
                p.stroke()
            }
            drawBadge(badge.label, in: local(badge.rect),
                      fontSize: badge.kind == .window ? style.windowFontSize : style.elementFontSize,
                      halo: badge.kind == .window, style: style, prefix: c.prefix,
                      highlighted: badge.label == c.highlight)
        }

        guard isMainScreen, !c.cards.isEmpty else { return }
        if let bg = c.stripBackground {
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: local(bg), xRadius: 18, yRadius: 18).fill()
        }
        let stripFont = max(18, style.windowFontSize * 0.6)
        for card in c.cards {
            drawCard(card, style: style, prefix: c.prefix, badgeFont: stripFont, highlighted: card.label == c.highlight)
        }
    }

    private func drawCard(_ card: StripCard, style: OverlayStyle, prefix: String, badgeFont: CGFloat, highlighted: Bool) {
        let rect = local(card.rect)
        let dim = !card.label.hasPrefix(prefix)
        NSGraphicsContext.saveGraphicsState()
        if dim { NSGraphicsContext.current?.cgContext.setAlpha(0.3) }

        NSColor(white: 0.12, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()

        let imageArea = local(card.imageRect)
        if let image = card.image {
            let s = image.size
            let scale = min(imageArea.width / s.width, imageArea.height / s.height)
            let fit = CGRect(x: imageArea.midX - s.width * scale / 2, y: imageArea.midY - s.height * scale / 2,
                             width: s.width * scale, height: s.height * scale)
            image.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let icon = card.icon {
            let side = min(imageArea.width, imageArea.height) * 0.55
            icon.draw(in: CGRect(x: imageArea.midX - side / 2, y: imageArea.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        // Title row: icon + title.
        let titleY = imageArea.maxY + 4
        var textX = rect.minX + 8
        if let icon = card.icon {
            icon.draw(in: CGRect(x: textX, y: titleY, width: 16, height: 16), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            textX += 20
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: card.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: para,
        ]).draw(in: CGRect(x: textX, y: titleY, width: rect.maxX - textX - 8, height: 16))
        NSGraphicsContext.restoreGraphicsState()

        // Badge centered on the bottom edge.
        let size = OverlayController.badgeSize(card.label, fontSize: badgeFont)
        let badgeRect = CGRect(x: rect.midX - size.width / 2, y: rect.maxY - size.height / 2, width: size.width, height: size.height)
        if highlighted {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 12, yRadius: 12)
            style.background.setStroke()
            ring.lineWidth = 4
            ring.stroke()
        }
        drawBadge(card.label, in: badgeRect, fontSize: badgeFont, halo: false, style: style, prefix: prefix,
                  highlighted: highlighted)
    }

    private func drawBadge(_ label: String, in rect: CGRect, fontSize: CGFloat, halo: Bool, style: OverlayStyle,
                           prefix: String, highlighted: Bool = false) {
        // Highlighted: 20% larger with inverted colors.
        let rect = highlighted ? rect.insetBy(dx: -rect.width * 0.1, dy: -rect.height * 0.1) : rect
        let fontSize = highlighted ? fontSize * 1.2 : fontSize
        let fill = highlighted ? style.text : style.background
        let ink = highlighted ? style.background : style.text
        let matches = label.hasPrefix(prefix)
        let typed = matches ? prefix.count : 0
        let text = label.uppercased()
        let font = OverlayController.badgeFont(fontSize)

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setAlpha(matches ? style.opacity : 0.25 * style.opacity)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(halo ? 0.6 : 0.35)
        shadow.shadowBlurRadius = halo ? fontSize * 0.3 : 3
        shadow.shadowOffset = .zero
        shadow.set()

        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.25, yRadius: rect.height * 0.25)
        fill.setFill()
        path.fill()
        NSShadow().set()
        style.border.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attr = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
        if typed > 0 {
            attr.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.35), range: NSRange(location: 0, length: typed))
        }
        let s = attr.size()
        attr.draw(at: CGPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}
