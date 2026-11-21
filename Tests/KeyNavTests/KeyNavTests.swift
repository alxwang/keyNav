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
