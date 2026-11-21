import CoreGraphics

/// Decides where a window's label goes: on the window (returns the point) or the strip (nil).
enum VisibilityAnalyzer {
    static let gridSize = 7
    static let minUncoveredFraction = 0.15
    static let minRegion = CGSize(width: 120, height: 80)

    static func labelPoint(frame: CGRect, occluders: [CGRect], screens: [CGRect]) -> CGPoint? {
        func uncovered(_ p: CGPoint) -> Bool {
            frame.contains(p)
                && screens.contains { $0.contains(p) }
                && !occluders.contains { $0.contains(p) }
        }

        // 1. Center test.
        if uncovered(frame.center) { return frame.center }

        // 2. Grid sampling for the largest uncovered region.
        let n = gridSize
        let inset = 0.1
        let dx = frame.width * (1 - 2 * inset) / Double(n - 1)
        let dy = frame.height * (1 - 2 * inset) / Double(n - 1)
        func sample(_ col: Int, _ row: Int) -> CGPoint {
            CGPoint(x: frame.minX + frame.width * inset + Double(col) * dx,
                    y: frame.minY + frame.height * inset + Double(row) * dy)
        }

        var free = [[Bool]](repeating: [Bool](repeating: false, count: n), count: n)
        var freeCount = 0
        for r in 0..<n { for c in 0..<n where uncovered(sample(c, r)) { free[r][c] = true; freeCount += 1 } }
        guard Double(freeCount) >= minUncoveredFraction * Double(n * n) else { return nil }

        // Largest 4-connected component.
        var seen = [[Bool]](repeating: [Bool](repeating: false, count: n), count: n)
        var best: [(Int, Int)] = []
        for r in 0..<n {
            for c in 0..<n where free[r][c] && !seen[r][c] {
                var comp: [(Int, Int)] = []
                var queue = [(r, c)]
                seen[r][c] = true
                while let (cr, cc) = queue.popLast() {
                    comp.append((cr, cc))
                    for (nr, nc) in [(cr + 1, cc), (cr - 1, cc), (cr, cc + 1), (cr, cc - 1)]
                    where nr >= 0 && nr < n && nc >= 0 && nc < n && free[nr][nc] && !seen[nr][nc] {
                        seen[nr][nc] = true
                        queue.append((nr, nc))
                    }
                }
                if comp.count > best.count { best = comp }
            }
        }

        let rows = best.map(\.0), cols = best.map(\.1)
        let width = Double(cols.max()! - cols.min()! + 1) * dx
        let height = Double(rows.max()! - rows.min()! + 1) * dy
        guard width >= minRegion.width, height >= minRegion.height else { return nil }

        let points = best.map { sample($0.1, $0.0) }
        let cx = points.map(\.x).reduce(0, +) / Double(points.count)
        let cy = points.map(\.y).reduce(0, +) / Double(points.count)
        return points.min { hypot($0.x - cx, $0.y - cy) < hypot($1.x - cx, $1.y - cy) }
    }
}
