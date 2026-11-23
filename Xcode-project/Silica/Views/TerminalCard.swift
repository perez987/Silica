import AppKit
import SwiftUI

/// The integrated terminal: a glass card under the editor's, with a header that
/// names what's running, or has a tab for each terminal once there are several, and
/// the terminal that's showing below.
struct TerminalCard: View {
    let session: TerminalSession
    let workspace: WorkspaceModel
    @Environment(\.colorScheme) private var colorScheme
    private var settings: EditorSettings { .shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalViewHost(view: session.view)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if !settings.usesGlassEffect {
                colorScheme == .dark ? Color.black : Color.white
            }
        }
        .workspaceCard()
    }

    private var header: some View {
        let hasTabs = workspace.terminals.count > 1
        return HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if hasTabs {
                    // Kept in place under a link's destination, so the row is
                    // scrolled where it was once the pointer leaves the link.
                    TerminalTabBar(workspace: workspace)
                        .opacity(session.linkDestination == nil ? 1 : 0)
                        .allowsHitTesting(session.linkDestination == nil)
                }
                // A terminal by itself needs no tab, only its name. Over a link,
                // where it leads takes the place of either: the link's text needn't say.
                if let destination = session.linkDestination {
                    label("link", destination)
                } else if !hasTabs {
                    // Shells name the terminal after the folder or the command that's running.
                    label("terminal", session.name)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                workspace.newTerminal()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.titleBarIcon)
            .help("New Terminal (⌃⇧`)")
            Button {
                workspace.closeTerminal()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.titleBarIcon)
            .help("Kill Terminal")
            Button {
                workspace.hideTerminal()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.titleBarIcon)
            .help("Hide Terminal (⌃`)")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: 30)
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
            Text(text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        // In line with the first tab's, which take its place.
        .padding(.leading, 8)
        .padding(.trailing, 2)
    }
}

/// The terminals' tabs, in the card's header once there's more than one. A smaller
/// relative of the editor's tab bar: the row scrolls when it has more tabs than fit,
/// a drag moves a tab along it, and a middle click closes one.
private struct TerminalTabBar: View {
    let workspace: WorkspaceModel

    /// The tab being dragged to a new place, and how far the pointer has carried it.
    @State private var drag: TabDrag<TerminalSession.ID>?
    /// Each tab's laid-out width, to tell which tabs a dragged one has passed and
    /// which tab a middle click is on.
    @State private var tabWidths: [TerminalSession.ID: CGFloat] = [:]
    /// Width of the part of the row that shows, and how far the row is scrolled under it.
    @State private var barWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    /// Scrolls the row during a drag; showing the selected tab still goes through the reader.
    @State private var scrollPosition = ScrollPosition(idType: Never.self)
    /// How much each end of the row is faded: fully once tabs are scrolled out past it.
    @State private var edgeFades = EdgeFades()

    /// The bar's own space, which stays put while the row scrolls and the tabs move.
    static let space: NamedCoordinateSpace = .named("TerminalTabBar")

    private static let spacing: CGFloat = 2
    private static let reorderAnimation = Animation.snappy(duration: 0.2)
    /// How far in from an end of the bar the row fades out.
    private static let fadeWidth: CGFloat = 12

