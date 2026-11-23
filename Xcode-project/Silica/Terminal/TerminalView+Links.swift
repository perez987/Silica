import AppKit
import GhosttyVt

/// A link in the terminal's text and the cells that show it.
struct TerminalLink: Equatable {
    /// Cells next to each other in one row of the screen.
    struct Span: Equatable {
        var row: Int
        var columns: Range<Int>
    }

    let url: URL
    /// A link that wraps has a span in each row it reaches.
    let spans: [Span]
    /// The line a path to a file came with, as in "Editor.swift:42".
    var line: Int?

    func columns(inRow row: Int) -> Range<Int>? {
        spans.first { $0.row == row }?.columns
    }

    func contains(column: Int, row: Int) -> Bool {
        columns(inRow: row)?.contains(column) == true
    }

    /// Where the link leads, to show before it's followed: a program can put a link
    /// on any text, so the text itself doesn't say.
    var destination: String {
        guard url.isFileURL else { return url.absoluteString }
        return (url.path as NSString).abbreviatingWithTildeInPath + (line.map { ":\($0)" } ?? "")
    }

    /// The URL for a link's text, or `nil` if it isn't one to follow.
    ///
    /// What a terminal shows can come from anywhere: a file that was printed, another
    /// machine. So only web and mail addresses open, and files on this Mac, which
    /// open in the editor rather than being launched.
    static func url(from text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return url.host?.isEmpty == false ? url : nil
        case "mailto":
            return url
        case "file":
            // Programs name the machine in file links, for terminals that show
            // another one's output.
            guard isThisMac(url.host ?? ""), !url.path.isEmpty else { return nil }
            return URL(fileURLWithPath: url.path)
        default:
            return nil
        }
    }

    private static func isThisMac(_ host: String) -> Bool {
        if host.isEmpty || host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return false }
        func shortName(_ name: String) -> String {
            String(name.prefix { $0 != "." }).lowercased()
        }
        return shortName(String(cString: buffer)) == shortName(host)
    }
}

// Links come from two places. A program can mark text as a link (OSC 8), as `ls
// --hyperlink` and compilers do; libghostty-vt keeps the address with those cells.
// And what is simply printed is found in the text: web addresses, and the paths of
// files that exist, with the line a compiler or a search put after them.
//
// A link shows itself while ⌘ is held with the pointer over it, and a ⌘ click
// follows it, which leaves plain clicks and drags for selecting.

extension TerminalView {
    /// How far a link is followed to either side of the pointer, in cells.
    private static let linkReach = 4096

    private typealias Position = (column: Int, row: Int)

    /// The link at a point in the view, if there's one.
    func link(at point: CGPoint) -> TerminalLink? {
        guard session?.terminal != nil, columns > 0, rows > 0, bounds.contains(point) else { return nil }
        var position: Position = cell(at: point)
        // The second half of a wide character belongs to its first.
        if position.column > 0, let cell = gridCell(at: position)?.cell, Self.isSpacer(cell) {
            position.column -= 1
        }
        if let link = markedLink(at: position) { return link }
        guard let run = run(at: position) else { return nil }
        return addressLink(in: run) ?? pathLink(in: run)
    }

    // MARK: Hover

    /// Finds the link under the pointer again: the pointer moved, ⌘ went down or
    /// up, or the text under it changed.
    ///
    /// Looking for a path asks the disk whether the file is there, so a pointer
    /// that moved within a cell (`pointerMoved`) isn't looked under again.
    func updateHoveredLink(modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags, pointerMoved: Bool = false) {
        guard modifiers.contains(.command), let window, window.isKeyWindow else {
            hoveredLink = nil
            probedLinkCell = nil
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else {
            hoveredLink = nil
            probedLinkCell = nil
            return
        }
        let cell = cell(at: point)
        if pointerMoved, let probedLinkCell, probedLinkCell == cell { return }
        probedLinkCell = cell
        hoveredLink = link(at: point)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateHoveredLink(modifiers: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredLink = nil
        probedLinkCell = nil
    }

    // MARK: Opening

    func open(_ link: TerminalLink) {
        guard link.url.isFileURL else {
            NSWorkspace.shared.open(link.url)
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: link.url.path, isDirectory: &isDirectory) else {
            NSSound.beep()
            return
        }
        if isDirectory.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([link.url])
        } else {
            session?.onOpenFile?(link.url, link.line)
        }
    }

    @objc func openLink(_ sender: NSMenuItem) {
        if let link = sender.representedObject as? TerminalLink { open(link) }
    }

    @objc func copyLink(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? TerminalLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url.isFileURL ? link.url.path : link.url.absoluteString, forType: .string)
    }

