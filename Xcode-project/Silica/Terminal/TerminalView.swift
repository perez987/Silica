import AppKit
import CoreText
import GhosttyVt

/// Draws a terminal's grid of cells and takes its keyboard and mouse input (the
/// input half is in TerminalView+Input.swift).
///
/// libghostty-vt keeps a "render state": a copy of what the screen shows, with the
/// rows that changed since the last look marked dirty. `refresh()` brings the copy
/// up to date and invalidates those rows; `draw(_:)` paints from the copy with Core
/// Text. The view has no background of its own, so the card's glass shows through.
final class TerminalView: NSView {
    private(set) weak var session: TerminalSession?

    // libghostty-vt objects, freed in `releaseTerminal()`.
    private var renderState: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    var keyEncoder: GhosttyKeyEncoder?
    var keyEvent: GhosttyKeyEvent?
    var mouseEncoder: GhosttyMouseEncoder?
    var mouseEvent: GhosttyMouseEvent?
    var selectionGesture: GhosttySelectionGesture?
    var selectionPress: GhosttySelectionGestureEvent?
    var selectionRelease: GhosttySelectionGestureEvent?
    var selectionDrag: GhosttySelectionGestureEvent?
    var selectionTick: GhosttySelectionGestureEvent?

    /// Room between the card's sides and the grid, and above it: none there, where
    /// the card's header already stands between the text and the edge.
    static let inset = CGSize(width: 10, height: 0)
    /// Room under the grid, which keeps the last row out of the card's round corners.
    static let bottomInset: CGFloat = 8

    // MARK: Metrics

    /// One cell, a whole number of pixels each way so that every column and row
    /// starts on a pixel.
    private(set) var cellSize = CGSize(width: 8, height: 16)
    private(set) var columns = 0
    private(set) var rows = 0
    /// Pixels per point of the screen the view is on.
    private(set) var scale: CGFloat = 2
    /// From the top of a cell down to the text's baseline.
    private var baseline: CGFloat = 12
    private var underlineOffset: CGFloat = 1
    private var strikethroughOffset: CGFloat = 4
    private var lineThickness: CGFloat = 1
    /// Regular, bold, italic and bold italic: bit 0 of the index is bold, bit 1 italic.
    private var fonts: [CTFont] = []
    /// Each font's glyph for a character; 0 where it has none.
    private var glyphCaches: [[UInt32: CGGlyph]] = []
    /// Laid-out text for what one glyph of the font can't show: characters from
    /// other fonts, emoji, and letters with combining marks.
    private var lineCache: [LineKey: CachedLine] = [:]
    private var isGridUpdateScheduled = false

    // MARK: State

    /// Where the cursor was at the last refresh, to repaint the rows it leaves and enters.
    private var cursor: Cursor?
    private var isCursorBlinkedOff = false
    private var blinkTimer: Timer?
    /// The view has the keyboard, in the key window.
    private(set) var isFocused = false
    /// Asked for the keyboard before it was in a window to take it in.
    private var wantsFocus = false

    // Input state, used by the extension in TerminalView+Input.swift.
    /// Text the input system committed during the key press being handled.
    var keyTextAccumulator: [String]?
    /// Text an input method is still composing, shown at the cursor.
    var markedText = "" {
        didSet { if markedText != oldValue { invalidateCursorRow() } }
    }
    var scrollRemainder: CGFloat = 0
    var autoscrollTimer: Timer?
    /// Where the pointer was last, for the autoscroll timer.
    var lastDragLocation = CGPoint.zero
    /// The button that went down while the running program had the mouse, so the
    /// program is the one told when it comes up.
    var pressedMouseButtons = 0
    /// The link under the pointer while ⌘ is held. It's underlined, and a click
    /// follows it.
    var hoveredLink: TerminalLink? {
        didSet {
            guard hoveredLink != oldValue else { return }
            for span in (oldValue?.spans ?? []) + (hoveredLink?.spans ?? []) {
                setNeedsDisplay(rowRect(span.row))
            }
            // The pointer turns into a hand over a link.
            window?.invalidateCursorRects(for: self)
            session?.linkDestination = hoveredLink?.destination
        }
    }
    /// The link a ⌘ click went down on; it's followed if the click comes up there.
    var pressedLink: TerminalLink?
    /// The cell `hoveredLink` was last looked for in.
    var probedLinkCell: (column: Int, row: Int)?

