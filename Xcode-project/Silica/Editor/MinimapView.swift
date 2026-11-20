import AppKit

/// A zoomed-out overview of the whole file down the right edge of the editor, as in
/// VS Code: each character is a small block in its syntax color, the lines on screen
/// sit under a translucent slider, and the cursor's line is marked in the accent color.
///
/// Logical lines are drawn (a wrapped line is one row). When the file is taller than
/// the minimap, the minimap scrolls in proportion to the editor so the slider always
/// stays in view. Click to jump to a spot (it's centered), drag the slider to scroll,
/// and scroll the wheel over it as over the text.
///
/// Only the rows on screen are drawn, straight from the text storage, so there's no
/// cached image to keep in sync with edits or highlighting.
final class MinimapView: NSView {
    /// Width of the minimap strip, including its padding.
    static let width: CGFloat = 100

    private let rowHeight: CGFloat = 2
    private let blockHeight: CGFloat = 1.5
    private let columnWidth: CGFloat = 1
    private let horizontalPadding: CGFloat = 6
    /// Opacity of the character blocks; full-strength colors are too loud at this size.
    private let textOpacity: CGFloat = 0.6

    private weak var controller: TextController?

    private var isHovering = false {
        didSet { if isHovering != oldValue { needsDisplay = true } }
    }
    private var drag: (startMouseY: CGFloat, startScrollY: CGFloat)? {
        didSet { needsDisplay = true }
    }

