import AppKit

/// Works out which characters of a text need their color set for it to match its
/// tokens.
///
/// TextKit 2 throws away the layout of every paragraph whose attributes are set,
/// even to the value they have. Setting every color again after each edit put the
/// lines above the view back to estimated heights, so the text under the scroll
/// position moved, and the top lines of the view could be left undrawn. Setting only
/// what differs, usually the token being typed, leaves the rest of the layout alone.
nonisolated enum SyntaxColoring {
    /// A range of the text and the color it has, or should have.
    struct Run {
        let range: NSRange
        let color: NSColor
    }

    /// The ranges of `text` whose foreground color isn't the one `tokens` give them,
    /// in order, each with the color to set. Text outside every token is `plain`;
    /// where tokens overlap, the later one wins; a token past the end of the text
    /// (from an older snapshot of it) is left out.
    static func changes(
        in text: NSAttributedString,
        tokens: [Run],
        plain: NSColor
    ) -> [Run] {
        let length = text.length
        guard length > 0 else { return [] }

        // The color each UTF-16 unit should have, as an index into `palette`.
        var palette = [plain]
        var paletteIndex = [ObjectIdentifier(plain): UInt16(0)]
        var wanted = [UInt16](repeating: 0, count: length)
        for token in tokens
        where token.range.location >= 0 && NSMaxRange(token.range) <= length {
            let id = ObjectIdentifier(token.color)
            let index: UInt16
            if let known = paletteIndex[id] {
                index = known
            } else {
                index = UInt16(palette.count)
                palette.append(token.color)
                paletteIndex[id] = index
            }
            for unit in token.range.location..<NSMaxRange(token.range) {
                wanted[unit] = index
            }
        }

        var changes: [Run] = []
        let whole = NSRange(location: 0, length: length)
        text.enumerateAttribute(
            .foregroundColor,
            in: whole,
            options: .longestEffectiveRangeNotRequired
        ) { value, run, _ in
            let current = value as? NSColor
            let end = NSMaxRange(run)
            var start = run.location
            while start < end {
                let index = wanted[start]
                var stop = start + 1
                while stop < end, wanted[stop] == index { stop += 1 }
                let color = palette[Int(index)]
                if current !== color, current != color {
                    if let last = changes.last, last.color === color,
                        NSMaxRange(last.range) == start
                    {
                        changes[changes.count - 1] = Run(
                            range: NSRange(
                                location: last.range.location,
                                length: stop - last.range.location
                            ),
                            color: color
                        )
                    } else {
                        changes.append(
                            Run(
                                range: NSRange(
                                    location: start,
                                    length: stop - start
                                ),
                                color: color
                            )
                        )
                    }
                }
                start = stop
            }
        }
        return changes
    }
}
