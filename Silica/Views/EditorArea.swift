import AppKit
import PDFKit
import SwiftUI

struct EditorArea: View {
    let workspace: WorkspaceModel

    @Environment(\.colorScheme) private var colorScheme
    private var settings: EditorSettings { .shared }
    @AppStorage("terminalHeight") private var terminalHeight: Double = 260
    @State private var dragStartTerminalHeight: Double?
    @State private var cardsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // Title bar row: tabs share it with the traffic lights.
            HStack(spacing: 8) {
                if !workspace.isSidebarVisible {
                    Color.clear.frame(width: WorkspaceLayout.trafficLightsWidth)
                    if !workspace.isStandalone {
                        SidebarToggleButton(workspace: workspace)
                    }
                }
                EditorTabBar(workspace: workspace)
                Spacer(minLength: 0)
                if let buffer = workspace.activeBuffer, let format = buffer.previewFormat {
                    PreviewModeToggle(buffer: buffer, format: format)
                }
                // Last, so it stays in place whatever the tab has beside it.
                TerminalToggleButton(workspace: workspace)
                    .padding(.trailing, WorkspaceLayout.cardInset + 4)
            }
            .frame(height: WorkspaceLayout.titleBarHeight)

            VStack(spacing: 0) {
                editorCard
                if workspace.isTerminalVisible, let terminal = workspace.terminal {
                    // The terminal's card sits under the editor's, the gap between
                    // them being the handle that resizes it.
                    VStack(spacing: 0) {
                        terminalResizeHandle
                        TerminalCard(session: terminal, workspace: workspace)
                            .frame(height: clampedTerminalHeight)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
            .padding(.leading, workspace.isSidebarVisible ? 0 : WorkspaceLayout.cardInset)
            .padding([.trailing, .bottom], WorkspaceLayout.cardInset)
        }
        .frame(minWidth: 420)
    }

    /// The stored height, kept within what the window has room for: the editor
    /// keeps a few lines however small the window gets.
    private var clampedTerminalHeight: CGFloat {
        let range = WorkspaceLayout.terminalHeightRange
        let most = max(cardsHeight - WorkspaceLayout.cardInset - WorkspaceLayout.minimumEditorHeight, range.lowerBound)
        return min(max(terminalHeight, range.lowerBound), min(most, range.upperBound))
    }

    /// Invisible strip between the two cards that resizes the terminal.
    private var terminalResizeHandle: some View {
        Color.clear
            .frame(height: WorkspaceLayout.cardInset)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .top))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // From the height on screen, which the window may have limited.
                        let start = dragStartTerminalHeight ?? clampedTerminalHeight
                        dragStartTerminalHeight = start
                        let range = WorkspaceLayout.terminalHeightRange
                        let most = max(cardsHeight - WorkspaceLayout.cardInset - WorkspaceLayout.minimumEditorHeight, range.lowerBound)
                        terminalHeight = min(max(start - value.translation.height, range.lowerBound), min(most, range.upperBound))
                    }
                    .onEnded { _ in dragStartTerminalHeight = nil }
            )
    }

    private var editorCard: some View {
        Group {
            if let buffer = workspace.activeBuffer {
                BufferView(buffer: buffer, workspace: workspace)
            } else {
                EmptyEditorView(workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if !settings.usesGlassEffect {
                colorScheme == .dark ? Color.black : Color.white
            }
        }
        .workspaceCard()
    }
}

// MARK: - Tabs

private struct EditorTabBar: View {
    let workspace: WorkspaceModel

    /// The tab being dragged to a new place, and how far the pointer has carried it.
    @State private var drag: TabDrag<URL>?
    /// Each tab's laid-out width, to tell which tabs a dragged one has passed.
    @State private var tabWidths: [URL: CGFloat] = [:]
    /// Width of the part of the row that shows, and how far the row is scrolled under it.
    @State private var barWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    /// Scrolls the row during a drag; showing the active tab still goes through the reader.
    @State private var scrollPosition = ScrollPosition(idType: Never.self)
    /// How much each end of the row is faded: fully once tabs are scrolled out past it.
    @State private var edgeFades = EdgeFades()

    /// The bar's own space, which stays put while the row scrolls and the tabs move.
    static let space: NamedCoordinateSpace = .named("EditorTabBar")

    private static let spacing: CGFloat = 6
    private static let inset: CGFloat = 2
    private static let reorderAnimation = Animation.snappy(duration: 0.2)
    /// How far in from an end of the bar the row fades out.
    private static let fadeWidth: CGFloat = 20

    var body: some View {
        let offsets = drag?.reorder(in: layout)?.offsets ?? [:]
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Self.spacing - 2 * Self.fadeWidth) {
                    ForEach(workspace.openTabs, id: \.self) { url in
                        let offset = offsets[url] ?? 0
                        let isDragged = drag?.tab == url
                        EditorTab(
                            url: url,
                            isActive: url == workspace.activeTab,
                            isDirty: workspace.buffers[url]?.isDirty == true,
                            isMissing: workspace.buffers[url]?.isMissingOnDisk == true,
                            select: { workspace.activate(url) },
                            close: { withAnimation(.snappy) { workspace.closeTab(url) } },
                            closeOthers: { withAnimation(.snappy) { workspace.closeOtherTabs(than: url) } },
                            revealInTree: workspace.contains(url) ? { workspace.revealInTree(url) } : nil,
                            drag: { handleDrag($0, of: url, proxy: proxy) }
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabWidths[url] = $0 }
                        // Room on either side that the row scrolls into view with the tab,
                        // so that it comes to rest clear of the faded ends of the bar. The
                        // row's spacing and padding take the same room back out.
                        .padding(.horizontal, Self.fadeWidth)
                        .offset(x: offset)
                        .zIndex(isDragged ? 1 : 0)
                        // The dragged tab stays under the pointer; the others slide out of its way.
                        .animation(isDragged ? nil : Self.reorderAnimation, value: offset)
                        .id(url)
                    }
                }
                .padding(.horizontal, Self.inset - Self.fadeWidth)
                .padding(.vertical, 4)
                // The tabs sit in the title bar, where the window server moves the window
                // on any drag, whatever gesture or view is under the pointer. So the
                // window stops being movable while the pointer is over the tabs; a drag
                // on the empty part of the row still moves it, as on its background.
                .onHover { workspace.window?.isMovable = !$0 }
            }
            .scrollIndicators(.never)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in
                scrollOffset = offset
            }
            .onScrollGeometryChange(for: EdgeFades.self) { geometry in
                let offset = geometry.contentOffset.x
                let hiddenAfter = geometry.contentSize.width - geometry.containerSize.width - offset
                return EdgeFades(leading: offset, trailing: hiddenAfter, over: Self.fadeWidth)
            } action: { _, fades in
                edgeFades = fades
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            // A tab scrolled part of the way out fades away rather than ending in a cut.
            .mask { fadeMask }
            .background(WheelScrollsSideways())
            .coordinateSpace(Self.space)
            .onChange(of: workspace.activeTab) { _, active in
                if let active {
                    withAnimation { proxy.scrollTo(active) }
                }
            }
            // The row jumps back to its start when the bar changes width, which takes the
            // active tab out of view: resizing the window or the sidebar brings it back,
            // in step with the resize rather than animated behind it.
            .onChange(of: barWidth) {
                if drag == nil, let active = workspace.activeTab {
                    proxy.scrollTo(active)
                }
            }
            .onChange(of: workspace.openTabs) { _, tabs in
                tabWidths = tabWidths.filter { tabs.contains($0.key) }
                // The dragged tab can close or be renamed mid-drag, which removes its view
                // before the gesture can end or cancel.
                if let drag, !tabs.contains(drag.tab) { self.drag = nil }
                // Closing the last tab leaves nothing for the pointer to move off.
                if tabs.isEmpty { workspace.window?.isMovable = true }
            }
            .onDisappear { workspace.window?.isMovable = true }
            // A pointer resting near an end of the bar sends no events, so a timer keeps
            // the row scrolling under it for as long as the drag lasts.
            .task(id: drag?.tab) {
                guard drag != nil else { return }
                var last = Date.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(16))
                    let now = Date.now
                    autoscroll(elapsed: now.timeIntervalSince(last))
                    last = now
                }
            }
        }
    }

    /// Opaque across the bar, clearing towards an end that has tabs scrolled out past it.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(1 - edgeFades.leading), .black],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: Self.fadeWidth)
            Color.black
            LinearGradient(
                colors: [.black, .black.opacity(1 - edgeFades.trailing)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: Self.fadeWidth)
        }
    }

    private func handleDrag(_ event: TabDragEvent, of url: URL, proxy: ScrollViewProxy) {
        switch event {
        case .moved(let translation, let location):
            if let drag, drag.tab == url {
                self.drag = TabDrag(tab: url, translation: translation, location: location, startScrollOffset: drag.startScrollOffset)
            } else {
                // Dragging a tab brings it forward, as clicking it does.
                workspace.activate(url)
                drag = TabDrag(tab: url, translation: translation, location: location, startScrollOffset: scrollOffset)
            }
        case .dropped(let translation):
            guard var dropped = drag, dropped.tab == url else { return }
            dropped.translation = translation
            let destination = dropped.reorder(in: layout)?.destination
            // The new order and the end of the drag go in one animation, so every tab
            // settles from where the drag left it instead of jumping to its new place.
            withAnimation(Self.reorderAnimation) {
                if let destination { workspace.moveTab(url, to: destination) }
                drag = nil
            }
            // Its new place can reach past the end of the bar. Once the row is laid out
            // in its new order: asked in the same pass, the reader goes to where the
            // tab was, which a drag that scrolled the row has left far behind.
            DispatchQueue.main.async {
                withAnimation(Self.reorderAnimation) { proxy.scrollTo(url) }
            }
        case .cancelled:
            if drag?.tab == url {
                withAnimation(Self.reorderAnimation) { drag = nil }
            }
        }
    }

    /// The row as it's laid out now, for the drag to be worked out from.
    private var layout: TabBarLayout<URL> {
        TabBarLayout(
            tabs: workspace.openTabs, widths: tabWidths, spacing: Self.spacing, inset: Self.inset,
            barWidth: barWidth, scrollOffset: scrollOffset
        )
    }

    /// Scrolls the row while a tab is held near an end of the bar, so a tab can be
    /// taken past the ones that fit in the bar.
    private func autoscroll(elapsed: TimeInterval) {
        guard let target = drag?.autoscrollOffset(in: layout, elapsed: elapsed) else { return }
        scrollPosition.scrollTo(x: target)
        // Ahead of the scroll view reporting it, so the tab doesn't trail the row by a frame.
        scrollOffset = target
    }

}

