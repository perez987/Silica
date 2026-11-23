import AppKit

/// Code-editing commands: auto-indent on Return, Tab to the next indent stop, and
/// line commands (indent, outdent, toggle comment, move and duplicate lines).
///
/// Each command is a single undo step. The line commands are also responder-chain
/// actions, so menu items reach whichever editor has focus.
extension EditorTextView {
    // MARK: Return and Tab

    /// Keeps the current line's indentation, adds a level after an opening bracket
    /// (or `:` in Python and YAML), and puts a closing bracket right after the cursor
    /// on its own line.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let selection = selectedRange()
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location

        var indentEnd = lineStart
        while indentEnd < selection.location, Self.isIndentCharacter(text.character(at: indentEnd)) { indentEnd += 1 }
        let indent = text.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))

        var before = selection.location - 1
        while before >= lineStart, Self.isIndentCharacter(text.character(at: before)) { before -= 1 }
        let opener: unichar? = before >= lineStart ? text.character(at: before) : nil
        let after = NSMaxRange(selection)
        let next: unichar? = after < text.length ? text.character(at: after) : nil

        let opensBlock: Bool
        switch opener {
        case 0x7B /* { */, 0x5B /* [ */, 0x28 /* ( */: opensBlock = true
        case 0x3A /* : */: opensBlock = language?.opensBlockWithColon == true
        default: opensBlock = false
        }

        var insertion = lineEnding + indent
        if opensBlock { insertion += indentation.unitString }
        if opensBlock, let opener, let next, Self.closer(for: opener) == next {
            // `{|}` → the cursor on an indented line, the `}` on the line below.
            let caret = selection.location + (insertion as NSString).length
            insertion += lineEnding + indent
            insertText(insertion, replacementRange: selection)
            setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            insertText(insertion, replacementRange: selection)
        }
    }

    /// Indents the selected lines when the selection spans lines; otherwise inserts a
    /// tab or, in space-indented files, spaces up to the next indent stop.
    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        let text = string as NSString
        if selection.length > 0, text.substring(with: selection).contains(where: \.isNewline) {
            indentLines(sender)
            return
        }
        let indentation = indentation
        guard !indentation.usesTabs else {
            super.insertTab(sender)
            return
        }
        let column = visualColumn(at: selection.location)
        let count = indentation.width - column % indentation.width
        insertText(String(repeating: " ", count: count), replacementRange: selection)
    }

    override func insertBacktab(_ sender: Any?) {
        outdentLines(sender)
    }

    /// Columns from the start of the line to `offset`, with tabs expanded.
    func visualColumn(at offset: Int) -> Int {
        let text = string as NSString
        let lineStart = text.lineRange(for: NSRange(location: min(offset, text.length), length: 0)).location
        var column = 0
        for index in lineStart..<min(offset, text.length) {
            column += text.character(at: index) == 0x09 ? Self.tabWidth - column % Self.tabWidth : 1
        }
        return column
    }

    // MARK: Line commands

    @objc func indentLines(_ sender: Any?) {
        let unit = indentation.unitString
        editSelectedLines(actionName: "Indent") { lines in
            lines.map { $0.isEmpty ? nil : LineEdit(column: 0, remove: 0, insert: unit) }
        }
    }

    @objc func outdentLines(_ sender: Any?) {
        let width = indentation.width
        editSelectedLines(actionName: "Outdent") { lines in
            lines.map { line in
                let characters = Array(line.utf16.prefix(width))
                let remove = characters.first == 0x09 ? 1 : characters.prefix { $0 == 0x20 }.count
                return remove > 0 ? LineEdit(column: 0, remove: remove, insert: "") : nil
            }
        }
    }

    /// Comments out the selected lines, or uncomments them if they all are already.
    @objc func toggleComment(_ sender: Any?) {
        if let token = language?.lineComment {
            toggleLineComment(token)
        } else if let block = language?.blockComment {
            toggleBlockComment(open: block.open, close: block.close)
        } else {
            NSSound.beep()
        }
    }

    private func toggleLineComment(_ token: String) {
        let tokenLength = (token as NSString).length
        editSelectedLines(actionName: "Toggle Comment") { lines in
            let nonBlank = lines.filter { !$0.allSatisfy(\.isWhitespace) }
            guard !nonBlank.isEmpty else { return lines.map { _ in nil } }
            let isCommented = nonBlank.allSatisfy { Self.trimmingIndent($0).hasPrefix(token) }
            let column = nonBlank.map { Self.indentLength($0) }.min() ?? 0
            return lines.map { line in
                guard !line.allSatisfy(\.isWhitespace) else { return nil }
                if isCommented {
                    let start = Self.indentLength(line)
                    let rest = (line as NSString).substring(from: start + tokenLength)
                    return LineEdit(column: start, remove: tokenLength + (rest.hasPrefix(" ") ? 1 : 0), insert: "")
                }
                return LineEdit(column: column, remove: 0, insert: token + " ")
            }
        }
    }

    private func toggleBlockComment(open: String, close: String) {
        editSelectedLines(actionName: "Toggle Comment") { lines in
            let nonBlank = lines.filter { !$0.allSatisfy(\.isWhitespace) }
            guard !nonBlank.isEmpty else { return lines.map { _ in nil } }
            let isCommented = nonBlank.allSatisfy {
                let body = Self.trimmingIndent($0).trimmingCharacters(in: .whitespaces)
                return body.hasPrefix(open) && body.hasSuffix(close)
            }
            return lines.map { line in
                guard !line.allSatisfy(\.isWhitespace) else { return nil }
                let start = Self.indentLength(line)
                let body = (line as NSString).substring(from: start)
                let replacement: String
                if isCommented {
                    var inner = body.trimmingCharacters(in: .whitespaces)
                    inner = String(inner.dropFirst(open.count).dropLast(close.count))
                    replacement = inner.trimmingCharacters(in: .whitespaces)
                } else {
                    replacement = "\(open) \(body) \(close)"
                }
                return LineEdit(column: start, remove: (body as NSString).length, insert: replacement)
            }
        }
    }

    @objc func moveLinesUp(_ sender: Any?) {
        let text = string as NSString
        let block = selectedLinesRange()
        guard block.location > 0 else { return NSSound.beep() }
        let previous = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
        let (blockBody, ownBreak) = Self.splitLineBreak(text.substring(with: block))
        let (previousBody, previousOwnBreak) = Self.splitLineBreak(text.substring(with: previous))
        // The block is the last line, without a break: it takes the previous line's.
        let blockBreak = ownBreak.isEmpty ? previousOwnBreak : ownBreak
        let previousBreak = ownBreak.isEmpty ? "" : previousOwnBreak
        let replacement = blockBody + blockBreak + previousBody + previousBreak
        let selection = selectedRange()
        applyEdit(in: NSRange(location: previous.location, length: previous.length + block.length),
                  with: replacement, actionName: "Move Line Up")
        setSelectedRange(NSRange(location: selection.location - previous.length, length: selection.length))
        scrollRangeToVisible(selectedRange())
    }

    @objc func moveLinesDown(_ sender: Any?) {
        let text = string as NSString
        let block = selectedLinesRange()
        let blockEnd = NSMaxRange(block)
        guard blockEnd < text.length else { return NSSound.beep() }
        let next = text.lineRange(for: NSRange(location: blockEnd, length: 0))
        let (blockBody, ownBreak) = Self.splitLineBreak(text.substring(with: block))
        let (nextBody, nextOwnBreak) = Self.splitLineBreak(text.substring(with: next))
        // The next line is the last, without a break: it takes the block's.
        let nextBreak = nextOwnBreak.isEmpty ? ownBreak : nextOwnBreak
        let blockBreak = nextOwnBreak.isEmpty ? "" : ownBreak
        let moved = nextBody + nextBreak
        let replacement = moved + blockBody + blockBreak
        let selection = selectedRange()
        applyEdit(in: NSRange(location: block.location, length: block.length + next.length),
                  with: replacement, actionName: "Move Line Down")
        setSelectedRange(NSRange(location: selection.location + (moved as NSString).length, length: selection.length))
        scrollRangeToVisible(selectedRange())
    }

    @objc func duplicateLinesDown(_ sender: Any?) {
        let text = string as NSString
        let block = selectedLinesRange()
        let (body, lineBreak) = Self.splitLineBreak(text.substring(with: block))
        // After the block; a last line without a break gets one first.
        let insertion = lineBreak.isEmpty ? lineEnding + body : body + lineBreak
        let selection = selectedRange()
        applyEdit(in: NSRange(location: NSMaxRange(block), length: 0), with: insertion, actionName: "Duplicate Line")
        let shift = lineBreak.isEmpty ? (lineEnding as NSString).length + (body as NSString).length : block.length
        setSelectedRange(NSRange(location: selection.location + shift, length: selection.length))
        scrollRangeToVisible(selectedRange())
    }

    @objc func duplicateLinesUp(_ sender: Any?) {
        let text = string as NSString
        let block = selectedLinesRange()
        let (body, lineBreak) = Self.splitLineBreak(text.substring(with: block))
        let selection = selectedRange()
        applyEdit(in: NSRange(location: block.location, length: 0),
                  with: body + (lineBreak.isEmpty ? lineEnding : lineBreak), actionName: "Duplicate Line")
        // The selection stays on the upper copy.
        setSelectedRange(selection)
    }

    // MARK: Go to line

    /// Puts the cursor at `location` and scrolls it to the middle of the view.
    func placeCursor(at location: Int) {
        setSelectedRange(NSRange(location: min(location, (string as NSString).length), length: 0))
        centerSelection()
    }

    /// Selects `range` and scrolls it into the middle of the view, with the find bounce.
    func reveal(_ range: NSRange) {
        let length = (string as NSString).length
        let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
        setSelectedRange(clamped)
        centerSelection()
        if clamped.length > 0 { showFindIndicator(for: clamped) }
    }

    private func centerSelection() {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let scrollView = enclosingScrollView,
              let location = contentManager.location(layoutManager.documentRange.location, offsetBy: selectedRange().location),
              let range = NSTextRange(location: layoutManager.documentRange.location, end: location) else {
            scrollRangeToVisible(selectedRange())
            return
        }
        layoutManager.ensureLayout(for: range)
        guard let fragment = layoutManager.textLayoutFragment(for: location) else {
            scrollRangeToVisible(selectedRange())
            return
        }
        let visibleHeight = scrollView.contentView.bounds.height
        let y = fragment.layoutFragmentFrame.midY + textContainerOrigin.y - visibleHeight / 2
        let maxY = max(0, frame.height - visibleHeight)
        scroll(NSPoint(x: 0, y: min(max(0, y), maxY)))
        // Sideways too, for long lines when wrapping is off.
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Helpers

    struct LineEdit {
        /// UTF-16 offset in the line where the change starts.
        var column: Int
        var remove: Int
        var insert: String
    }

    /// Whole lines the selection touches. A selection that ends right after a line
    /// break leaves the next line out, as in other editors.
    func selectedLinesRange() -> NSRange {
        let text = string as NSString
        var selection = selectedRange()
        if selection.length > 0, NSMaxRange(selection) <= text.length,
           Self.isLineBreak(text.character(at: NSMaxRange(selection) - 1)) {
            selection.length -= 1
        }
        return text.lineRange(for: selection)
    }

    /// Replaces the selected lines in one undoable step. `transform` gets each line
    /// (without its break) and returns one change per line, or `nil` to leave it.
    /// The selection follows the changes.
    private func editSelectedLines(actionName: String, _ transform: ([String]) -> [LineEdit?]) {
        let text = string as NSString
        let block = selectedLinesRange()

        var lines: [(start: Int, contents: String, lineBreak: String)] = []
        var location = block.location
        repeat {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            lines.append((
                start,
                text.substring(with: NSRange(location: start, length: contentsEnd - start)),
                text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
            ))
            location = end
        } while location < NSMaxRange(block)

        let edits = transform(lines.map(\.contents))
        guard edits.contains(where: { $0 != nil }) else { return }

        var replacement = ""
        var applied: [(position: Int, remove: Int, insert: Int)] = []
        for (line, edit) in zip(lines, edits) {
            guard let edit else {
                replacement += line.contents + line.lineBreak
                continue
            }
            let contents = line.contents as NSString
            let column = min(edit.column, contents.length)
            let remove = min(edit.remove, contents.length - column)
            replacement += contents.substring(to: column) + edit.insert
                + contents.substring(from: column + remove) + line.lineBreak
            applied.append((line.start + column, remove, (edit.insert as NSString).length))
        }

        let selection = selectedRange()
        func map(_ position: Int, isSelectionStart: Bool) -> Int {
            var shift = 0
            for edit in applied {
                if position > edit.position + edit.remove
                    || (position == edit.position + edit.remove && !(isSelectionStart && selection.length > 0 && edit.remove == 0)) {
                    shift += edit.insert - edit.remove
                } else if position > edit.position {
                    return edit.position + shift + min(position - edit.position, edit.insert)
                }
            }
            return position + shift
        }
        let start = map(selection.location, isSelectionStart: true)
        let end = selection.length > 0 ? map(NSMaxRange(selection), isSelectionStart: false) : start

        applyEdit(in: block, with: replacement, actionName: actionName)
        setSelectedRange(NSRange(location: start, length: max(0, end - start)))
    }

    /// One undoable replacement.
    func applyEdit(in range: NSRange, with replacement: String, actionName: String) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        replaceCharacters(in: range, with: replacement)
        didChangeText()
        undoManager?.setActionName(actionName)
    }

    private static func isIndentCharacter(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private static func isLineBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
    }

    private static func closer(for opener: unichar) -> unichar? {
        switch opener {
        case 0x7B /* { */: 0x7D /* } */
        case 0x5B /* [ */: 0x5D /* ] */
        case 0x28 /* ( */: 0x29 /* ) */
        default: nil
        }
    }

    /// UTF-16 length of the line's leading spaces and tabs.
    private static func indentLength(_ line: String) -> Int {
        line.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
    }

    private static func trimmingIndent(_ line: String) -> String {
        (line as NSString).substring(from: indentLength(line))
    }

    /// Splits off a trailing `\n`, `\r\n` or `\r`.
    private static func splitLineBreak(_ line: String) -> (body: String, lineBreak: String) {
        // "\r\n" is one Character in Swift, so dropping the last Character removes either kind.
        for lineBreak in ["\r\n", "\n", "\r"] where line.hasSuffix(lineBreak) {
            return (String(line.dropLast()), lineBreak)
        }
        return (line, "")
    }
}
