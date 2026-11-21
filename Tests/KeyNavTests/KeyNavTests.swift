import XCTest
@testable import KeyNav

final class LabelGeneratorTests: XCTestCase {
    func testPrefixFreeAndUnique() {
        for n in [1, 5, 26, 27, 50, 200, 676, 700, 1000] {
            let labels = LabelGenerator.labels(count: n, alphabet: LabelGenerator.defaultAlphabet)
            XCTAssertEqual(labels.count, n)
            XCTAssertEqual(Set(labels).count, n, "duplicates for n=\(n)")
            for a in labels {
                for b in labels where a != b {
                    XCTAssertFalse(b.hasPrefix(a), "\(a) is a prefix of \(b) (n=\(n))")
                }
            }
        }
    }

    func testSingleCharsWhenTheyFit() {
        let labels = LabelGenerator.labels(count: 26, alphabet: LabelGenerator.defaultAlphabet)
        XCTAssertTrue(labels.allSatisfy { $0.count == 1 })
        XCTAssertEqual(labels.first, "a")
    }

    func testMinimalLengthJustOverAlphabet() {
        // 27 items with 26 chars: 25 singles + 2 doubles sharing the weakest prefix.
        let labels = LabelGenerator.labels(count: 27, alphabet: LabelGenerator.defaultAlphabet)
        XCTAssertEqual(labels.filter { $0.count == 1 }.count, 25)
        XCTAssertEqual(labels.filter { $0.count == 2 }.count, 2)
        XCTAssertTrue(labels.prefix(4).elementsEqual(["a", "s", "d", "f"]))
    }

    func testNormalizeDropsDuplicatesAndFallsBack() {
        XCTAssertEqual(String(LabelGenerator.normalize("aAbB c")), "abc")
        XCTAssertEqual(String(LabelGenerator.normalize("x")), LabelGenerator.defaultAlphabet)
    }
}

final class VisibilityAnalyzerTests: XCTestCase {
    let screen = [CGRect(x: 0, y: 0, width: 2000, height: 1200)]

    func testUncoveredCenter() {
        let f = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(VisibilityAnalyzer.labelPoint(frame: f, occluders: [], screens: screen), f.center)
    }

    func testFullyCoveredGoesToStrip() {
        let f = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertNil(VisibilityAnalyzer.labelPoint(frame: f, occluders: [f.insetBy(dx: -10, dy: -10)], screens: screen))
    }

    func testCenterCoveredButLargeRegionVisible() {
        let f = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let cover = CGRect(x: 300, y: 0, width: 1000, height: 800) // leaves left 300pt strip
        let p = VisibilityAnalyzer.labelPoint(frame: f, occluders: [cover], screens: screen)
        XCTAssertNotNil(p)
        XCTAssertLessThan(p!.x, 300)
    }

    func testSmallSliverGoesToStrip() {
        let f = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let cover = CGRect(x: 60, y: 0, width: 1000, height: 800) // only a 60pt sliver
        XCTAssertNil(VisibilityAnalyzer.labelPoint(frame: f, occluders: [cover], screens: screen))
    }

    func testOffScreenCountsAsCovered() {
        let f = CGRect(x: 1900, y: 100, width: 800, height: 600) // mostly off the right edge
        XCTAssertNil(VisibilityAnalyzer.labelPoint(frame: f, occluders: [], screens: screen))
    }
}

final class ElementOrderingTests: XCTestCase {
    private func el(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 40, _ h: CGFloat = 20, _ c: RoleCategory = .buttons) -> ElementInfo {
        ElementInfo(ax: AXUIElementCreateSystemWide(), role: "AXButton", subrole: nil,
                    frame: CGRect(x: x, y: y, width: w, height: h), category: c)
    }

    func testReadingOrder() {
        let items = [el(200, 12), el(10, 100), el(10, 10), el(100, 8)]
        let ordered = ElementScanner.readingOrder(items).map { $0.frame.origin }
        XCTAssertEqual(ordered, [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 8), CGPoint(x: 200, y: 12), CGPoint(x: 10, y: 100)])
    }

    func testDedupeKeepsStrongerRole() {
        let row = el(0, 0, 300, 20, .rows)
        let button = el(1, 0, 298, 20, .buttons)
        let result = ElementScanner.dedupe([row, button])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.category, .buttons)
    }

    func testDedupeKeepsDistinctElements() {
        XCTAssertEqual(ElementScanner.dedupe([el(0, 0), el(100, 0)]).count, 2)
    }
}

final class SettingsTests: XCTestCase {
    func testDecodingMissingKeysUsesDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"alphabet":"jkl"}"#.utf8))
        XCTAssertEqual(s.alphabet, "jkl")
        XCTAssertEqual(s.windowHotkey, Hotkey.defaultWindow)
        XCTAssertEqual(s.maxElements, 300)
    }

    func testRoundTrip() throws {
        var s = Settings()
        s.exclusions = [Exclusion(bundleID: "com.example", name: "Example")]
        s.roleCategories = [.links]
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testHotkeyDisplay() {
        XCTAssertEqual(Hotkey.defaultWindow.displayString, "⌥Space")
    }
}