    // MARK: Reading the grid

    private func gridCell(at position: Position) -> (ref: GhosttyGridRef, cell: GhosttyCell)? {
        guard let terminal = session?.terminal else { return nil }
        let coordinate = GhosttyPointCoordinate(x: UInt16(clamping: position.column), y: UInt32(clamping: position.row))
        var ref = GhosttyGridRef()
        var cell: GhosttyCell = 0
        guard ghostty_terminal_grid_ref(terminal, GhosttyPoint(tag: GHOSTTY_POINT_TAG_VIEWPORT, value: .init(coordinate: coordinate)), &ref) == GHOSTTY_SUCCESS,
              ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { return nil }
        return (ref, cell)
    }

    private static func isSpacer(_ cell: GhosttyCell) -> Bool {
        var wide = GHOSTTY_CELL_WIDE_NARROW
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
        return wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD
    }

    private static func isWide(_ cell: GhosttyCell) -> Bool {
        var wide = GHOSTTY_CELL_WIDE_NARROW
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
        return wide == GHOSTTY_CELL_WIDE_WIDE
    }

    /// Whether the line in `row` carries on in the row below, having reached the
    /// right edge, rather than ending there.
    private func wraps(row: Int) -> Bool {
        guard var ref = gridCell(at: (0, row))?.ref else { return false }
        var gridRow: GhosttyRow = 0
        var wraps = false
        guard ghostty_grid_ref_row(&ref, &gridRow) == GHOSTTY_SUCCESS else { return false }
        ghostty_row_get(gridRow, GHOSTTY_ROW_DATA_WRAP, &wraps)
        return wraps
    }

    /// The cell before (`step` -1) or after (1) a cell in reading order, on the
    /// screen. `throughLineEnds` goes on into the next row even where a line ends.
    private func neighbor(of position: Position, step: Int, throughLineEnds: Bool) -> Position? {
        let column = position.column + step
        if (0..<columns).contains(column) { return (column, position.row) }
        let row = position.row + step
        guard (0..<rows).contains(row), throughLineEnds || wraps(row: min(row, position.row)) else { return nil }
        return (step > 0 ? 0 : columns - 1, row)
    }

    /// The cells from `position` in one direction for as long as `accepts` them,
    /// nearest first. The spacer halves of wide characters are passed over.
    private func cells(
        from position: Position, step: Int, throughLineEnds: Bool, accepting accepts: (GhosttyGridRef, GhosttyCell) -> Bool
    ) -> [(position: Position, cell: GhosttyCell)] {
        var found: [(position: Position, cell: GhosttyCell)] = []
        var position = position
        for _ in 0..<Self.linkReach {
            guard let next = neighbor(of: position, step: step, throughLineEnds: throughLineEnds),
                  let (ref, cell) = gridCell(at: next) else { break }
            position = next
            if Self.isSpacer(cell) { continue }
            guard accepts(ref, cell) else { break }
            found.append((next, cell))
        }
        return found
    }

    /// The spans of cells in reading order: one for each row they're in.
    private static func spans(of cells: [(position: Position, cell: GhosttyCell)]) -> [TerminalLink.Span] {
        var spans: [TerminalLink.Span] = []
        for (position, cell) in cells {
            let end = position.column + (isWide(cell) ? 2 : 1)
            if let last = spans.indices.last, spans[last].row == position.row {
                spans[last].columns = spans[last].columns.lowerBound..<end
            } else {
                spans.append(.init(row: position.row, columns: position.column..<end))
            }
        }
        return spans
    }

    // MARK: Links a program marked