/// Lets a mouse wheel scroll the tab row. A wheel only scrolls up and down, which a
/// row that scrolls sideways ignores unless Shift is held, so while the pointer is on
/// the bar the wheel's travel reaches the row as sideways travel. Trackpads and mice
/// that scroll both ways are left as they are.
struct WheelScrollsSideways: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {}

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.stopWatching()
    }

    /// Marks where the bar is in its window, behind the row.
    final class AnchorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // A wheel's events belong to no gesture, unlike a trackpad's.
                guard let self, event.window === window, event.phase.isEmpty, event.momentumPhase.isEmpty,
                      event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
                      bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
                return event.turnedSideways() ?? event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

struct MiddleClickClosesTab<Tab: Hashable>: NSViewRepresentable {
    let tab: (CGFloat) -> Tab?
    let close: (Tab) -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.tab = tab
        nsView.close = close
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.stopWatching()
    }

    final class AnchorView: NSView {
        var tab: (CGFloat) -> Tab? = { _ in nil }
        var close: (Tab) -> Void = { _ in }
        private var monitor: Any?
        private var pressed: Tab?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            pressed = nil
        }

        private func handle(_ event: NSEvent) {
            guard event.buttonNumber == 2 else { return }
            let point = convert(event.locationInWindow, from: nil)
            let isBlocked = window?.attachedSheet != nil || NSApp.modalWindow != nil
            let hit = event.window === window && !isBlocked && bounds.contains(point) ? tab(point.x) : nil
            if event.type == .otherMouseDown {
                pressed = hit
                return
            }
            defer { pressed = nil }
            guard let hit, hit == pressed else { return }
            DispatchQueue.main.async { [weak self] in self?.close(hit) }
        }
    }
}

