import Foundation
import Observation

/// A file or folder in the explorer tree. Folder contents load lazily on expand.
@Observable
final class FileNode: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Path from the project root, "" for the root itself; used to match ignore rules.
    let relativePath: String

    /// Matched by a .gitignore rule, itself or through an ignored parent folder.
    private(set) var isIgnored: Bool
    /// Ignore rules in effect for this node's parent folder.
    @ObservationIgnored private var inheritedRules: GitIgnoreStack
    /// Ignore rules for this folder's children: inherited ones plus its own .gitignore.
    @ObservationIgnored private var childRules: GitIgnoreStack?

    /// `nil` until the folder has been expanded for the first time.
    private(set) var children: [FileNode]?
    var isExpanded = false {
        didSet { if isExpanded { loadChildrenIfNeeded() } }
    }

    var id: URL { url }

    /// Shown dimmed in the tree: dotfiles (which Finder hides) and gitignored items.
    var isDimmed: Bool { isIgnored || name.hasPrefix(".") }

    /// The project root, with the repository's `.git/info/exclude` rules.
    convenience init(root url: URL) {
        let rules = GitIgnoreStack()
            .adding(GitIgnoreFile(base: "", url: url.appending(path: ".git/info/exclude")))
        self.init(url: url, isDirectory: true, relativePath: "", isIgnored: false, inheritedRules: rules)
    }

    private init(url: URL, isDirectory: Bool, relativePath: String, isIgnored: Bool, inheritedRules: GitIgnoreStack) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.relativePath = relativePath
        self.isIgnored = isIgnored
        self.inheritedRules = inheritedRules
    }

    func loadChildrenIfNeeded() {
        guard isDirectory, children == nil else { return }
        children = contents()
    }

    /// Re-reads every loaded folder, keeping existing nodes (and their expansion state).
    /// Ignore rules are re-read too, so editing a .gitignore updates the dimming.
    func reload() {
        guard isDirectory, let old = children else { return }
        childRules = nil
        let existing = Dictionary(old.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let fresh = contents().map { node in
            guard let kept = existing[node.url] else { return node }
            kept.isIgnored = node.isIgnored
            kept.inheritedRules = node.inheritedRules
            return kept
        }
        children = fresh
        fresh.forEach { $0.reload() }
    }

    func collapseAll() {
        children?.forEach {
            $0.isExpanded = false
            $0.collapseAll()
        }
    }

    static let hiddenNames: Set<String> = [".DS_Store", ".git"]

    private func rulesForChildren() -> GitIgnoreStack {
        if let childRules { return childRules }
        let rules = inheritedRules.adding(GitIgnoreFile(base: relativePath, url: url.appending(path: ".gitignore")))
        childRules = rules
        return rules
    }

    private func contents() -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        )) ?? []
        let rules = rulesForChildren()

        return urls
            .filter { !Self.hiddenNames.contains($0.lastPathComponent) }
            .map { childURL in
                let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let normalized = URL(
                    filePath: childURL.path(percentEncoded: false),
                    directoryHint: isDir ? .isDirectory : .notDirectory
                )
                let name = childURL.lastPathComponent
                let path = relativePath.isEmpty ? name : relativePath + "/" + name
                return FileNode(
                    url: normalized,
                    isDirectory: isDir,
                    relativePath: path,
                    isIgnored: isIgnored || rules.isIgnored(path, isDirectory: isDir),
                    inheritedRules: rules
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
