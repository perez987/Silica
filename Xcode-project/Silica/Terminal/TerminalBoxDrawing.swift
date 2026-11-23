import CoreGraphics

/// Draws the characters that programs build frames, bars and prompts from: box
/// lines, blocks and the Powerline arrows.
///
/// A font's glyphs for these are made for the font's own line height, so in a
/// terminal's cells they leave gaps between rows or between neighbors. Drawn to
/// the cell's exact pixels instead, lines join and blocks tile.
nonisolated enum TerminalBoxDrawing {
    /// Draws `codepoint` in `cell` with the context's fill and stroke colors, in a
    /// context flipped like the terminal view (y grows downwards). Returns `false`
    /// for a character it has no drawing for, which is left to the font.
    static func draw(
        _ codepoint: UInt32,
        in cell: CGRect,
        scale: CGFloat,
        context: CGContext
    ) -> Bool {
        switch codepoint {
        case 0x256D...0x2570:
            drawRoundedCorner(
                codepoint,
                in: Grid(cell, scale: scale),
                context: context
            )
        case 0x2500...0x257F:
            let arms = boxArms[Int(codepoint - 0x2500)]
            guard arms != 0 else { return false }
            drawLines(arms, in: Grid(cell, scale: scale), context: context)
        case 0x2580...0x259F:
            drawBlock(codepoint, in: Grid(cell, scale: scale), context: context)
        case 0xE0B0...0xE0B3:
            drawPowerline(codepoint, in: cell, scale: scale, context: context)
        default:
            return false
        }
        return true
    }

    /// Whether `draw` has a drawing for the character, to keep it out of text runs.
    static func draws(_ codepoint: UInt32) -> Bool {
        switch codepoint {
        case 0x256D...0x2570, 0x2580...0x259F, 0xE0B0...0xE0B3: true
        case 0x2500...0x257F: boxArms[Int(codepoint - 0x2500)] != 0
        default: false
        }
    }

    /// A cell measured in whole pixels, so that edges land on pixel boundaries.
    private struct Grid {
        let cell: CGRect
        let scale: CGFloat
        let width: Int
        let height: Int
        /// Thickness of a light line, in pixels; a heavy one is twice it.
        let light: Int

        init(_ cell: CGRect, scale: CGFloat) {
            self.cell = cell
            self.scale = scale
            width = max(Int((cell.width * scale).rounded()), 1)
            height = max(Int((cell.height * scale).rounded()), 1)
            light = max(Int((cell.height * scale / 16).rounded()), 1)
        }

        /// The rectangle between pixel columns `x0..<x1` and pixel rows `y0..<y1`.
        func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> CGRect {
            CGRect(
                x: cell.minX + CGFloat(x0) / scale,
                y: cell.minY + CGFloat(y0) / scale,
                width: CGFloat(x1 - x0) / scale,
                height: CGFloat(y1 - y0) / scale
            )
        }

        /// Where a line of `thickness` pixels through the middle of `length` begins.
        /// Light and heavy lines share a center this way.
        func start(_ thickness: Int, in length: Int) -> Int {
            (length - thickness) / 2
        }
    }

    // MARK: Lines

    /// The arms of each character from U+2500 to U+257F: up, right, down and left,
    /// each none (0), light (1) or heavy (2). `----` is one that isn't made of
    /// such arms (dashed, double and diagonal lines) or that is drawn another way.
    private static let boxArms: [UInt8] = {
        let table = """
            0101 0202 1010 2020 ---- ---- ---- ---- ---- ---- ---- ---- 0110 0210 0120 0220
            0011 0012 0021 0022 1100 1200 2100 2200 1001 1002 2001 2002 1110 1210 2110 1120
            2120 2210 1220 2220 1011 1012 2011 1021 2021 2012 1022 2022 0111 0112 0211 0212
            0121 0122 0221 0222 1101 1102 1201 1202 2101 2102 2201 2202 1111 1112 1211 1212
            2111 1121 2121 2112 2211 1122 1221 2212 1222 2122 2221 2222 ---- ---- ---- ----
            ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ----
            ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ----
            ---- ---- ---- ---- 0001 1000 0100 0010 0002 2000 0200 0020 0201 1020 0102 2010
            """
        var arms = table.split(whereSeparator: \.isWhitespace).map {
            entry -> UInt8 in
            // Two bits an arm: up, right, down, left from the high bits down.
            entry.utf8.reduce(0) { packed, digit in
                digit == UInt8(ascii: "-")
                    ? 0 : packed << 2 | (digit - UInt8(ascii: "0"))
            }
        }
        arms += [UInt8](repeating: 0, count: max(128 - arms.count, 0))
        return arms
    }()

    private static func drawLines(
        _ arms: UInt8,
        in grid: Grid,
        context: CGContext
    ) {
        let up = Int(arms >> 6 & 3) * grid.light
        let right = Int(arms >> 4 & 3) * grid.light
        let down = Int(arms >> 2 & 3) * grid.light
        let left = Int(arms & 3) * grid.light
        // Each arm runs from its edge to the far side of the arms it crosses in
        // the middle, so corners and joints come out square.
        let across = max(up, down)
        let along = max(left, right)
        let middleX = grid.start(across, in: grid.width)
        let middleY = grid.start(along, in: grid.height)
        if left > 0 {
            let y = grid.start(left, in: grid.height)
            context.fill(
                grid.rect(
                    0,
                    y,
                    across > 0 ? middleX + across : grid.width / 2,
                    y + left
                )
            )
        }
        if right > 0 {
            let y = grid.start(right, in: grid.height)
            context.fill(
                grid.rect(
                    across > 0 ? middleX : grid.width / 2,
                    y,
                    grid.width,
                    y + right
                )
            )
        }
        if up > 0 {
            let x = grid.start(up, in: grid.width)
            context.fill(
                grid.rect(
                    x,
                    0,
                    x + up,
                    along > 0 ? middleY + along : grid.height / 2
                )
            )
        }
        if down > 0 {
            let x = grid.start(down, in: grid.width)
            context.fill(
                grid.rect(
                    x,
                    along > 0 ? middleY : grid.height / 2,
                    x + down,
                    grid.height
                )
            )
        }
    }

    /// ╭ ╮ ╯ ╰: a light line that turns through a quarter circle.
    private static func drawRoundedCorner(
        _ codepoint: UInt32,
        in grid: Grid,
        context: CGContext
    ) {
        let cell = grid.cell
        let thickness = CGFloat(grid.light) / grid.scale
        // The same centers as the straight lines these meet in the cells around.
        let center = CGPoint(
            x: cell.minX + CGFloat(grid.start(grid.light, in: grid.width))
                / grid.scale + thickness / 2,
            y: cell.minY + CGFloat(grid.start(grid.light, in: grid.height))
                / grid.scale + thickness / 2
        )
        // Which way the two arms go: ╭ down and right, ╮ down and left, ╯ up and
        // left, ╰ up and right.
        let goesDown = codepoint == 0x256D || codepoint == 0x256E
        let goesRight = codepoint == 0x256D || codepoint == 0x2570
        let verticalEnd = CGPoint(
            x: center.x,
            y: goesDown ? cell.maxY : cell.minY
        )
        let horizontalEnd = CGPoint(
            x: goesRight ? cell.maxX : cell.minX,
            y: center.y
        )
        let radius = min(
            abs(horizontalEnd.x - center.x),
            abs(verticalEnd.y - center.y)
        )

        context.saveGState()
        context.setLineWidth(thickness)
        context.move(to: verticalEnd)
        context.addArc(
            tangent1End: center,
            tangent2End: horizontalEnd,
            radius: radius
        )
        context.addLine(to: horizontalEnd)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Blocks

    private static func drawBlock(
        _ codepoint: UInt32,
        in grid: Grid,
        context: CGContext
    ) {
        let width = grid.width
        let height = grid.height
        func eighths(_ count: Int, of length: Int) -> Int {
            Int((Double(length) * Double(count) / 8).rounded())
        }
        switch codepoint {
        case 0x2580:  // ▀ upper half
            context.fill(grid.rect(0, 0, width, height / 2))
        case 0x2581...0x2588:  // ▁ to █: the lower one to eight eighths
            context.fill(
                grid.rect(
                    0,
                    height - eighths(Int(codepoint - 0x2580), of: height),
                    width,
                    height
                )
            )
        case 0x2589...0x258F:  // ▉ to ▏: the left seven to one eighths
            context.fill(
                grid.rect(
                    0,
                    0,
                    eighths(Int(0x2590 - codepoint), of: width),
                    height
                )
            )
        case 0x2590:  // ▐ right half
            context.fill(grid.rect(width / 2, 0, width, height))
        case 0x2591...0x2593:  // ░ ▒ ▓: a quarter, a half and three quarters dark
            context.saveGState()
            context.setAlpha(CGFloat(codepoint - 0x2590) / 4)
            context.fill(grid.cell)
            context.restoreGState()
        case 0x2594:  // ▔ upper eighth
            context.fill(grid.rect(0, 0, width, eighths(1, of: height)))
        case 0x2595:  // ▕ right eighth
            context.fill(
                grid.rect(width - eighths(1, of: width), 0, width, height)
            )
        default:
            // ▖ to ▟: quadrants. One bit each: upper left, upper right, lower left,
            // lower right.
            let quadrants: [UInt8] = [
                0b0010, 0b0001, 0b1000, 0b1011, 0b1001, 0b1110, 0b1101, 0b0100,
                0b0110, 0b0111,
            ]
            let index = Int(codepoint) - 0x2596
            guard quadrants.indices.contains(index) else { return }
            let bits = quadrants[index]
            let middleX = width / 2
            let middleY = height / 2
            if bits & 0b1000 != 0 {
                context.fill(grid.rect(0, 0, middleX, middleY))
            }
            if bits & 0b0100 != 0 {
                context.fill(grid.rect(middleX, 0, width, middleY))
            }
            if bits & 0b0010 != 0 {
                context.fill(grid.rect(0, middleY, middleX, height))
            }
            if bits & 0b0001 != 0 {
                context.fill(grid.rect(middleX, middleY, width, height))
            }
        }
    }

    // MARK: Powerline

    /// The arrows prompts put between their segments: solid (U+E0B0, U+E0B2) and
    /// outlined (U+E0B1, U+E0B3), pointing right and left. They're private-use
    /// characters that only patched fonts have.
    private static func drawPowerline(
        _ codepoint: UInt32,
        in cell: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        let pointsRight = codepoint == 0xE0B0 || codepoint == 0xE0B1
        let base = pointsRight ? cell.minX : cell.maxX
        let tip = CGPoint(x: pointsRight ? cell.maxX : cell.minX, y: cell.midY)
        context.move(to: CGPoint(x: base, y: cell.minY))
        context.addLine(to: tip)
        context.addLine(to: CGPoint(x: base, y: cell.maxY))
        if codepoint == 0xE0B0 || codepoint == 0xE0B2 {
            context.fillPath()
        } else {
            context.saveGState()
            context.setLineWidth(
                max((cell.height * scale / 16).rounded(), 1) / scale
            )
            context.strokePath()
            context.restoreGState()
        }
    }
}