private extension NSEvent {
    /// A copy of a scroll event with its vertical travel made horizontal, as holding
    /// Shift does.
    func turnedSideways() -> NSEvent? {
        guard let copy = cgEvent?.copy() else { return nil }
        let lines = copy.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fraction = copy.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let points = copy.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        // Whole lines first: setting them recomputes the finer amounts.
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lines)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fraction)
        copy.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        copy.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: points)
        return NSEvent(cgEvent: copy)
    }
}

/// How strongly each end of the tab row fades, from 0 (not at all) to 1.
struct EdgeFades: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    init() {}

    /// Each end fades in over the first `distance` points of row scrolled out past it.
    init(leading: CGFloat, trailing: CGFloat, over distance: CGFloat) {
        self.leading = min(max(leading / distance, 0), 1)
        self.trailing = min(max(trailing / distance, 0), 1)
    }
}

/// A tab bar's row as it's laid out, which a drag along it is worked out from.
struct TabBarLayout<Tab: Hashable> {
    let tabs: [Tab]
    /// Each tab's laid-out width.
    let widths: [Tab: CGFloat]
    /// The gap between two tabs, and the room before the first and after the last.
    let spacing: CGFloat
    let inset: CGFloat
    /// Width of the part of the row that shows, and how far the row is scrolled under it.
    let barWidth: CGFloat
    let scrollOffset: CGFloat

