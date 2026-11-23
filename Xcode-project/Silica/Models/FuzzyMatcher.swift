import Foundation

/// A file in a project, prepared for fuzzy matching.
nonisolated struct QuickOpenItem: Sendable, Identifiable {
    let url: URL
    /// Path relative to the project root, e.g. `Sources/App/main.swift`.
    let path: String
    /// Scalar index where the file name starts within `path`.
    let nameStart: Int
    let scalars: [Unicode.Scalar]
    /// Lowercased scalar values, one per entry in `scalars`.
    let lowered: [UInt32]

    var id: URL { url }

    init(url: URL, path: String) {
        self.url = url
        self.path = path
        let scalars = Array(path.unicodeScalars)
        self.scalars = scalars
        self.lowered = scalars.map(FuzzyMatcher.lower)
        self.nameStart = (scalars.lastIndex(of: "/") ?? -1) + 1
    }
}

nonisolated struct FuzzyMatch: Sendable {
    let score: Int
    /// Scalar indices into the item's path that matched the query.
    let positions: [Int]
}

/// Subsequence matching in the style of editor "Quick Open" pickers: the query's
/// characters must appear in order, and matches score higher when they are
/// consecutive, start words, or fall in the file name rather than its folders.
nonisolated enum FuzzyMatcher {
    /// Lowercased query scalars, with spaces dropped so "app main" matches `App/main.swift`.
    static func prepare(_ query: String) -> [UInt32] {
        query.unicodeScalars.filter { !$0.properties.isWhitespace }.map(lower)
    }

    static func match(_ query: [UInt32], in item: QuickOpenItem) -> FuzzyMatch? {
        guard !query.isEmpty, query.count <= item.lowered.count,
              isSubsequence(query, of: item.lowered[...]) else { return nil }

        var best: FuzzyMatch?
        // Prefer a match inside the file name; try a few starting points there.
        if isSubsequence(query, of: item.lowered[item.nameStart...]) {
            var attempts = 0
            for start in item.nameStart..<item.lowered.count where item.lowered[start] == query[0] {
                if let positions = forward(query, in: item.lowered, from: start) {
                    let candidate = FuzzyMatch(score: score(positions, query: query, in: item), positions: positions)
                    if best == nil || candidate.score > best!.score { best = candidate }
                }
                attempts += 1
                if attempts == 6 { break }
            }
        }
        // Otherwise (or as a competitor) match right-to-left over the whole path,
        // which keeps the tail of the query as close to the file name as possible.
        if let positions = backward(query, in: item.lowered) {
            let candidate = FuzzyMatch(score: score(positions, query: query, in: item), positions: positions)
            if best == nil || candidate.score > best!.score { best = candidate }
        }
        return best
    }

    // MARK: Matching

    private static func isSubsequence(_ query: [UInt32], of text: ArraySlice<UInt32>) -> Bool {
        var q = 0
        for value in text where value == query[q] {
            q += 1
            if q == query.count { return true }
        }
        return false
    }

    private static func forward(_ query: [UInt32], in text: [UInt32], from start: Int) -> [Int]? {
        var positions: [Int] = []
        positions.reserveCapacity(query.count)
        var q = 0
        var i = start
        while i < text.count, q < query.count {
            if text[i] == query[q] {
                positions.append(i)
                q += 1
            }
            i += 1
        }
        return q == query.count ? positions : nil
    }

    private static func backward(_ query: [UInt32], in text: [UInt32]) -> [Int]? {
        var positions = [Int](repeating: 0, count: query.count)
        var q = query.count - 1
        var i = text.count - 1
        while i >= 0, q >= 0 {
            if text[i] == query[q] {
                positions[q] = i
                q -= 1
            }
            i -= 1
        }
        return q < 0 ? positions : nil
    }

    // MARK: Scoring

    private static func score(_ positions: [Int], query: [UInt32], in item: QuickOpenItem) -> Int {
        let scalars = item.scalars
        var score = 0
        var previous = -2
        for position in positions {
            score += 10
            if position == previous + 1 {
                score += 15
            } else if previous >= 0 {
                score -= min(position - previous - 1, 10)
            }
            if position == item.nameStart {
                score += 25
            } else if position == 0 || isSeparator(scalars[position - 1]) {
                score += 12
            } else if isUpper(scalars[position]) && !isUpper(scalars[position - 1]) {
                score += 10
            }
            if position >= item.nameStart { score += 6 }
            previous = position
        }
        if let first = positions.first, first >= item.nameStart {
            score += 30
            // The query is a prefix of the file name, e.g. "main" for main.swift.
            if first == item.nameStart, positions.last! - first == positions.count - 1 {
                score += 40
            }
        }
        return score - item.lowered.count / 6
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "/", "_", "-", ".", " ": true
        default: false
        }
    }

    private static func isUpper(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isUppercase
    }

    static func lower(_ scalar: Unicode.Scalar) -> UInt32 {
        if scalar.isASCII {
            let value = scalar.value
            return (0x41...0x5A).contains(value) ? value + 0x20 : value
        }
        return scalar.properties.lowercaseMapping.unicodeScalars.first?.value ?? scalar.value
    }
}