    /// The address a program gave the cell, as the bytes it sent.
    private static func address(of ref: GhosttyGridRef, cell: GhosttyCell) -> [UInt8]? {
        var hasLink = false
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &hasLink)
        guard hasLink else { return nil }
        var ref = ref
        var length = 0
        guard ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &length) == GHOSTTY_OUT_OF_SPACE, length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard ghostty_grid_ref_hyperlink_uri(&ref, &bytes, length, &length) == GHOSTTY_SUCCESS else { return nil }
        return Array(bytes.prefix(length))
    }

    private func markedLink(at position: Position) -> TerminalLink? {
        guard let (ref, cell) = gridCell(at: position), let address = Self.address(of: ref, cell: cell),
              let url = TerminalLink.url(from: String(decoding: address, as: UTF8.self)) else { return nil }
        // A link is the same wherever its text breaks, so this follows it past the
        // ends of lines too.
        let isSameLink: (GhosttyGridRef, GhosttyCell) -> Bool = { Self.address(of: $0, cell: $1) == address }
        let before = cells(from: position, step: -1, throughLineEnds: true, accepting: isSameLink)
        let after = cells(from: position, step: 1, throughLineEnds: true, accepting: isSameLink)
        return TerminalLink(url: url, spans: Self.spans(of: before.reversed() + [(position, cell)] + after))
    }

    // MARK: Links in the text

    /// How addresses found in the text begin.
    private static let schemes = ["https://", "http://", "file://"].map { Array($0.unicodeScalars.map(\.value)) }

    private static func character(of cell: GhosttyCell) -> UInt32 {
        var codepoint: UInt32 = 0
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
        return codepoint
    }

    /// Whether a character can be part of an address. Spaces and quotes end one, and
    /// so do the lines of a table or a frame drawn around it.
    private static func isAddressCharacter(_ character: UInt32) -> Bool {
        switch character {
        case 0...0x20, 0x7F...0xA0, 0x2500...0x259F, 0xE0B0...0xE0B3: false
        default: !addressDelimiters.contains(character)
        }
    }

    private static let addressDelimiters = Set("\"<>`|\\^{}".unicodeScalars.map(\.value))

    /// The characters around the pointer that an address or a path could be made of.
    private struct Run {
        var cells: [(position: Position, cell: GhosttyCell)]
        var characters: [UInt32]
        /// The index of the cell under the pointer.
        var pointer: Int

        func text(_ range: Range<Int>) -> String {
            var text = String.UnicodeScalarView()
            for character in characters[range] {
                if let scalar = Unicode.Scalar(character) { text.append(scalar) }
            }
            return String(text)
        }
    }

    /// The run of address characters around a cell, through wrapped rows: a long
    /// address is one line to the program that printed it.
    private func run(at position: Position) -> Run? {
        guard let cell = gridCell(at: position)?.cell, Self.isAddressCharacter(Self.character(of: cell)) else { return nil }
        let isAddress: (GhosttyGridRef, GhosttyCell) -> Bool = { Self.isAddressCharacter(Self.character(of: $1)) }
        let before = cells(from: position, step: -1, throughLineEnds: false, accepting: isAddress)
        let after = cells(from: position, step: 1, throughLineEnds: false, accepting: isAddress)
        let cells = before.reversed() + [(position, cell)] + after
        return Run(cells: cells, characters: cells.map { Self.character(of: $0.cell) }, pointer: before.count)
    }

    private func addressLink(in run: Run) -> TerminalLink? {
        let characters = run.characters, pointer = run.pointer

        // The address starts at the last scheme at or before the pointer, which
        // leaves out what comes first in "(see https://…" or "url=https://…".
        func hasScheme(at index: Int) -> Bool {
            Self.schemes.contains { scheme in
                characters[index...].count > scheme.count
                    && zip(characters[index...], scheme).allSatisfy { $0 | 0x20 == $1 }
            }
        }
        guard let start = (0...pointer).last(where: hasScheme) else { return nil }
        var end = characters.count
        // And ends before the punctuation of the sentence it's in. A closing bracket
        // stays if the address opened it, as in a Wikipedia link.
        let brackets: [UInt32: UInt32] = [0x29: 0x28, 0x5D: 0x5B] // ) and ]
        let punctuation = Set(".,;:!?'".unicodeScalars.map(\.value))
        while end > start {
            let last = characters[end - 1]
            if punctuation.contains(last) {
                end -= 1
            } else if let opening = brackets[last],
                      characters[start..<end].count(where: { $0 == opening }) < characters[start..<end].count(where: { $0 == last }) {
                end -= 1
            } else {
                break
            }
        }
        guard pointer < end, let url = TerminalLink.url(from: run.text(start..<end)) else { return nil }
        return TerminalLink(url: url, spans: Self.spans(of: Array(run.cells[start..<end])))
    }

    // MARK: Paths in the text

    /// A run longer than any path isn't looked at.
    private static let longestPath = 1024
    private static let pathOpeners = Set("'([".unicodeScalars.map(\.value))
    private static let pathClosers = Set(".,;:!?')]".unicodeScalars.map(\.value))

    /// A file a program named, with the line if it gave one: "Editor.swift:42:7"
    /// from a compiler, "notes.md:3:" from a search, "main.ts(12,5)", or only the
    /// name, as `ls` and `git status` print it. Anything is a link whose file is
    /// there, which is what tells a path from a word.
    private func pathLink(in run: Run) -> TerminalLink? {
        let characters = run.characters, pointer = run.pointer
        guard characters.count <= Self.longestPath, let directories = session?.workingDirectories else { return nil }
        func character(_ index: Int) -> UInt32? { characters.indices.contains(index) ? characters[index] : nil }
        func number(at index: Int) -> (value: Int, end: Int)? {
            var end = index
            while let digit = character(end), (0x30...0x39).contains(digit), end - index < 9 { end += 1 }
            return end > index ? (Int(run.text(index..<end)) ?? 0, end) : nil
        }

        // The path starts after what it's wrapped in or assigned to, as in
        // "(Editor.swift:42)" and "--config=build.json".
        var start = characters[..<pointer].lastIndex(of: 0x3D).map { $0 + 1 } ?? 0
        while start < pointer, Self.pathOpeners.contains(characters[start]) { start += 1 }

        // Where it may end: before a line number, tried from the left, or else at
        // the end of the run, less the punctuation of the sentence it's in.
        var endings: [(path: Int, link: Int, line: Int?)] = []
        for index in characters.indices.dropFirst(start + 1) where endings.count < 4 {
            let isColon = characters[index] == 0x3A
            guard isColon || characters[index] == 0x28, let line = number(at: index + 1) else { continue }
            var end = line.end
            // A column may follow the line; it's part of the link, though only the
            // line is gone to.
            if character(end) == (isColon ? 0x3A : 0x2C), let column = number(at: end + 1) { end = column.end }
            if !isColon {
                guard character(end) == 0x29 else { continue }
                end += 1
            }
            endings.append((index, end, line.value))
        }
        var end = characters.count
        while end > start, Self.pathClosers.contains(characters[end - 1]) { end -= 1 }
        endings.append((end, end, nil))

        for ending in endings where ending.path > start && pointer < ending.link {
            guard let url = Self.file(at: run.text(start..<ending.path), in: directories) else { continue }
            var line = ending.line
            if line == nil, ending.link == characters.count { line = lineNamed(after: run) }
            return TerminalLink(url: url, spans: Self.spans(of: Array(run.cells[start..<ending.link])), line: line)
        }
        return nil
    }

    /// The file a path names, if there's one: the path as it is, or from one of the
    /// folders it may be relative to.
    private static func file(at path: String, in directories: [URL]) -> URL? {
        guard !path.contains("://") else { return nil }
        var paths = [(path as NSString).expandingTildeInPath]
        // A diff names the two sides of a file "a/…" and "b/…".
        if path.hasPrefix("a/") || path.hasPrefix("b/") { paths.append(String(path.dropFirst(2))) }
        for path in paths {
            let candidates = path.hasPrefix("/") ? [URL(fileURLWithPath: path)] : directories.map { $0.appendingPathComponent(path) }
            for candidate in candidates {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    return candidate.standardizedFileURL
                }
            }
        }
        return nil
    }

    /// The line in `File "main.py", line 12`, as Python's errors name it after the
    /// path.
    private func lineNamed(after run: Run) -> Int? {
        guard let last = run.cells.last?.position else { return nil }
        var room = 20
        let following = cells(from: last, step: 1, throughLineEnds: false) { _, _ in
            room -= 1
            return room >= 0
        }
        var text = String.UnicodeScalarView()
        for cell in following {
            text.append(Unicode.Scalar(Self.character(of: cell.cell)).flatMap { $0.value == 0 ? nil : $0 } ?? " ")
        }
        let prefix = "\", line "
        guard String(text).hasPrefix(prefix) else { return nil }
        return Int(String(text).dropFirst(prefix.count).prefix { $0.isNumber })
    }
}