    /// The tab at a horizontal position in the bar, if there's one.
    func tab(at x: CGFloat) -> Tab? {
        var leading = inset - scrollOffset
        for tab in tabs {
            let width = widths[tab] ?? 0
            if x >= leading && x < leading + width { return tab }
            leading += width + spacing
        }
        return nil
    }
}

/// A tab being dragged to another place in its bar.
struct TabDrag<Tab: Hashable> {
    let tab: Tab
    /// Horizontal distance the pointer has moved since the drag began.
    var translation: CGFloat
    /// The pointer's horizontal position in the tab bar.
    var location: CGFloat
    /// How far the row was scrolled when the drag began.
    let startScrollOffset: CGFloat

    /// Where the dragged tab would land if dropped now, and how far each tab sits from
    /// its place in the row meanwhile: the dragged one follows the pointer, and the
    /// tabs it has passed step aside by its width. The order itself changes on drop.
    func reorder(in bar: TabBarLayout<Tab>) -> (destination: Int, offsets: [Tab: CGFloat])? {
        let tabs = bar.tabs
        guard let source = tabs.firstIndex(of: tab) else { return nil }
        let widths = tabs.map { bar.widths[$0] ?? 0 }
        // How far along the row a tab pushes the ones after it.
        let strides = widths.map { $0 + bar.spacing }
        let before = strides[..<source].reduce(0, +)
        let after = strides[(source + 1)...].reduce(0, +)

        // The pointer's travel, plus the row's as it scrolled under the pointer.
        var offset = translation + bar.scrollOffset - startScrollOffset
        // The tab stays in view when the pointer leaves the bar, which scrolls it...
        if bar.barWidth > 0 {
            let leading = bar.scrollOffset - (bar.inset + before)
            offset = max(min(offset, leading + bar.barWidth - widths[source]), leading)
        }
        // ...and stops at the ends of the row.
        offset = min(max(offset, -before), after)

        // A neighbor is passed once the dragged tab's leading or trailing edge crosses its middle.
        let neighbors = offset > 0 ? Array((source + 1)..<tabs.count) : Array((0..<source).reversed())
        var destination = source
        var passed: CGFloat = 0
        for index in neighbors {
            guard abs(offset) > passed + bar.spacing + widths[index] / 2 else { break }
            passed += strides[index]
            destination = index
        }

        var offsets = [tab: offset]
        let slot = destination > source ? -strides[source] : strides[source]
        for index in min(source, destination)...max(source, destination) where index != source {
            offsets[tabs[index]] = slot
        }
        return (destination, offsets)
    }