    var body: some View {
        let offsets = drag?.reorder(in: layout)?.offsets ?? [:]
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Self.spacing - 2 * Self.fadeWidth) {
                    ForEach(workspace.terminals) { terminal in
                        let offset = offsets[terminal.id] ?? 0
                        let isDragged = drag?.tab == terminal.id
                        TerminalTab(
                            session: terminal,
                            isSelected: terminal === workspace.terminal,
                            select: { workspace.selectTerminal(terminal) },
                            close: { workspace.closeTerminal(terminal) },
                            drag: { handleDrag($0, of: terminal, proxy: proxy) }
                        )
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.width
                        } action: {
                            tabWidths[terminal.id] = $0
                        }
                        // Room on either side that the row scrolls into view with the
                        // tab, so that it comes to rest clear of the faded ends of the
                        // bar. The row's spacing and padding take the same room back out.
                        .padding(.horizontal, Self.fadeWidth)
                        .offset(x: offset)
                        .zIndex(isDragged ? 1 : 0)
                        // The dragged tab stays under the pointer; the others slide out of its way.
                        .animation(
                            isDragged ? nil : Self.reorderAnimation,
                            value: offset
                        )
                        .id(terminal.id)
                    }
                }
                .padding(.horizontal, -Self.fadeWidth)
                // Room for the selected tab's glass, which reaches past its edges.
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.x
            } action: { _, offset in
                scrollOffset = offset
            }
            .onScrollGeometryChange(for: EdgeFades.self) { geometry in
                let offset = geometry.contentOffset.x
                let hiddenAfter =
                    geometry.contentSize.width - geometry.containerSize.width
                    - offset
                return EdgeFades(
                    leading: offset,
                    trailing: hiddenAfter,
                    over: Self.fadeWidth
                )
            } action: { _, fades in
                edgeFades = fades
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                barWidth = $0
            }
            .mask { fadeMask }
            .background(WheelScrollsSideways())
            .background(
                MiddleClickClosesTab(tab: tab(at:)) { id in
                    if let terminal = workspace.terminals.first(where: {
                        $0.id == id
                    }) {
                        workspace.closeTerminal(terminal)
                    }
                }
            )
            .coordinateSpace(Self.space)
            .onAppear {
                if let selected = workspace.terminal {
                    proxy.scrollTo(selected.id)
                }
            }
            .onChange(of: workspace.terminal?.id) { _, selected in
                if let selected {
                    withAnimation { proxy.scrollTo(selected) }
                }
            }
            .onChange(of: workspace.terminals.map(\.id)) { _, ids in
                tabWidths = tabWidths.filter { ids.contains($0.key) }
                // The dragged tab's shell can exit mid-drag, which removes its view
                // before the gesture can end or cancel.
                if let drag, !ids.contains(drag.tab) { self.drag = nil }
            }
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

    private func handleDrag(
        _ event: TabDragEvent,
        of terminal: TerminalSession,
        proxy: ScrollViewProxy
    ) {
        let id = terminal.id
        switch event {
        case .moved(let translation, let location):
            if let drag, drag.tab == id {
                self.drag = TabDrag(
                    tab: id,
                    translation: translation,
                    location: location,
                    startScrollOffset: drag.startScrollOffset
                )
            } else {
                // Dragging a tab brings its terminal forward, as clicking it does.
                workspace.selectTerminal(terminal)
                drag = TabDrag(
                    tab: id,
                    translation: translation,
                    location: location,
                    startScrollOffset: scrollOffset
                )
            }
        case .dropped(let translation):
            guard var dropped = drag, dropped.tab == id else { return }
            dropped.translation = translation
            let destination = dropped.reorder(in: layout)?.destination
            // The new order and the end of the drag go in one animation, so every tab
            // settles from where the drag left it instead of jumping to its new place.
            withAnimation(Self.reorderAnimation) {
                if let destination {
                    workspace.moveTerminal(terminal, to: destination)
                }
                drag = nil
            }
            // Its new place can reach past the end of the bar. Once the row is laid out
            // in its new order: asked in the same pass, the reader goes to where the
            // tab was, which a drag that scrolled the row has left far behind.
            DispatchQueue.main.async {
                withAnimation(Self.reorderAnimation) { proxy.scrollTo(id) }
            }
        case .cancelled:
            if drag?.tab == id {
                withAnimation(Self.reorderAnimation) { drag = nil }
            }
        }
    }

    /// The row as it's laid out now, for a drag or a middle click to be worked out from.
    private var layout: TabBarLayout<TerminalSession.ID> {
        TabBarLayout(
            tabs: workspace.terminals.map(\.id),
            widths: tabWidths,
            spacing: Self.spacing,
            inset: 0,
            barWidth: barWidth,
            scrollOffset: scrollOffset
        )
    }

    /// Scrolls the row while a tab is held near an end of the bar, so a tab can be
    /// taken past the ones that fit in the bar.
    private func autoscroll(elapsed: TimeInterval) {
        guard let target = drag?.autoscrollOffset(in: layout, elapsed: elapsed)
        else { return }
        scrollPosition.scrollTo(x: target)
        // Ahead of the scroll view reporting it, so the tab doesn't trail the row by a frame.
        scrollOffset = target
    }

    /// Opaque across the bar, clearing towards an end that has tabs scrolled out past it.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(1 - edgeFades.leading), .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Self.fadeWidth)
            Color.black
            LinearGradient(
                colors: [.black, .black.opacity(1 - edgeFades.trailing)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Self.fadeWidth)
        }
    }

    /// The tab at a horizontal position in the bar, if there's one.
    private func tab(at x: CGFloat) -> TerminalSession.ID? {
        // The tabs are out of their places during a drag.
        drag == nil ? layout.tab(at: x) : nil
    }
}

