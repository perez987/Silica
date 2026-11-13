import AppKit

/// A syntax highlighting color scheme, chosen in Settings. Each theme has a light and
/// a dark palette, picked by the window's appearance.
///
/// Only token colors change: plain text stays the system label color and the editor
/// keeps its glass card, so comment grays that a theme designed for an opaque, near-black
/// background would lose are lifted a little in the dark palettes.
nonisolated enum SyntaxTheme: String, CaseIterable, Identifiable, Sendable {
    case one, github, xcode, solarized, catppuccin, gruvbox, tokyoNight, rosePine, dracula

    static let `default` = SyntaxTheme.one

    var id: Self { self }

    var name: String {
        switch self {
        case .one: "Atom One"
        case .github: "GitHub"
        case .xcode: "Xcode"
        case .solarized: "Solarized"
        case .catppuccin: "Catppuccin"
        case .gruvbox: "Gruvbox"
        case .tokyoNight: "Tokyo Night"
        case .rosePine: "Rosé Pine"
        case .dracula: "Dracula"
        }
    }

    // MARK: Editor chrome (the same in every theme)

    static let plain = NSColor.labelColor

    /// Gutter numbers: solid colors rather than translucent label colors, which
    /// lose contrast on the glass card.
    static let lineNumber = dynamic(light: 0x9A9AA0, dark: 0x9C9CA2)
    static let currentLineNumber = dynamic(light: 0x3C3C43, dark: 0xF2F2F7)

    /// Indent guides: a faint line that reads on the glass card in both appearances.
    static let indentGuide = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.10)
    }

    // MARK: Token colors

    /// A color that follows the appearance it's drawn in.
    func color(for kind: TokenKind) -> NSColor {
        Self.colors[self]![kind]!
    }

    /// The light/dark hex pair for a token kind, shared with the Markdown preview's CSS.
    func hexPair(for kind: TokenKind) -> (light: UInt32, dark: UInt32) {
        (palettes.light[kind], palettes.dark[kind])
    }

    /// Link color in the Markdown preview.
    var linkPair: (light: UInt32, dark: UInt32) {
        (palettes.light.link, palettes.dark.link)
    }

    private struct Palette {
        var keyword: UInt32
        var type: UInt32
        var string: UInt32
        var number: UInt32
        var comment: UInt32
        var function: UInt32
        /// Properties, tags, variables and Markdown headings.
        var variable: UInt32
        var link: UInt32
        /// Added and removed lines in a diff.
        var inserted: UInt32
        var deleted: UInt32
        var attribute: UInt32? = nil
        var preprocessor: UInt32? = nil

        subscript(kind: TokenKind) -> UInt32 {
            switch kind {
            case .keyword: keyword
            case .preprocessor: preprocessor ?? keyword
            case .type: type
            case .string: string
            case .number: number
            case .attribute: attribute ?? number
            case .comment: comment
            case .function: function
            case .property, .tag, .variable, .heading: variable
            case .link: link
            case .inserted: inserted
            case .deleted: deleted
            }
        }
    }

    private var palettes: (light: Palette, dark: Palette) {
        switch self {
        case .one:
            // Atom's One Light / One Dark. One Dark's comment gray (5C6370) nearly
            // vanishes on the glass card, so dark mode uses a lighter shade of it.
            (
                Palette(keyword: 0xA626A4, type: 0xC18401, string: 0x50A14F, number: 0x986801,
                        comment: 0xA0A1A7, function: 0x4078F2, variable: 0xE45649, link: 0x0184BC,
                        inserted: 0x50A14F, deleted: 0xE45649),
                Palette(keyword: 0xC678DD, type: 0xE5C07B, string: 0x98C379, number: 0xD19A66,
                        comment: 0x9DA5B3, function: 0x61AFEF, variable: 0xE06C75, link: 0x56B6C2,
                        inserted: 0x98C379, deleted: 0xE06C75)
            )
        case .github:
            // GitHub Light / GitHub Dark (Primer).
            (
                Palette(keyword: 0xCF222E, type: 0x953800, string: 0x0A3069, number: 0x0550AE,
                        comment: 0x6E7781, function: 0x8250DF, variable: 0x116329, link: 0x0969DA,
                        inserted: 0x1A7F37, deleted: 0xCF222E),
                Palette(keyword: 0xFF7B72, type: 0xFFA657, string: 0xA5D6FF, number: 0x79C0FF,
                        comment: 0x8B949E, function: 0xD2A8FF, variable: 0x7EE787, link: 0x58A6FF,
                        inserted: 0x3FB950, deleted: 0xF85149)
            )
        case .xcode:
            // Xcode's Standard preset (Xcode 27, default tints), sampled from the editor:
            // it's computed by Xcode rather than shipped as an .xccolortheme file. Functions
            // use the project-symbol teal; variables, properties and tags the declaration blue.
            // Xcode has no diff colors of its own, so those are the system green and red.
            (
                Palette(keyword: 0xAC3261, type: 0x853CC1, string: 0xB33421, number: 0x286DAB,
                        comment: 0x606578, function: 0x265C52, variable: 0x2C7290, link: 0x1146B3,
                        inserted: 0x248A3D, deleted: 0xD70015,
                        attribute: 0xAC3261, preprocessor: 0x805F24),
                Palette(keyword: 0xED80A8, type: 0xC793F7, string: 0xEF8772, number: 0xDE9F2E,
                        comment: 0xA2AAC4, function: 0x479F92, variable: 0x4CC1F5, link: 0x5B8EDD,
                        inserted: 0x30D158, deleted: 0xFF453A,
                        attribute: 0xED80A8, preprocessor: 0xDE9F2E)
            )
        case .solarized:
            // Solarized's accents are shared by both modes; only the comment tone differs.
            (
                Palette(keyword: 0x859900, type: 0xB58900, string: 0x2AA198, number: 0xD33682,
                        comment: 0x93A1A1, function: 0x268BD2, variable: 0xCB4B16, link: 0x6C71C4,
                        inserted: 0x859900, deleted: 0xDC322F,
                        preprocessor: 0xCB4B16),
                Palette(keyword: 0x859900, type: 0xB58900, string: 0x2AA198, number: 0xD33682,
                        comment: 0x839496, function: 0x268BD2, variable: 0xCB4B16, link: 0x6C71C4,
                        inserted: 0x859900, deleted: 0xDC322F,
                        preprocessor: 0xCB4B16)
            )
        case .catppuccin:
            // Catppuccin Latte / Mocha.
            (
                Palette(keyword: 0x8839EF, type: 0xDF8E1D, string: 0x40A02B, number: 0xFE640B,
                        comment: 0x7C7F93, function: 0x1E66F5, variable: 0xE64553, link: 0x209FB5,
                        inserted: 0x40A02B, deleted: 0xD20F39,
                        attribute: 0xDF8E1D, preprocessor: 0xEA76CB),
                Palette(keyword: 0xCBA6F7, type: 0xF9E2AF, string: 0xA6E3A1, number: 0xFAB387,
                        comment: 0x9399B2, function: 0x89B4FA, variable: 0xEBA0AC, link: 0x74C7EC,
                        inserted: 0xA6E3A1, deleted: 0xF38BA8,
                        attribute: 0xF9E2AF, preprocessor: 0xF5C2E7)
            )
        case .gruvbox:
            // Gruvbox Light / Dark.
            (
                Palette(keyword: 0x9D0006, type: 0xB57614, string: 0x79740E, number: 0x8F3F71,
                        comment: 0x928374, function: 0x427B58, variable: 0x076678, link: 0x076678,
                        inserted: 0x79740E, deleted: 0x9D0006,
                        attribute: 0xAF3A03, preprocessor: 0xAF3A03),
                Palette(keyword: 0xFB4934, type: 0xFABD2F, string: 0xB8BB26, number: 0xD3869B,
                        comment: 0xA89984, function: 0x8EC07C, variable: 0x83A598, link: 0x83A598,
                        inserted: 0xB8BB26, deleted: 0xFB4934,
                        attribute: 0xFE8019, preprocessor: 0xFE8019)
            )
        case .tokyoNight:
            // Tokyo Night Day / Night. Night's comment (565F89) is lifted for the glass.
            (
                Palette(keyword: 0x9854F1, type: 0x007197, string: 0x587539, number: 0xB15C00,
                        comment: 0x848CB5, function: 0x2E7DE9, variable: 0xF52A65, link: 0x007197,
                        inserted: 0x587539, deleted: 0xF52A65,
                        attribute: 0x8C6C3E),
                Palette(keyword: 0xBB9AF7, type: 0x2AC3DE, string: 0x9ECE6A, number: 0xFF9E64,
                        comment: 0x8089B3, function: 0x7AA2F7, variable: 0xF7768E, link: 0x7DCFFF,
                        inserted: 0x9ECE6A, deleted: 0xF7768E,
                        attribute: 0xE0AF68)
            )
        case .rosePine:
            // Rosé Pine Dawn / Rosé Pine. The main variant's pine (31748F) is too dark for
            // the glass card, so it borrows Moon's (3E8FB0); its comment uses "subtle".
            // Added lines use pine, the palette's terminal green, since foam already colors
            // a diff's headers.
            (
                Palette(keyword: 0x286983, type: 0x56949F, string: 0xEA9D34, number: 0xB4637A,
                        comment: 0x9893A5, function: 0xD7827E, variable: 0x907AA9, link: 0x56949F,
                        inserted: 0x286983, deleted: 0xB4637A),
                Palette(keyword: 0x3E8FB0, type: 0x9CCFD8, string: 0xF6C177, number: 0xEB6F92,
                        comment: 0x908CAA, function: 0xEBBCBA, variable: 0xC4A7E7, link: 0x9CCFD8,
                        inserted: 0x3E8FB0, deleted: 0xEB6F92)
            )
        case .dracula:
            // Alucard (Dracula's official light theme) / Dracula. Dracula's comment
            // (6272A4) is lifted for the glass card.
            (
                Palette(keyword: 0xA3144D, type: 0x036A96, string: 0x846E15, number: 0x644AC9,
                        comment: 0x6C664B, function: 0x14710A, variable: 0xA34D14, link: 0x036A96,
                        inserted: 0x14710A, deleted: 0xCB3A2A),
                Palette(keyword: 0xFF79C6, type: 0x8BE9FD, string: 0xF1FA8C, number: 0xBD93F9,
                        comment: 0x8A96C4, function: 0x50FA7B, variable: 0xFFB86C, link: 0x8BE9FD,
                        inserted: 0x50FA7B, deleted: 0xFF5555)
            )
        }
    }

    private static let colors: [SyntaxTheme: [TokenKind: NSColor]] = Dictionary(
        uniqueKeysWithValues: allCases.map { theme in
            (theme, Dictionary(uniqueKeysWithValues: TokenKind.allCases.map { kind in
                let pair = theme.hexPair(for: kind)
                return (kind, dynamic(light: pair.light, dark: pair.dark))
            }))
        }
    )

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