    /// Where the row should be scrolled to after `elapsed` seconds of the tab being
    /// held near an end of the bar, faster the further the pointer goes; `nil` when
    /// the row has no need to move.
    func autoscrollOffset(in bar: TabBarLayout<Tab>, elapsed: TimeInterval) -> CGFloat? {
        guard bar.barWidth > 0 else { return nil }
        // How close to an end of the bar the pointer starts scrolling it.
        let zone: CGFloat = 40
        // Scrolling speed, in points per second for each point the pointer is into the zone.
        let rate: CGFloat = 10
        // Only towards the side the tab has been dragged to: picking up a tab that
        // sits at an end of the bar shouldn't scroll it straight away.
        var depth: CGFloat = 0
        if translation > 0 {
            depth = max(location - (bar.barWidth - zone), 0)
        } else if translation < 0 {
            depth = min(location - zone, 0)
        }
        let speed = min(max(depth, -2 * zone), 2 * zone) * rate

        let rowWidth = bar.tabs.reduce(2 * bar.inset - bar.spacing) { $0 + (bar.widths[$1] ?? 0) + bar.spacing }
        let target = min(max(bar.scrollOffset + speed * CGFloat(elapsed), 0), max(rowWidth - bar.barWidth, 0))
        return target == bar.scrollOffset ? nil : target
    }
}

enum TabDragEvent {
    /// The pointer's travel since the drag began, and its position in the tab bar.
    case moved(translation: CGFloat, location: CGFloat)
    case dropped(translation: CGFloat)
    /// The drag stopped without a drop.
    case cancelled
}

private struct EditorTab: View {
    let url: URL
    let isActive: Bool
    let isDirty: Bool
    /// Deleted or moved on disk since it was opened.
    let isMissing: Bool
    let select: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    let revealInTree: (() -> Void)?
    /// Reports a drag along the tab bar, which moves the tab to another place in it.
    let drag: (TabDragEvent) -> Void

    @State private var isHovering = false
    @GestureState private var isDragging = false

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(url: url)
                .font(.caption)
            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .strikethrough(isMissing)
                .help(isMissing ? String(localized: "Deleted from disk. Save to write it again.") : "")

            ZStack {
                if isDirty && !isHovering {
                    Circle()
                        .fill(.primary.opacity(0.7))
                        .frame(width: 7, height: 7)
                } else {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .opacity(isActive || isHovering ? 1 : 0)
                    .help("Close")
                }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .foregroundStyle(isActive ? .primary : .secondary)
        .glassSurface(isActive, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: select)
        // Measured in the bar, as the tab moves with the drag. The tab bar keeps the
        // drag from moving the window as well.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: EditorTabBar.space)
                .updating($isDragging) { _, state, _ in state = true }
                .onChanged { drag(.moved(translation: $0.translation.width, location: $0.location.x)) }
                .onEnded { drag(.dropped(translation: $0.translation.width)) }
        )
        // A cancelled gesture resets its state without calling `onEnded`.
        .onChange(of: isDragging) { _, isDragging in
            if !isDragging { drag(.cancelled) }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Close", action: close)
            Button("Close Others", action: closeOthers)
            if !url.isUntitled {
                Divider()
                if let revealInTree {
                    Button("Reveal in Explorer", action: revealInTree)
                }
                Button("Show in Finder") { Finder.reveal(url) }
                Button("Copy Path") { Finder.copyPath(url) }
            }
        }
    }
}