    init(controller: TextController) {
        self.controller = controller
        super.init(frame: .zero)

        let textView = controller.textView
        let clipView = controller.scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(setNeedsRedraw), name: NSView.boundsDidChangeNotification, object: clipView)
        center.addObserver(self, selector: #selector(setNeedsRedraw), name: NSView.frameDidChangeNotification, object: textView)
        // Edits and highlighting (attribute-only changes) alike.
        if let storage = textView.textStorage {
            center.addObserver(self, selector: #selector(setNeedsRedraw), name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        center.addObserver(self, selector: #selector(setNeedsRedraw), name: NSTextView.didChangeSelectionNotification, object: textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// As with the gutter: vibrant colors wash out on the glass card.
    override var allowsVibrancy: Bool { false }
    /// A click scrolls the editor; it shouldn't need the window focused first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func setNeedsRedraw() {
        needsDisplay = true
    }

    // MARK: Geometry

    /// Where things sit for the current scroll position, in this view's coordinates.
    private struct Metrics {
        var lineCount: Int
        /// How far the minimap's rows are scrolled up.
        var offset: CGFloat
        var slider: NSRect
        /// How far the slider can travel, for turning drags into editor scrolling.
        var track: CGFloat
    }

    private func metrics() -> Metrics? {
        guard let controller else { return nil }
        let lineCount = controller.lineCount
        let contentHeight = CGFloat(lineCount) * rowHeight
        let visibleLines = controller.visibleLineRange()
        let sliderTop = CGFloat(visibleLines.lowerBound - 1) * rowHeight
        let sliderHeight = max(CGFloat(visibleLines.count) * rowHeight, 8)

        // Scroll the rows by the editor's scroll fraction, but keep the slider in view:
        // at the top it starts at 0, at the bottom the last row meets the bottom edge.
        let fraction = controller.scrollFraction
        let maxOffset = max(0, contentHeight - bounds.height)
        let offset = min(max(sliderTop - fraction * (bounds.height - sliderHeight), 0), maxOffset)

        let slider = NSRect(x: 0, y: sliderTop - offset, width: bounds.width, height: sliderHeight)
        let track = max(0, min(contentHeight, bounds.height) - sliderHeight)
        return Metrics(lineCount: lineCount, offset: offset, slider: slider, track: track)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let storage = controller.textView.textStorage,
              let context = NSGraphicsContext.current?.cgContext,
              let metrics = metrics() else { return }

        drawSelection(in: context, metrics: metrics)
        drawText(storage, in: context, metrics: metrics, dirtyRect: dirtyRect)

        let sliderOpacity: CGFloat = drag != nil ? 0.16 : isHovering ? 0.11 : 0.07
        context.setFillColor(NSColor.labelColor.withAlphaComponent(sliderOpacity).cgColor)
        context.fill(metrics.slider)

        drawDivider(in: context)
    }

    /// A hairline down the leading edge, setting the minimap apart from the text.
    private func drawDivider(in context: CGContext) {
        let scale = window?.backingScaleFactor ?? 2
        context.setFillColor(SyntaxTheme.indentGuide.cgColor)
        context.fill(NSRect(x: 0, y: 0, width: 1 / scale, height: bounds.height))
    }

    /// Rows holding the selection get a faint accent wash; the cursor's row a stronger one.
    private func drawSelection(in context: CGContext, metrics: Metrics) {
        guard let controller else { return }
        let selection = controller.textView.selectedRange()
        let accent = NSColor.controlAccentColor
        let cursorLine = controller.lineNumber(at: selection.location)

        if selection.length > 0 {
            let lastLine = controller.lineNumber(at: max(selection.location, NSMaxRange(selection) - 1))
            let top = CGFloat(cursorLine - 1) * rowHeight - metrics.offset
            let height = CGFloat(lastLine - cursorLine + 1) * rowHeight
            context.setFillColor(accent.withAlphaComponent(0.25).cgColor)
            context.fill(NSRect(x: 0, y: top, width: bounds.width, height: height))
        } else {
            let top = CGFloat(cursorLine - 1) * rowHeight - metrics.offset
            context.setFillColor(accent.withAlphaComponent(0.6).cgColor)
            context.fill(NSRect(x: 0, y: top, width: bounds.width, height: rowHeight))
        }
    }

    /// One block per non-blank character, merged into runs of the same color.
    private func drawText(_ storage: NSTextStorage, in context: CGContext, metrics: Metrics, dirtyRect: NSRect) {
        guard let controller, storage.length > 0 else { return }
        let text = storage.string as NSString
        let length = text.length
        let tabWidth = EditorTextView.tabWidth
        let maxColumns = Int((bounds.width - 2 * horizontalPadding) / columnWidth)

        let firstRow = max(0, Int((metrics.offset + dirtyRect.minY) / rowHeight))
        let lastRow = min(metrics.lineCount - 1, Int((metrics.offset + dirtyRect.maxY) / rowHeight))
        guard firstRow <= lastRow else { return }

        var rects: [CGRect] = []
        var rectsColor: NSColor?
        func flush() {
            guard let rectsColor, !rects.isEmpty else { return }
            context.setFillColor(rectsColor.withAlphaComponent(rectsColor.alphaComponent * textOpacity).cgColor)
            context.fill(rects)
            rects.removeAll(keepingCapacity: true)
        }

        var buffer = [unichar](repeating: 0, count: maxColumns)
        var colorRun = NSRange(location: 0, length: 0)
        var color = SyntaxTheme.plain

        for row in firstRow...lastRow {
            let start = controller.offset(ofLine: row + 1)
            guard start < length else { break }
            let y = CGFloat(row) * rowHeight - metrics.offset + (rowHeight - blockHeight) / 2
            // A row never shows more characters than it has columns (tabs only widen it).
            let count = min(maxColumns, length - start)
            text.getCharacters(&buffer, range: NSRange(location: start, length: count))

            var column = 0
            var spanStart = -1
            var spanColor = color

            func endSpan(at end: Int) {
                guard spanStart >= 0 else { return }
                if rectsColor !== spanColor {
                    flush()
                    rectsColor = spanColor
                }
                rects.append(CGRect(
                    x: horizontalPadding + CGFloat(spanStart) * columnWidth, y: y,
                    width: CGFloat(end - spanStart) * columnWidth, height: blockHeight
                ))
                spanStart = -1
            }

            for i in 0..<count {
                let character = buffer[i]
                if character == 0x0A || character == 0x0D { break }
                if column >= maxColumns { break }
                if character == 0x20 || character == 0x09 {
                    endSpan(at: column)
                    column = character == 0x09 ? column + tabWidth - column % tabWidth : column + 1
                    continue
                }
                let index = start + i
                if !NSLocationInRange(index, colorRun) {
                    color = storage.attribute(.foregroundColor, at: index, effectiveRange: &colorRun) as? NSColor ?? SyntaxTheme.plain
                }
                if spanStart >= 0, color !== spanColor {
                    endSpan(at: column)
                }
                if spanStart < 0 {
                    spanStart = column
                    spanColor = color
                }
                column += 1
            }
            endSpan(at: min(column, maxColumns))
        }
        flush()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, let metrics = metrics() else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Off the slider, jump there first, then let the same press drag from the new spot.
        if !metrics.slider.contains(point) {
            let line = Int((point.y + metrics.offset) / rowHeight) + 1
            controller.center(line: min(max(line, 1), metrics.lineCount))
        }
        drag = (point.y, controller.scrollY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let drag, let metrics = metrics(), metrics.track > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = point.y - drag.startMouseY
        controller.setScrollY(drag.startScrollY + delta * controller.maxScrollY / metrics.track)
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.scrollView.scrollWheel(with: event)
    }
}
