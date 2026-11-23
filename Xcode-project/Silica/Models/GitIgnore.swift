import Foundation

/// The rules from one ignore file (a `.gitignore`, or `.git/info/exclude`), following
/// the pattern format in `man gitignore`:
///
/// - blank lines and `#` comments are skipped; `\#` and `\!` escape a leading `#` / `!`
/// - `!` re-includes what an earlier rule excluded
/// - a trailing `/` matches directories only
/// - a pattern with a `/` at its start or middle is relative to the ignore file's
///   folder; otherwise it matches a name at any depth below it
/// - `*`, `?` and `[…]` don't match `/`; `**/`, `/**/` and `/**` span folders
///
/// Matching is case-insensitive, like git's default (`core.ignorecase`) on macOS.
nonisolated struct GitIgnoreFile: @unchecked Sendable {
    /// Folder the rules are relative to, as a project-relative path ("" for the root).
    let base: String
    private let rules: [Rule]

    var isEmpty: Bool { rules.isEmpty }

    init(base: String, contents: String) {
        self.base = base
        self.rules = contents
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .compactMap { Rule(line: String($0)) }
    }

    init?(base: String, url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(base: base, contents: String(decoding: data, as: UTF8.self))
    }

    /// `true` / `false` when a rule decides `path` (relative to `base`), `nil` if none matches.
    func decision(for path: String, isDirectory: Bool) -> Bool? {
        let lowered = path.lowercased()
        let name = lowered.split(separator: "/").last.map(String.init) ?? lowered
        var result: Bool?
        for rule in rules where rule.matches(path: lowered, name: name, isDirectory: isDirectory) {
            result = !rule.isNegated
        }
        return result
    }

    private struct Rule {
        enum Matcher {
            case name(String)
            case nameSuffix(String)
            case regex(NSRegularExpression)
        }

        let matcher: Matcher
        let isNegated: Bool
        let directoryOnly: Bool
        /// Anchored rules match the whole relative path; others match the last component.
        let isAnchored: Bool

        init?(line: String) {
            var pattern = Substring(line)
            if pattern.hasPrefix("#") { return nil }

            // Trailing spaces are dropped unless escaped with a backslash.
            while pattern.hasSuffix(" "), !pattern.hasSuffix("\\ ") { pattern.removeLast() }
            if pattern.isEmpty { return nil }

            var negated = false
            if pattern.hasPrefix("!") {
                negated = true
                pattern.removeFirst()
            } else if pattern.hasPrefix("\\!") || pattern.hasPrefix("\\#") {
                pattern.removeFirst()
            }

            var directoryOnly = false
            if pattern.hasSuffix("/") {
                directoryOnly = true
                pattern = pattern.dropLast()
            }
            if pattern.isEmpty { return nil }

            let anchored = pattern.contains("/")
            if pattern.hasPrefix("/") { pattern.removeFirst() }
            if pattern.isEmpty { return nil }

            let lowered = pattern.lowercased()
            self.isNegated = negated
            self.directoryOnly = directoryOnly
            self.isAnchored = anchored

            if !anchored, !lowered.contains(where: { "*?[\\".contains($0) }) {
                matcher = .name(lowered)
            } else if !anchored, lowered.hasPrefix("*"),
                      !lowered.dropFirst().contains(where: { "*?[\\".contains($0) }) {
                matcher = .nameSuffix(String(lowered.dropFirst()))
            } else {
                guard let regex = try? NSRegularExpression(pattern: "^" + Self.regex(from: lowered) + "$") else {
                    return nil
                }
                matcher = .regex(regex)
            }
        }

        func matches(path: String, name: String, isDirectory: Bool) -> Bool {
            if directoryOnly, !isDirectory { return false }
            let subject = isAnchored ? path : name
            switch matcher {
            case .name(let literal):
                return subject == literal
            case .nameSuffix(let suffix):
                return subject.hasSuffix(suffix)
            case .regex(let regex):
                let range = NSRange(subject.startIndex..., in: subject)
                return regex.firstMatch(in: subject, range: range) != nil
            }
        }

        /// Translates a gitignore glob into a regular expression body.
        private static func regex(from glob: String) -> String {
            let chars = Array(glob)
            var out = ""
            var i = 0
            while i < chars.count {
                let c = chars[i]
                switch c {
                case "*":
                    if i + 1 < chars.count, chars[i + 1] == "*" {
                        let atStart = i == 0
                        let afterSlash = i > 0 && chars[i - 1] == "/"
                        let beforeSlash = i + 2 < chars.count && chars[i + 2] == "/"
                        let atEnd = i + 2 == chars.count
                        if (atStart || afterSlash) && beforeSlash {
                            // "**/" — zero or more leading folders.
                            out += "(?:.*/)?"
                            i += 3
                            continue
                        } else if afterSlash && atEnd {
                            // "/**" — everything inside.
                            out += ".*"
                            i += 2
                            continue
                        }
                        // Any other "**" behaves like "*".
                        out += "[^/]*"
                        i += 2
                        continue
                    }
                    out += "[^/]*"
                case "?":
                    out += "[^/]"
                case "[":
                    if let close = chars[(i + 1)...].firstIndex(of: "]"), close > i + 1 {
                        var body = String(chars[(i + 1)..<close])
                        if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                        body = body.replacingOccurrences(of: "\\", with: "\\\\")
                        out += "[" + body + "]"
                        i = close + 1
                        continue
                    }
                    out += "\\["
                case "\\":
                    if i + 1 < chars.count {
                        out += NSRegularExpression.escapedPattern(for: String(chars[i + 1]))
                        i += 2
                        continue
                    }
                default:
                    out += NSRegularExpression.escapedPattern(for: String(c))
                }
                i += 1
            }
            return out
        }
    }
}

/// The ignore files that apply inside one folder, outermost first.
nonisolated struct GitIgnoreStack: Sendable {
    private(set) var files: [GitIgnoreFile] = []

    func adding(_ file: GitIgnoreFile?) -> GitIgnoreStack {
        guard let file, !file.isEmpty else { return self }
        var copy = self
        copy.files.append(file)
        return copy
    }

    /// Whether `path` (project-relative) is ignored. Deeper files and later rules win.
    func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for file in files {
            let relative: String
            if file.base.isEmpty {
                relative = path
            } else if path.hasPrefix(file.base + "/") {
                relative = String(path.dropFirst(file.base.count + 1))
            } else {
                continue
            }
            if let decision = file.decision(for: relative, isDirectory: isDirectory) {
                ignored = decision
            }
        }
        return ignored
    }
}