    // Buffers reused from one frame to the next.
    private var drawCells: [DrawCell] = []
    private var rowRanges: [(row: Int, cells: Range<Int>)] = []
    private var clusters: [String] = []
    private var runGlyphs: [CGGlyph] = []
    private var runPositions: [CGPoint] = []
    private var codepoints = [UInt32](repeating: 0, count: 32)

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        ghostty_render_state_new(nil, &renderState)
        ghostty_render_state_row_iterator_new(nil, &rowIterator)
        ghostty_render_state_row_cells_new(nil, &rowCells)
        ghostty_key_encoder_new(nil, &keyEncoder)
        ghostty_key_event_new(nil, &keyEvent)
        ghostty_mouse_encoder_new(nil, &mouseEncoder)
        ghostty_mouse_event_new(nil, &mouseEvent)
        ghostty_selection_gesture_new(nil, &selectionGesture)
        ghostty_selection_gesture_event_new(nil, &selectionPress, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS)
        ghostty_selection_gesture_event_new(nil, &selectionRelease, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE)
        ghostty_selection_gesture_event_new(nil, &selectionDrag, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG)
        ghostty_selection_gesture_event_new(nil, &selectionTick, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK)

        updateFont()
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel(String(localized: "Terminal"))
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(fontSettingsDidChange), name: .editorFontSizeDidChange, object: nil)
        center.addObserver(self, selector: #selector(fontSettingsDidChange), name: .editorSettingsDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Frees everything that refers to the session's terminal, which is about to
    /// go. The view draws nothing and takes no input afterwards.
    func releaseTerminal() {
        hoveredLink = nil
        pressedLink = nil
        probedLinkCell = nil
        blinkTimer?.invalidate()
        blinkTimer = nil
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        if let terminal = session?.terminal {
            ghostty_selection_gesture_free(selectionGesture, terminal)
        }
        selectionGesture = nil
        for event in [selectionPress, selectionRelease, selectionDrag, selectionTick] {
            ghostty_selection_gesture_event_free(event)
        }
        (selectionPress, selectionRelease, selectionDrag, selectionTick) = (nil, nil, nil, nil)
        ghostty_mouse_event_free(mouseEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(renderState)
        (mouseEvent, mouseEncoder, keyEvent, keyEncoder) = (nil, nil, nil, nil)
        (rowCells, rowIterator, renderState) = (nil, nil, nil)
        session = nil
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: Font and grid

    @objc private func fontSettingsDidChange() {
        updateFont()
    }

    /// Takes the editor's font and size, and measures a cell.
    private func updateFont() {
        let settings = EditorSettings.shared
        let regular = settings.editorFont(ofSize: settings.fontSize)
        func variant(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
            let descriptor = regular.fontDescriptor.withSymbolicTraits(regular.fontDescriptor.symbolicTraits.union(traits))
            return NSFont(descriptor: descriptor, size: regular.pointSize) ?? regular
        }
        fonts = [regular, variant(.bold), variant(.italic), variant([.bold, .italic])].map { $0 as CTFont }
        glyphCaches = Array(repeating: [:], count: fonts.count)
        lineCache.removeAll()

        scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        func pixelAligned(_ value: CGFloat, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> CGFloat {
            max((value * scale).rounded(rule), 1) / scale
        }
        let font = fonts[0]
        var character: UniChar = 0x4D // "M": every cell is as wide as the font's letters.
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = ascent + descent + CTFontGetLeading(font)
        cellSize = CGSize(
            width: pixelAligned(advance.width > 0 ? advance.width : regular.pointSize * 0.6),
            height: pixelAligned(lineHeight, .up)
        )
        baseline = pixelAligned((cellSize.height - ascent - descent) / 2 + ascent)
        lineThickness = pixelAligned(CTFontGetUnderlineThickness(font))
        underlineOffset = pixelAligned(-CTFontGetUnderlinePosition(font))
        strikethroughOffset = pixelAligned(CTFontGetXHeight(font) / 2)

        setGridNeedsUpdate()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setGridNeedsUpdate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else {
            updateFocus()
            return
        }
        center.addObserver(self, selector: #selector(windowKeyStateDidChange), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowKeyStateDidChange), name: NSWindow.didResignKeyNotification, object: window)
        if window.backingScaleFactor != scale { updateFont() }
        applyAppearance()
        setGridNeedsUpdate()
        if wantsFocus {
            wantsFocus = false
            window.makeFirstResponder(self)
        }
        updateFocus()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window, window.backingScaleFactor != scale { updateFont() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        session?.setAppearance(isDark: isDark)
        refresh()
        needsDisplay = true
    }

    /// The grid follows the view's size once per pass of the run loop: a window
    /// being resized sets the size many times over, and each new grid is a signal to
    /// the shell and a redraw by whatever runs in it.
    private func setGridNeedsUpdate() {
        guard !isGridUpdateScheduled else { return }
        isGridUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in self?.updateGrid() }
    }

    private func updateGrid() {
        isGridUpdateScheduled = false
        guard let session, window != nil else { return }
        let columns = Int((bounds.width - 2 * Self.inset.width) / cellSize.width)
        let rows = Int((bounds.height - Self.inset.height - Self.bottomInset) / cellSize.height)
        // Smaller than this and the card is still on its way in or out.
        guard columns >= 4, rows >= 1 else { return }
        self.columns = columns
        self.rows = rows
        session.resize(
            columns: columns,
            rows: rows,
            cellPixelSize: CGSize(width: cellSize.width * scale, height: cellSize.height * scale)
        )
        refresh()
        needsDisplay = true
    }

    // MARK: Geometry

    private func rowRect(_ row: Int) -> CGRect {
        CGRect(x: 0, y: Self.inset.height + CGFloat(row) * cellSize.height, width: bounds.width, height: cellSize.height)
    }

    func cellRect(column: Int, row: Int, span: Int = 1) -> CGRect {
        CGRect(
            x: Self.inset.width + CGFloat(column) * cellSize.width,
            y: Self.inset.height + CGFloat(row) * cellSize.height,
            width: CGFloat(span) * cellSize.width,
            height: cellSize.height
        )
    }

    /// The cell under a point in the view, pulled into the grid if it's outside.
    func cell(at point: CGPoint) -> (column: Int, row: Int) {
        let column = Int(((point.x - Self.inset.width) / cellSize.width).rounded(.down))
        let row = Int(((point.y - Self.inset.height) / cellSize.height).rounded(.down))
        return (min(max(column, 0), max(columns - 1, 0)), min(max(row, 0), max(rows - 1, 0)))
    }

    /// Where the cursor's cell is, for the input method's candidate window.
    var cursorRect: CGRect {
        guard let cursor else { return cellRect(column: 0, row: 0) }
        return cellRect(column: cursor.column, row: cursor.row)
    }

    // MARK: Refresh

    /// The terminal changed: what the shell printed, a scroll, a new selection.
    func terminalDidChange() {
        // A program in the middle of drawing a frame asked for the screen to wait.
        guard session?.isRenderHeld != true else { return }
        refresh()
    }

    private func refresh() {
        guard let terminal = session?.terminal, let renderState,
              ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else { return }

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        if dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL {
            needsDisplay = true
        } else if dirty == GHOSTTY_RENDER_STATE_DIRTY_PARTIAL,
                  ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator) == GHOSTTY_SUCCESS {
            var row: UInt16 = 0
            while ghostty_render_state_row_iterator_next_dirty(rowIterator, &row) {
                setNeedsDisplay(rowRect(Int(row)))
            }
        }
        ghostty_render_state_clean(renderState)

        // A cursor that only changes its shape or stops blinking dirties no row.
        let cursor = readCursor()
        if cursor != self.cursor {
            invalidateCursorRow()
            self.cursor = cursor
            invalidateCursorRow()
            restartCursorBlink()
        }
        // The text under a resting pointer may be another link now, or none.
        if hoveredLink != nil { updateHoveredLink() }
    }

    private func readCursor() -> Cursor? {
        var state = GhosttyRenderStateCursor()
        state.size = MemoryLayout<GhosttyRenderStateCursor>.size
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &state) == GHOSTTY_SUCCESS,
              state.viewport_has_value, state.visible else { return nil }
        return Cursor(
            // On the second half of a wide character, the cursor covers the whole of it.
            column: Int(state.viewport_x) - (state.wide_tail ? 1 : 0),
            row: Int(state.viewport_y),
            style: state.visual_style,
            blinks: state.blinking
        )
    }

    private func invalidateCursorRow() {
        if let cursor { setNeedsDisplay(rowRect(cursor.row)) }
    }

    // MARK: Cursor blink and focus

    /// Shows the cursor and starts its blink over, as typing does.
    func restartCursorBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        if isCursorBlinkedOff {
            isCursorBlinkedOff = false
            invalidateCursorRow()
        }
        guard isFocused, cursor?.blinks == true else { return }
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isCursorBlinkedOff.toggle()
                self.invalidateCursorRow()
            }
        }
        // In the common modes, so the cursor keeps blinking while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    @objc private func windowKeyStateDidChange() {
        updateFocus()
        updateHoveredLink()
    }

    /// Gives the terminal the keyboard: now, or once its card has put the view in
    /// the window if it's only just appearing.
    func focus() {
        if let window {
            window.makeFirstResponder(self)
        } else {
            wantsFocus = true
        }
    }

    func updateFocus() {
        let isFocused = session != nil && window?.isKeyWindow == true && window?.firstResponder === self
        guard isFocused != self.isFocused else { return }
        self.isFocused = isFocused
        session?.setFocused(isFocused)
        restartCursorBlink()
        // The cursor goes hollow and the selection gray without the keyboard.
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, session?.terminal != nil, let renderState,
              ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator) == GHOSTTY_SUCCESS
        else { return }

        context.saveGState()
        defer { context.restoreGState() }
        // The rows above and below the dirty ones are drawn again too, for the parts
        // of their glyphs that reach into these; the clip keeps the rest of them as is.
        context.clip(to: dirtyRect)
        context.clear(dirtyRect)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        context.setFillColorSpace(colorSpace)
        context.setStrokeColorSpace(colorSpace)
        context.textMatrix = .identity

        let colors = resolvedColors()
        let firstRow = Int(((dirtyRect.minY - Self.inset.height) / cellSize.height).rounded(.down)) - 1
        let lastRow = Int(((dirtyRect.maxY - Self.inset.height) / cellSize.height).rounded(.up))

        drawCells.removeAll(keepingCapacity: true)
        rowRanges.removeAll(keepingCapacity: true)
        clusters.removeAll(keepingCapacity: true)
        var row = 0
        while ghostty_render_state_row_iterator_next(rowIterator) {
            defer { row += 1 }
            if row < firstRow { continue }
            if row > lastRow { break }
            let start = drawCells.count
            readCells(ofRow: row, colors: colors)
            if drawCells.count > start { rowRanges.append((row, start..<drawCells.count)) }
        }

        // Every background before any text, so a row's fill can't cover the tails
        // of the letters in the row above.
        for cell in drawCells {
            guard let background = cell.background else { continue }
            background.set(in: context)
            context.fill(cellRect(column: cell.column, row: cell.row, span: cell.span))
        }
        for (row, range) in rowRanges {
            drawText(of: drawCells[range], row: row, in: context)
        }
        drawCursor(in: context, colors: colors)
        drawMarkedText(in: context, colors: colors)
    }

    private func resolvedColors() -> Colors {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let scheme = isDark ? TerminalColors.dark : TerminalColors.light
        let selection = isFocused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
        return Colors(
            // Plain text is the label color, as in the editor.
            foreground: RGBA(.labelColor),
            background: RGBA(hex: scheme.background),
            cursor: RGBA(hex: scheme.foreground),
            selection: RGBA(selection)
        )
    }

    /// Reads the row the iterator is on into `drawCells`, leaving out cells with
    /// nothing to draw.
    private func readCells(ofRow row: Int, colors: Colors) {
        guard ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells) == GHOSTTY_SUCCESS else { return }
        var selection = GhosttyRenderStateRowSelection()
        selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        let hasSelection = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
        // A block cursor is its cell drawn in reverse.
        let blockCursorColumn: Int? = if let cursor, cursor.row == row, cursor.style == GHOSTTY_CURSOR_STYLE_BLOCK,
                                         isFocused, !isCursorBlinkedOff, markedText.isEmpty { cursor.column } else { nil }

        var column = -1
        while ghostty_render_state_row_cells_next(rowCells) {
            column += 1
            var raw: GhosttyCell = 0
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            // The second cell of a wide character: its first cell draws both.
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
            let span = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1

            var length: UInt32 = 0
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
            var cellBackground = GhosttyColorRgb()
            let hasBackground = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &cellBackground) == GHOSTTY_SUCCESS
            var isStyled = false
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &isStyled)
            let isSelected = hasSelection && column + span > Int(selection.start_x) && column <= Int(selection.end_x)
            let isCursor = blockCursorColumn == column
            if length == 0, !hasBackground, !isStyled, !isSelected, !isCursor { continue }

            var cell = DrawCell(row: row, column: column, span: span, foreground: colors.foreground)
            if hasBackground { cell.background = RGBA(cellBackground) }
            if isStyled {
                var style = GhosttyStyle()
                ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                var cellForeground = GhosttyColorRgb()
                if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &cellForeground) == GHOSTTY_SUCCESS {
                    cell.foreground = RGBA(cellForeground)
                }
                let flags = style.flags
                cell.variant = (flags & StyleFlag.bold != 0 ? 1 : 0) | (flags & StyleFlag.italic != 0 ? 2 : 0)
                cell.isUnderlined = (flags >> StyleFlag.underlineShift) & 7 != 0
                cell.isStruckThrough = flags & StyleFlag.strikethrough != 0
                if flags & StyleFlag.inverse != 0 {
                    let background = cell.background ?? colors.background
                    cell.background = cell.foreground
                    cell.foreground = background
                }
                if flags & StyleFlag.faint != 0 { cell.foreground.alpha *= 0.5 }
                if flags & StyleFlag.invisible != 0 { length = 0 }
            }
            if isSelected { cell.background = colors.selection }
            if isCursor {
                cell.background = colors.cursor
                cell.foreground = colors.background
            }

            if length > 0 {
                if Int(length) > codepoints.count {
                    codepoints = [UInt32](repeating: 0, count: Int(length))
                }
                var count = 0
                codepoints.withUnsafeMutableBufferPointer { buffer in
                    var graphemes = GhosttyCodepointBuffer(ptr: buffer.baseAddress, cap: buffer.count, len: 0)
                    if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &graphemes) == GHOSTTY_SUCCESS {
                        count = min(graphemes.len, buffer.count)
                    }
                }
                if count == 1 {
                    // A space draws nothing, though it can still be underlined.
                    if codepoints[0] != 0x20 { cell.codepoint = codepoints[0] }
                } else if count > 1 {
                    // A letter with combining marks, or an emoji made of several parts.
                    var text = String.UnicodeScalarView()
                    for scalar in codepoints[..<count] {
                        if let scalar = Unicode.Scalar(scalar) { text.append(scalar) }
                    }
                    cell.codepoint = codepoints[0]
                    cell.cluster = clusters.count
                    clusters.append(String(text))
                }
            }
            if cell.codepoint == 0, cell.background == nil, !cell.isUnderlined, !cell.isStruckThrough { continue }
            drawCells.append(cell)
        }
    }

    private func drawText(of cells: ArraySlice<DrawCell>, row: Int, in context: CGContext) {
        let rowTop = Self.inset.height + CGFloat(row) * cellSize.height

        // Box lines and blocks, and the lines under and through text, in the view's
        // own top-down coordinates.
        for cell in cells {
            let rect = cellRect(column: cell.column, row: row, span: cell.span)
            if cell.cluster == nil, TerminalBoxDrawing.draws(cell.codepoint) {
                cell.foreground.set(in: context)
                _ = TerminalBoxDrawing.draw(cell.codepoint, in: rect, scale: scale, context: context)
            }
            if cell.isUnderlined {
                cell.foreground.set(in: context)
                context.fill(CGRect(x: rect.minX, y: rowTop + baseline + underlineOffset, width: rect.width, height: lineThickness))
            }
            if cell.isStruckThrough {
                cell.foreground.set(in: context)
                context.fill(CGRect(x: rect.minX, y: rowTop + baseline - strikethroughOffset, width: rect.width, height: lineThickness))
            }
        }
        // One line under the whole of the link the pointer is on, spaces included,
        // in the color of its text.
        if let columns = hoveredLink?.columns(inRow: row), let first = cells.first(where: { columns.contains($0.column) }) {
            let rect = cellRect(column: columns.lowerBound, row: row, span: columns.count)
            first.foreground.set(in: context)
            context.fill(CGRect(x: rect.minX, y: rowTop + baseline + underlineOffset, width: rect.width, height: lineThickness))
        }

        // Text, with the baseline as the x axis and y growing upwards as Core Text
        // draws. Neighbors in one font and color go to Core Text as a single run.
        context.saveGState()
        context.translateBy(x: 0, y: rowTop + baseline)
        context.scaleBy(x: 1, y: -1)
        var runVariant = 0
        var runColor: RGBA?
        func flushRun() {
            guard !runGlyphs.isEmpty, let runColor else { return }
            runColor.set(in: context)
            // The positions are added to the text position, which drawing a line
            // of text leaves at the line's end.
            context.textPosition = .zero
            CTFontDrawGlyphs(fonts[runVariant], runGlyphs, runPositions, runGlyphs.count, context)
            runGlyphs.removeAll(keepingCapacity: true)
            runPositions.removeAll(keepingCapacity: true)
        }
        for cell in cells where cell.codepoint != 0 {
            let x = Self.inset.width + CGFloat(cell.column) * cellSize.width
            if cell.cluster == nil, cell.span == 1 {
                if TerminalBoxDrawing.draws(cell.codepoint) { continue }
                let glyph = glyph(for: cell.codepoint, variant: cell.variant)
                if glyph != 0 {
                    if cell.variant != runVariant || cell.foreground != runColor {
                        flushRun()
                        runVariant = cell.variant
                        runColor = cell.foreground
                    }
                    runGlyphs.append(glyph)
                    runPositions.append(CGPoint(x: x, y: 0))
                    continue
                }
            }
            // Anything else is laid out by Core Text, which finds a font that has it.
            flushRun()
            let text = cell.cluster.map { clusters[$0] } ?? Unicode.Scalar(cell.codepoint).map { String($0) } ?? ""
            let line = line(for: text, variant: cell.variant)
            let room = CGFloat(cell.span) * cellSize.width
            cell.foreground.set(in: context)
            if line.width > room * 1.05 {
                // Wider than its cells, as icons and some emoji are: scaled to fit.
                let fit = room / line.width
                context.saveGState()
                context.translateBy(x: x, y: 0)
                context.scaleBy(x: fit, y: fit)
                context.textPosition = .zero
                CTLineDraw(line.line, context)
                context.restoreGState()
            } else {
                context.textPosition = CGPoint(x: x + max((room - line.width) / 2, 0), y: 0)
                CTLineDraw(line.line, context)
            }
        }
        flushRun()
        context.restoreGState()
    }

    private func glyph(for codepoint: UInt32, variant: Int) -> CGGlyph {
        if let glyph = glyphCaches[variant][codepoint] { return glyph }
        var glyph: CGGlyph = 0
        // Characters past the basic plane take two UTF-16 units; they go the slow way.
        if codepoint < 0x10000 {
            var character = UniChar(codepoint)
            CTFontGetGlyphsForCharacters(fonts[variant], &character, &glyph, 1)
        }
        glyphCaches[variant][codepoint] = glyph
        return glyph
    }

    private func line(for text: String, variant: Int) -> CachedLine {
        let key = LineKey(text: text, variant: variant)
        if let line = lineCache[key] { return line }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fonts[variant],
            // The color comes from the context, so one line serves every color.
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let cached = CachedLine(line: line, width: CTLineGetTypographicBounds(line, nil, nil, nil))
        if lineCache.count >= 4096 { lineCache.removeAll(keepingCapacity: true) }
        lineCache[key] = cached
        return cached
    }

    /// The cursors that aren't a reversed cell: a bar, an underline, and the outline
    /// the cursor becomes while the terminal doesn't have the keyboard.
    private func drawCursor(in context: CGContext, colors: Colors) {
        guard let cursor, markedText.isEmpty else { return }
        let rect = cellRect(column: cursor.column, row: cursor.row)
        colors.cursor.set(in: context)
        if !isFocused || cursor.style == GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW {
            let width = max(scale.rounded(), 1) / scale
            context.setLineWidth(width)
            context.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
        } else if isCursorBlinkedOff {
            return
        } else if cursor.style == GHOSTTY_CURSOR_STYLE_BAR {
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: max((1.5 * scale).rounded(), 1) / scale, height: rect.height))
        } else if cursor.style == GHOSTTY_CURSOR_STYLE_UNDERLINE {
            let height = max((2 * scale).rounded(), 1) / scale
            context.fill(CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height))
        }
    }

    /// What an input method is composing, underlined at the cursor until it's committed.
    private func drawMarkedText(in context: CGContext, colors: Colors) {
        guard !markedText.isEmpty else { return }
        let origin = cursorRect.origin
        let line = line(for: markedText, variant: 0)
        let rect = CGRect(x: origin.x, y: origin.y, width: max(line.width, cellSize.width), height: cellSize.height)
        colors.background.set(in: context)
        context.fill(rect)
        colors.cursor.set(in: context)
        context.fill(CGRect(x: rect.minX, y: rect.minY + baseline + underlineOffset, width: rect.width, height: lineThickness))
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + baseline)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: rect.minX, y: 0)
        CTLineDraw(line.line, context)
        context.restoreGState()
    }
}

