import AppKit
import Observation
import SwiftUI

/// Works out which folders to pin to the top of the file tree as it scrolls: the
/// open folders that contain the first visible row, so it's always clear where
/// the rows on screen belong.
///
/// SwiftUI doesn't report a list's scroll position or row frames, so this reads
/// them from the AppKit table behind the list.
@Observable
final class PinnedFolderTracker {
    /// What the tracker needs to know about a list row.
    struct Row: Equatable {
        let depth: Int
        let isOpenFolder: Bool
    }

    /// A folder row drawn over the top of the list.
    struct Pinned: Equatable {
        /// The folder's index in the list's rows.
        let index: Int
        /// The top of its place in the stack, from the top of the tree.
        let slotTop: CGFloat
        /// Where it's drawn: at `slotTop`, or higher while the end of its folder
        /// pushes it out.
        let top: CGFloat
        let height: CGFloat
    }

    /// Where the list puts a row's content inside the row, as insets from the
    /// tree's edges and the row's top.
    struct ContentLayout: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
        var top: CGFloat = 0
        var height: CGFloat = 0
    }

    /// The pinned folders, outermost first.
    private(set) var pinned: [Pinned] = []
    /// Measured from the list's own rows, so pinned ones line up with them.
    private(set) var contentLayout = ContentLayout()

    /// How much of the top of the list the pinned folders cover.
    var coveredHeight: CGFloat {
        pinned.last.map { max($0.top + $0.height, 0) } ?? 0
    }

    /// The most folders pinned at once.
    private static let maxPinned = 6
    /// The most of the tree's height the pinned folders take.
    private static let maxHeightFraction: CGFloat = 0.4

    @ObservationIgnored private var rows: [Row] = []
    @ObservationIgnored private weak var anchor: NSView?
    @ObservationIgnored private weak var table: NSTableView?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var scrollMonitor: Any?
    @ObservationIgnored private var isUpdateScheduled = false
    @ObservationIgnored private var tableSearchesLeft = 20

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    // MARK: Inputs

    /// The list's rows changed (a folder opened, the filter changed, ...).
    func setRows(_ rows: [Row]) {
        guard rows != self.rows else { return }
        self.rows = rows
        scheduleUpdate()
    }

    /// Updates on the next turn of the run loop: after the table has caught up with
    /// a change, and outside SwiftUI's view update.
    func scheduleUpdate() {
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isUpdateScheduled = false
            self?.update()
        }
    }

    /// `anchor` covers the visible part of the tree; the list's table is looked up
    /// from it.
    fileprivate func attach(to anchor: NSView) {
        self.anchor = anchor
        scheduleUpdate()
    }

    // MARK: Pinned folders

    private func update() {
        findTableIfNeeded()
        if table == nil, anchor?.window != nil, tableSearchesLeft > 0 {
            // The list may not have made its table yet.
            tableSearchesLeft -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.scheduleUpdate() }
        }
        // Keeps the last answer while the table and `rows` are out of step.
        guard let (pinned, contentLayout) = currentState() else { return }
        if pinned != self.pinned { self.pinned = pinned }
        if let contentLayout, contentLayout != self.contentLayout { self.contentLayout = contentLayout }
    }

    /// The y of the top of the visible tree in the table's coordinates.
    private func visibleTop(in table: NSTableView, anchor: NSView) -> CGFloat {
        table.convert(NSPoint(x: anchor.bounds.minX, y: anchor.bounds.minY), from: anchor).y
    }

    private func currentState() -> ([Pinned], ContentLayout?)? {
        guard let table, let anchor, anchor.window != nil, table.window === anchor.window,
              !rows.isEmpty else { return ([], nil) }
        // The table has one more row than `rows`: the spacer that ends the list.
        guard table.numberOfRows == rows.count + 1 else { return nil }

        let top = visibleTop(in: table, anchor: anchor)
        let x = table.bounds.midX
        let maxHeight = anchor.bounds.height * Self.maxHeightFraction

        // As VS Code's sticky scroll does it: pin the ancestor of the first row
        // under the stack so far, then look at the row under that one, and so on.
        var pinned: [Pinned] = []
        var stackHeight: CGFloat = 0
        var probe = top
        while pinned.count < Self.maxPinned {
            let first = table.row(at: NSPoint(x: x, y: probe + 0.5))
            guard rows.indices.contains(first),
                  let index = ancestor(of: first, depth: pinned.count),
                  index > (pinned.last?.index ?? -1) else { break }
            let rect = table.rect(ofRow: index)
            guard stackHeight + rect.height <= maxHeight else { break }
            if index == first {
                // The row under the stack is itself a folder: pin it once it has
                // started to scroll under the stack, if it has rows to stand for.
                guard rows[index].isOpenFolder, lastDescendant(of: index) > index,
                      rect.minY < top + stackHeight - 0.5 else { break }
            }
            // The folder's last row pushes it out as it scrolls past.
            let endBottom = table.rect(ofRow: lastDescendant(of: index)).maxY - top
            guard endBottom > stackHeight else { break }
            let rowTop = min(stackHeight, endBottom - rect.height)
            pinned.append(Pinned(index: index, slotTop: stackHeight, top: rowTop, height: rect.height))
            stackHeight += rect.height
            probe = top + rowTop + rect.height
        }
        let layout = pinned.first.flatMap { measureContentLayout(rowHeight: $0.height, in: table, anchor: anchor) }
        return (pinned, layout)
    }

    /// The row at `depth` that contains row `index`, or `index` itself when it is
    /// at that depth.
    private func ancestor(of index: Int, depth: Int) -> Int? {
        var index = index
        while index > 0, rows[index].depth > depth { index -= 1 }
        return rows[index].depth == depth ? index : nil
    }

    /// The last row inside the folder at `index`; `index` itself if it shows none.
    private func lastDescendant(of index: Int) -> Int {
        var last = index
        while last + 1 < rows.count, rows[last + 1].depth > rows[index].depth { last += 1 }
        return last
    }

    /// Measured from a visible row of the given height, which leaves out a taller
    /// row with a name field in it.
    private func measureContentLayout(rowHeight: CGFloat, in table: NSTableView, anchor: NSView) -> ContentLayout? {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return nil }
        for row in visible.location..<(visible.location + visible.length) where row < rows.count {
            let rect = table.rect(ofRow: row)
            guard abs(rect.height - rowHeight) < 0.5,
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            let frame = anchor.convert(cell.bounds, from: cell)
            let rowTop = anchor.convert(rect, from: table).minY
            return ContentLayout(
                leading: frame.minX - anchor.bounds.minX,
                trailing: anchor.bounds.maxX - frame.maxX,
                top: frame.minY - rowTop,
                height: frame.height
            )
        }
        return nil
    }

    // MARK: Scrolling

    /// Scrolls the folder's own row to its place in the stack, where it takes over
    /// from the pinned copy.
    func reveal(_ pinned: Pinned) {
        scroll(row: pinned.index, toOffset: pinned.slotTop, animated: true)
    }

    /// Scrolls a row out from under the pinned folders, to just below the ones that
    /// contain it. Does nothing when the row is already clear of them.
    func uncover(row index: Int) {
        guard let table, let anchor, rows.indices.contains(index), table.numberOfRows == rows.count + 1 else { return }
        let rect = table.rect(ofRow: index)
        let top = visibleTop(in: table, anchor: anchor)
        guard rect.minY < top + coveredHeight - 0.5, rect.maxY > top - rect.height else { return }
        let above = min(rows[index].depth, Self.maxPinned)
        scroll(row: index, toOffset: CGFloat(above) * rect.height, animated: false)
    }

    private func scroll(row index: Int, toOffset offset: CGFloat, animated: Bool) {
        guard let table, let anchor, let scrollView = table.enclosingScrollView,
              index < table.numberOfRows else { return }
        let clipView = scrollView.contentView
        let delta = table.rect(ofRow: index).minY - (visibleTop(in: table, anchor: anchor) + offset)
        var origin = clipView.bounds.origin
        origin.y += delta
        origin = clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size)).origin
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                clipView.animator().setBoundsOrigin(origin)
            } completionHandler: {
                scrollView.reflectScrolledClipView(clipView)
            }
        } else {
            clipView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    /// The pinned folders are drawn over the list, not in it, so the scroll wheel
    /// wouldn't reach the list while the pointer is on them: pass it on.
    private func forwardScrollEvents() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let anchor, let scrollView = table?.enclosingScrollView,
                  !pinned.isEmpty, event.window === anchor.window else { return event }
            let point = anchor.convert(event.locationInWindow, from: nil)
            guard anchor.bounds.contains(point), point.y < coveredHeight else { return event }
            scrollView.scrollWheel(with: event)
            return nil
        }
    }

    // MARK: Table

    private func findTableIfNeeded() {
        guard let anchor, let window = anchor.window else { return }
        if let table, table.window === window { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        table = nil

        // The list is a sibling of the anchor somewhere up the hierarchy: take the
        // nearest table whose scroll view is where the anchor is.
        let anchorFrame = anchor.convert(anchor.bounds, to: nil)
        var ancestor = anchor.superview
        var found: NSTableView?
        while let view = ancestor, found == nil {
            found = Self.table(in: view, overlapping: anchorFrame)
            ancestor = view.superview
        }
        guard let found, let scrollView = found.enclosingScrollView else { return }
        table = found
        tableSearchesLeft = 0
        forwardScrollEvents()

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        found.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        let onChange: (Notification) -> Void = { [weak self] _ in self?.update() }
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main, using: onChange),
            center.addObserver(forName: NSView.frameDidChangeNotification, object: found, queue: .main, using: onChange),
        ]
    }

    private static func table(in view: NSView, overlapping frame: CGRect) -> NSTableView? {
        if let table = view as? NSTableView {
            guard let scrollView = table.enclosingScrollView else { return nil }
            return scrollView.convert(scrollView.bounds, to: nil).intersects(frame) ? table : nil
        }
        for subview in view.subviews {
            if let table = table(in: subview, overlapping: frame) { return table }
        }
        return nil
    }
}

/// Put behind the tree, the size of its visible part: tells the tracker where the
/// tree is and what its rows are.
struct PinnedFolderAnchor: NSViewRepresentable {
    let tracker: PinnedFolderTracker
    let rows: [PinnedFolderTracker.Row]

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.tracker = tracker
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.tracker = tracker
        tracker.setRows(rows)
    }

    final class AnchorView: NSView {
        weak var tracker: PinnedFolderTracker?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            tracker?.attach(to: self)
        }

        override func layout() {
            super.layout()
            tracker?.scheduleUpdate()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