private struct TerminalTab: View {
    let session: TerminalSession
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    /// Reports a drag along the tab bar, which moves the tab to another place in it.
    let drag: (TabDragEvent) -> Void

    @State private var isHovering = false
    @GestureState private var isDragging = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption)
            Text(session.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        // A long title, such as a path, doesn't crowd the other tabs out.
        .frame(maxWidth: 180)
        .foregroundStyle(isSelected ? .primary : .secondary)
        // Under the pointer, a tab gets a fainter fill than the title bar's buttons do.
        .background(
            Color.primary.opacity(!isSelected && isHovering ? 0.05 : 0),
            in: .rect(cornerRadius: 6, style: .continuous)
        )
        .glassSurface(
            isSelected,
            in: .rect(cornerRadius: 6, style: .continuous)
        )
        .contentShape(.rect(cornerRadius: 6, style: .continuous))
        .onTapGesture(perform: select)
        // Measured in the bar, as the tab moves with the drag.
        .gesture(
            DragGesture(
                minimumDistance: 1,
                coordinateSpace: TerminalTabBar.space
            )
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged {
                drag(
                    .moved(
                        translation: $0.translation.width,
                        location: $0.location.x
                    )
                )
            }
            .onEnded { drag(.dropped(translation: $0.translation.width)) }
        )
        // A cancelled gesture resets its state without calling `onEnded`.
        .onChange(of: isDragging) { _, isDragging in
            if !isDragging { drag(.cancelled) }
        }
        .onHover { isHovering = $0 }
        .help(session.name)
        .contextMenu {
            Button("Kill Terminal", action: close)
        }
    }
}

/// Shows and hides the terminal from the title bar: the bottom card's counterpart to
/// the sidebar's toggle at the other end of the row.
struct TerminalToggleButton: View {
    let workspace: WorkspaceModel

    var body: some View {
        Button {
            // Unlike ⌃`, which goes to a terminal that's showing but doesn't have
            // the keyboard, a click on this always shows or hides.
            if workspace.isTerminalVisible {
                workspace.hideTerminal()
            } else {
                workspace.showTerminal()
            }
        } label: {
            Image(systemName: "terminal")
        }
        .buttonStyle(.titleBarIcon)
        // Tinted while it's on, like the Search button in the sidebar's header.
        .foregroundStyle(
            workspace.isTerminalVisible
                ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
        )
        .help(
            workspace.isTerminalVisible
                ? String(localized: "Hide Terminal (⌃`)")
                : String(localized: "Show Terminal (⌃`)")
        )
    }
}

/// Puts the session's own view in the card. The view outlives the card: hiding the
/// terminal takes the card away, and showing it again brings the same view back.
private struct TerminalViewHost: NSViewRepresentable {
    let view: TerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