// MARK: - Drawing types

/// A color as its sRGB components, which is how the context is given colors: no
/// color object to make for each run of text.
private struct RGBA: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1

    init(_ color: GhosttyColorRgb) {
        red = CGFloat(color.r) / 255
        green = CGFloat(color.g) / 255
        blue = CGFloat(color.b) / 255
    }

    init(hex: UInt32) {
        self.init(GhosttyColorRgb(hex: hex))
    }

    /// A system color as it is in the appearance being drawn.
    init(_ color: NSColor) {
        let color = color.usingColorSpace(.sRGB) ?? .gray
        red = color.redComponent
        green = color.greenComponent
        blue = color.blueComponent
        alpha = color.alphaComponent
    }

    /// Makes this the context's fill and stroke color. The context's color spaces
    /// have to be sRGB.
    func set(in context: CGContext) {
        withUnsafeTemporaryAllocation(of: CGFloat.self, capacity: 4) { components in
            components[0] = red
            components[1] = green
            components[2] = blue
            components[3] = alpha
            context.setFillColor(components.baseAddress!)
            context.setStrokeColor(components.baseAddress!)
        }
    }
}

private struct Colors {
    var foreground: RGBA
    /// Opaque, for text drawn in reverse and under the block cursor: the card itself
    /// has no background color.
    var background: RGBA
    var cursor: RGBA
    var selection: RGBA
}

