import Foundation
import Observation

/// One file's matches in Find in Project.
struct SearchFileResult: Identifiable, Sendable {
    let url: URL
    /// Path from the project root.
    let path: String
    let matches: [SearchMatch]

    var id: String { url.path(percentEncoded: false) }
}

struct SearchMatch: Identifiable, Sendable {
    let id: String
    /// 1-based line number.
    let line: Int
    /// The match in the file's text (UTF-16).
    let range: NSRange
    /// The line, trimmed and shortened around the match.
    let preview: String
    /// The match within `preview`.
    let previewRange: NSRange
}

/// State behind Find in Project (⇧⌘F): the query and the matches across the
/// project's files, searched in the background as the query changes.
@Observable
final class ProjectSearchModel {
    let rootURL: URL

    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    var isCaseSensitive = false {
        didSet { scheduleSearch(after: .zero) }
    }

    private(set) var results: [SearchFileResult] = []
    private(set) var matchCount = 0
    private(set) var isSearching = false
    /// More matches exist than are listed.
    private(set) var isTruncated = false
    /// Files whose matches are folded away.
    var collapsedFiles: Set<URL> = []
    /// Bumped to put the cursor in the search field.
    var focusRequest = 0

    /// The current text of edited files, searched instead of what's on disk.
    @ObservationIgnored var unsavedTexts: () -> [URL: String] = { [:] }
    @ObservationIgnored private var task: Task<Void, Never>?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Searches again, e.g. after files changed on disk.
    func refresh() {
        guard !query.isEmpty else { return }
        scheduleSearch(after: .milliseconds(300))
    }

    private func scheduleSearch(after delay: Duration = .milliseconds(200)) {
        task?.cancel()
        let query = query
        guard !query.isEmpty else {
            results = []
            matchCount = 0
            isTruncated = false
            isSearching = false
            return
        }
        isSearching = true
        let root = rootURL
        let caseSensitive = isCaseSensitive
        let overrides = unsavedTexts()
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) {
                ProjectSearch.run(root: root, query: query, caseSensitive: caseSensitive, overrides: overrides)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.results = outcome.files
            self.matchCount = outcome.matchCount
            self.isTruncated = outcome.isTruncated
            self.isSearching = false
        }
    }
}

/// Plain-text search through the files Quick Open lists (so .gitignore applies).
nonisolated enum ProjectSearch {
    static let maxMatches = 2000
    static let maxFileSize = 5 * 1024 * 1024
    /// Context kept before a match in its preview: short, so the match stays visible
    /// in a narrow sidebar.
    private static let previewLead = 20
    private static let previewLength = 160

    struct Outcome: Sendable {
        var files: [SearchFileResult] = []
        var matchCount = 0
        var isTruncated = false
    }

    static func run(root: URL, query: String, caseSensitive: Bool, overrides: [URL: String]) -> Outcome {
        var outcome = Outcome()
        let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.caseInsensitive]
        for item in ProjectFileIndex.scan(root: root) {
            if Task.isCancelled { return Outcome() }
            guard let text = overrides[item.url] ?? readText(item.url) else { continue }
            let matches = search(text as NSString, for: query, options: options, file: item.url,
                                 limit: maxMatches - outcome.matchCount)
            guard !matches.isEmpty else { continue }
            outcome.files.append(SearchFileResult(url: item.url, path: item.path, matches: matches))
            outcome.matchCount += matches.count
            if outcome.matchCount >= maxMatches {
                outcome.isTruncated = true
                break
            }
        }
        return outcome
    }

    private static func readText(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileSize,
              let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func search(_ text: NSString, for query: String, options: NSString.CompareOptions,
                               file: URL, limit: Int) -> [SearchMatch] {
        var matches: [SearchMatch] = []
        var location = 0
        // Line counting walks forward from the previous match.
        var line = 1
        var counted = 0
        while location < text.length, matches.count < limit {
            let range = text.range(of: query, options: options, range: NSRange(location: location, length: text.length - location))
            guard range.location != NSNotFound, range.length > 0 else { break }

            for index in counted..<range.location where text.character(at: index) == 0x0A { line += 1 }
            counted = range.location

            let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
            var contentsEnd = NSMaxRange(lineRange)
            while contentsEnd > lineRange.location,
                  [0x0A, 0x0D].contains(text.character(at: contentsEnd - 1)) { contentsEnd -= 1 }
            // Skip the indentation, then keep a window around the match.
            var start = lineRange.location
            while start < range.location, [0x20, 0x09].contains(text.character(at: start)) { start += 1 }
            start = max(start, range.location - previewLead)
            let end = min(contentsEnd, max(NSMaxRange(range), start + previewLength))
            var preview = text.substring(with: NSRange(location: start, length: max(0, end - start)))
            var previewStart = range.location - start
            if start == range.location - previewLead, start > lineRange.location,
               text.substring(with: NSRange(location: lineRange.location, length: start - lineRange.location))
                   .contains(where: { !$0.isWhitespace }) {
                preview = "…" + preview
                previewStart += 1
            }
            let previewLength = min(range.length, (preview as NSString).length - previewStart)

            matches.append(SearchMatch(
                id: "\(file.path(percentEncoded: false))#\(matches.count)",
                line: line,
                range: range,
                preview: preview,
                previewRange: NSRange(location: previewStart, length: max(0, previewLength))
            ))
            location = NSMaxRange(range)
        }
        return matches
    }
}