final class ImportantElementTests: XCTestCase {
    private func el(_ role: String, _ c: RoleCategory, _ frame: CGRect, named: Bool = true,
                    url: String? = nil, ancestor: Int? = nil) -> ElementInfo {
        ElementInfo(ax: AXUIElementCreateSystemWide(), role: role, subrole: nil, frame: frame, category: c,
                    hasName: named, url: url, ancestor: ancestor)
    }

    func testChildrenOfRowsAndLinksAreHidden() {
        let items = [
            el("AXRow", .rows, CGRect(x: 0, y: 0, width: 400, height: 24)),
            el("AXCell", .rows, CGRect(x: 0, y: 0, width: 200, height: 24), ancestor: 0),
            el("AXButton", .buttons, CGRect(x: 360, y: 2, width: 20, height: 20), ancestor: 0),
            el("AXLink", .links, CGRect(x: 0, y: 100, width: 200, height: 20)),
            el("AXButton", .buttons, CGRect(x: 300, y: 100, width: 40, height: 20)),
        ]
        let roles = ElementScanner.important(items, badgeSize: 22).map(\.role)
        XCTAssertEqual(roles, ["AXRow", "AXLink", "AXButton"])
    }

    func testUnnamedAndDuplicateLinksAreHidden() {
        let items = [
            el("AXLink", .links, CGRect(x: 0, y: 0, width: 100, height: 20), url: "https://a"),
            el("AXLink", .links, CGRect(x: 0, y: 50, width: 100, height: 20), url: "https://a"),
            el("AXLink", .links, CGRect(x: 0, y: 100, width: 100, height: 20), named: false, url: "https://b"),
            el("AXTextField", .textInputs, CGRect(x: 0, y: 150, width: 100, height: 20), named: false),
        ]
        XCTAssertEqual(ElementScanner.important(items, badgeSize: 22).map(\.frame.minY), [0, 150])
    }

    func testNamedChildOfUnnamedWrapperIsKept() {
        let items = [
            el("AXLink", .links, CGRect(x: 0, y: 0, width: 100, height: 40), named: false),
            el("AXButton", .buttons, CGRect(x: 10, y: 10, width: 60, height: 20), ancestor: 0),
        ]
        XCTAssertEqual(ElementScanner.important(items, badgeSize: 22).map(\.role), ["AXButton"])
    }

    func testCollidingLabelsKeepStrongerControl() {
        let items = [
            el("AXRow", .rows, CGRect(x: 0, y: 0, width: 400, height: 24)),
            el("AXTextField", .textInputs, CGRect(x: 2, y: 2, width: 200, height: 20)),
        ]
        XCTAssertEqual(ElementScanner.important(items, badgeSize: 22).map(\.role), ["AXTextField"])
    }
}

final class BadgePlacementTests: XCTestCase {
    let screens = [CGRect(x: 0, y: 0, width: 2000, height: 1200)]
    let size = CGSize(width: 20, height: 20)

    func testSmallControlGetsBadgeOnTheLeft() {
        let icon = CGRect(x: 100, y: 100, width: 24, height: 24)
        let r = OverlayController.elementBadgeRect(index: 0, frame: icon, size: size, frames: [icon], placed: [], screens: screens)
        XCTAssertFalse(r.intersects(icon))
        XCTAssertLessThan(r.maxX, icon.minX + 0.1)
    }

    func testToolbarNeighborPushesBadgeAbove() {
        let left = CGRect(x: 70, y: 100, width: 24, height: 24)
        let icon = CGRect(x: 100, y: 100, width: 24, height: 24)
        let r = OverlayController.elementBadgeRect(index: 1, frame: icon, size: size, frames: [left, icon], placed: [], screens: screens)
        XCTAssertFalse(r.intersects(icon))
        XCTAssertFalse(r.intersects(left))
        XCTAssertLessThan(r.maxY, icon.minY + 0.1)
    }

    func testContainerDoesNotBlock() {
        let row = CGRect(x: 0, y: 90, width: 400, height: 44)
        let icon = CGRect(x: 100, y: 100, width: 24, height: 24)
        let r = OverlayController.elementBadgeRect(index: 1, frame: icon, size: size, frames: [row, icon], placed: [], screens: screens)
        XCTAssertLessThan(r.maxX, icon.minX + 0.1)
    }

    func testLargeControlGetsBadgeInside() {
        let field = CGRect(x: 100, y: 100, width: 300, height: 40)
        let r = OverlayController.elementBadgeRect(index: 0, frame: field, size: size, frames: [field], placed: [], screens: screens)
        XCTAssertTrue(field.contains(r))
    }
}