/// One cell with something to draw, its colors and style settled.
private struct DrawCell {
    var row: Int
    var column: Int
    /// 2 for a wide character such as a CJK ideograph or an emoji.
    var span: Int
    var foreground: RGBA
    var background: RGBA?
    /// The character, or the first of several; 0 for none.
    var codepoint: UInt32 = 0
    /// Index into `clusters` of the whole text, for a cell with several code points.
    var cluster: Int?
    /// Index into `fonts`.
    var variant = 0
    var isUnderlined = false
    var isStruckThrough = false
}

private struct Cursor: Equatable {
    var column: Int
    var row: Int
    var style: GhosttyCursorStyle
    var blinks: Bool
}

private struct LineKey: Hashable {
    var text: String
    var variant: Int
}

private struct CachedLine {
    var line: CTLine
    var width: CGFloat
}

/// The bits of a cell's style. The header has them as macros Swift doesn't import.
private enum StyleFlag {
    static let bold: UInt16 = 1 << 0
    static let italic: UInt16 = 1 << 1
    static let faint: UInt16 = 1 << 2
    static let inverse: UInt16 = 1 << 4
    static let invisible: UInt16 = 1 << 5
    static let strikethrough: UInt16 = 1 << 6
    static let underlineShift: UInt16 = 8
}
