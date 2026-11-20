import Foundation

/// Narrows the explorer tree to files whose names contain the filter text, plus
/// everything inside folders whose names do. Works from the project's file index
/// (the one Quick Open uses), so it covers folders the tree hasn't loaded yet and
/// leaves out what git ignores.
nonisolated enum TreeFilter {
    struct Result: Sendable {
        /// Project-relative paths to show: matching files and every folder above them.
        var visiblePaths: Set<String>
        var matchCount: Int
    }

    /// Case-insensitive substring match on names, as in Xcode's navigator filter.
    static func filter(_ items: [QuickOpenItem], by query: String) -> Result {
        let needle = query.lowercased()
        var visible = Set<String>()
        var matches = 0
        for item in items {
            let components = item.path.split(separator: "/")
            guard let name = components.last else { continue }
            let nameMatches = name.lowercased().contains(needle)
            let folderMatches = components.dropLast().contains { $0.lowercased().contains(needle) }
            guard nameMatches || folderMatches else { continue }
            matches += 1
            var path = ""
            for component in components {
                path = path.isEmpty ? String(component) : path + "/" + component
                visible.insert(path)
            }
        }
        return Result(visiblePaths: visible, matchCount: matches)
    }

    /// Where `query` appears in `name`, for highlighting.
    static func matchRange(of query: String, in name: String) -> Range<String.Index>? {
        guard !query.isEmpty else { return nil }
        return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    }
}