// MARK: - Buffer

private struct BufferView: View {
    let buffer: EditorBuffer
    let workspace: WorkspaceModel

    var body: some View {
        switch buffer.content {
        case .text(let controller):
            if buffer.isShowingPreview, let preview = buffer.preview {
                PreviewHost(preview: preview)
            } else {
                // Keep the floating status bar clear of the scrollbar and minimap.
                TextViewHost(controller: controller)
                    .overlay(alignment: .bottomTrailing) {
                        StatusBar(buffer: buffer, workspace: workspace)
                            .padding(4)
                            .padding(
                                .trailing,
                                (EditorSettings.shared.showsMinimap ? MinimapView.width : 0)
                                    + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
                            )
                    }
            }
        case .image(let file):
            ImagePreview(file: file)
        case .pdf(let file):
            PDFPreview(file: file, name: buffer.name)
        case .binary:
            ContentUnavailableView(
                "Binary File",
                systemImage: "doc.questionmark",
                description: Text("“\(buffer.name)” isn’t a text file, so it can’t be shown in the editor.")
            )
        case .tooLarge(let size):
            ContentUnavailableView(
                "File Too Large",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text("“\(buffer.name)” is \(size.formatted(.byteCount(style: .file))), which is too large to open here.")
            )
        case .unreadable(let message):
            ContentUnavailableView(
                "Can’t Read File",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}

// MARK: - Status bar

/// Cursor position, indentation, encoding, line endings and language, in a small
/// line over the bottom-right corner of the editor.
private struct StatusBar: View {
    let buffer: EditorBuffer
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: workspace.showGoToLine) {
                Text(position)
            }
            .buttonStyle(.plain)
            .help("Go to Line (⌘L)")
            Text(buffer.indentation.usesTabs ? String(localized: "Tabs") : String(localized: "Spaces: \(buffer.indentation.width)"))
            Text(buffer.encodingName)
            Text(buffer.lineEndingName)
            Text(buffer.language?.displayName ?? String(localized: "Plain Text"))
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassSurface(in: .capsule)
        .fixedSize()
    }

    private var position: String {
        let cursor = buffer.cursor
        let base = String(localized: "Ln \(cursor.line), Col \(cursor.column)")
        return cursor.selectedLength > 0 ? base + String(localized: " (\(cursor.selectedLength) selected)") : base
    }
}

// MARK: - Preview

/// Source / Preview switch for rendered tabs, in the quiet icon style of the
/// other title bar buttons; the current mode is drawn in the primary color on a soft fill.
private struct PreviewModeToggle: View {
    let buffer: EditorBuffer
    let format: PreviewFormat

    var body: some View {
        HStack(spacing: 2) {
            option("doc.plaintext", help: "Show \(format.sourceName) (⇧⌘V)", isOn: !buffer.isShowingPreview) {
                buffer.setShowingPreview(false)
            }
            option("eye", help: "Show Preview (⇧⌘V)", isOn: buffer.isShowingPreview) {
                buffer.setShowingPreview(true)
            }
        }
    }

    private func option(_ symbol: String, help: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isOn ? .primary : .secondary)
        .background {
            if isOn {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(0.08))
            }
        }
        .help(Text(help))
    }
}

// MARK: - Image

