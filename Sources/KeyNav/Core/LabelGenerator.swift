import Foundation

enum LabelGenerator {
    static let defaultAlphabet = "asdfjklgheruiwoqptycvnmxzb"

    /// Normalized, de-duplicated alphabet (falls back to the default if fewer than 2 usable chars).
    static func normalize(_ alphabet: String) -> [Character] {
        var seen = Set<Character>()
        var chars: [Character] = []
        for c in alphabet.lowercased() where !c.isWhitespace && !seen.contains(c) {
            seen.insert(c)
            chars.append(c)
        }
        return chars.count >= 2 ? chars : Array(defaultAlphabet)
    }

    /// Generates `count` prefix-free labels of minimal length. The earliest alphabet
    /// characters stay single-char labels; the weakest (last) characters become prefixes.
    /// Labels are returned in priority order: give the first label to the most important item.
    static func labels(count n: Int, alphabet: String) -> [String] {
        guard n > 0 else { return [] }
        let chars = normalize(alphabet)
        var labels = chars.map { String($0) }
        while labels.count < n {
            let minLen = labels.map(\.count).min()!
            let idx = labels.lastIndex { $0.count == minLen }!
            let prefix = labels.remove(at: idx)
            labels.append(contentsOf: chars.map { prefix + String($0) })
        }
        return Array(labels.prefix(n))
    }
}