/// Shows an image file fitted to the editor card, never enlarged past one image
/// pixel per point (VS Code's and Preview's 100%), over a checkerboard so
/// transparent areas are visible.
private struct ImagePreview: View {
    let file: EditorBuffer.ImageFile

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: file.image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .background(Checkerboard())
                .overlay(Rectangle().strokeBorder(.separator, lineWidth: 1))
                .frame(maxWidth: file.pixelSize.width, maxHeight: file.pixelSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(details)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private var details: String {
        let size = "\(Int(file.pixelSize.width)) × \(Int(file.pixelSize.height)) px"
        return [size, file.format, file.byteCount.formatted(.byteCount(style: .file))].joined(separator: "  ·  ")
    }
}

/// Light and dark squares behind transparent pixels, as image editors draw them.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 8
            for row in 0..<Int((size.height / square).rounded(.up)) {
                for column in 0..<Int((size.width / square).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)
                    context.fill(Path(rect), with: .color(.primary.opacity(0.06)))
                }
            }
        }
    }
}

// MARK: - PDF

/// Shows a PDF's pages in the editor card, with its page count and size over the
/// corner where text files have their status bar. A password-protected PDF asks
/// for its password first.
private struct PDFPreview: View {
    let file: EditorBuffer.PDFFile
    let name: String

    var body: some View {
        if file.isLocked {
            PDFPasswordPrompt(file: file, name: name)
                // Each locked tab keeps its own half-typed password.
                .id(ObjectIdentifier(file))
        } else {
            PDFViewHost(pdfView: file.view)
                .overlay(alignment: .bottomTrailing) {
                    Text(details)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassSurface(in: .capsule)
                        .fixedSize()
                        .padding(4)
                }
        }
    }

    private var details: String {
        let pages = file.pageCount == 1 ? String(localized: "1 page") : String(localized: "\(file.pageCount) pages")
        return [pages, file.byteCount.formatted(.byteCount(style: .file))].joined(separator: "  ·  ")
    }
}

/// Stands in for a protected PDF's pages until the right password is entered.
private struct PDFPasswordPrompt: View {
    let file: EditorBuffer.PDFFile
    let name: String

    @State private var password = ""
    @State private var wasRejected = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Password Required", systemImage: "lock.doc")
        } description: {
            Text(wasRejected ? String(localized: "That password didn’t unlock “\(name)”.") : String(localized: "“\(name)” is password-protected."))
        } actions: {
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($isFocused)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock)
                    .disabled(password.isEmpty)
            }
        }
        .onAppear { isFocused = true }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        wasRejected = !file.unlock(with: password)
        if wasRejected { password = "" }
    }
}

/// Hosts whichever PDF tab's view is active.
private struct PDFViewHost: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if pdfView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        pdfView.removeFromSuperview()
        pdfView.frame = container.bounds
        pdfView.autoresizingMask = [.width, .height]
        container.addSubview(pdfView)
        // So the arrow keys, Page Up and Page Down scroll it straight away.
        DispatchQueue.main.async { [pdfView] in
            pdfView.window?.makeFirstResponder(pdfView)
        }
    }
}

// MARK: - Empty state

private struct EmptyEditorView: View {
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 24) {
            // The app icon, as on the welcome window; it carries its own margin.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)

            VStack(spacing: 6) {
                Text(workspace.name)
                    .font(.title2.weight(.semibold))
                if !workspace.isStandalone {
                    Text("Select a file in the sidebar to start editing.")
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if workspace.isStandalone {
                    shortcut("New File", keys: "⌘N")
                } else {
                    shortcut("Quick Open", keys: "⌘P")
                }
                shortcut("Open Another Project", keys: "⌘O")
                if !workspace.isStandalone {
                    shortcut("Toggle Sidebar", keys: "⌃⌘S")
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ title: LocalizedStringKey, keys: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(keys)
                .monospaced()
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .glassSurface(in: .capsule)
        }
    }
}
