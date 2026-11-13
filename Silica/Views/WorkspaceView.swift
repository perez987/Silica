import AppKit
import SwiftUI

/// Window root for a workspace: resolves the project bookmark, then shows the editor.
struct WorkspaceWindow: View {
    let projectID: RecentProject.ID?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: WorkspaceModel?
    @State private var errorMessage: String?

    @MainActor private static var openCount = 0

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Can’t Open Project", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Open Project…") { ProjectOpener(openWindow: openWindow).chooseAndOpen() }
                        .buttonStyle(.glassProminent)
                }
                .frame(minWidth: 500, minHeight: 360)
            } else {
                // Must be a real view: onAppear doesn't fire on an empty Group.
                ProgressView()
                    .frame(minWidth: 500, minHeight: 360)
            }
        }
        .containerBackground(for: .window) {
            WindowBackground()
        }
        .onAppear {
            ExternalOpener.shared.openWindow = openWindow
            Self.openCount += 1
            dismissWindow(id: WindowID.welcome)
            load()
        }
        .onDisappear {
            if let workspace, KeyWorkspace.shared.current === workspace {
                KeyWorkspace.shared.current = nil
            }
            if let workspace { ExternalOpener.shared.workspaceDidClose(workspace) }
            workspace?.close()
            Self.openCount -= 1
            if Self.openCount == 0 {
                openWindow(id: WindowID.welcome)
            }
        }
    }

    private func load() {
        guard workspace == nil else { return }
        guard let projectID else {
            // e.g. a restored window that never had a project: just close it.
            dismiss()
            return
        }
        do {
            let url = try RecentProjectsStore.shared.resolveURL(for: projectID)
            let workspace = WorkspaceModel(rootURL: url)
            self.workspace = workspace
            ExternalOpener.shared.workspaceDidOpen(workspace, projectID: projectID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum WorkspaceLayout {
    /// Height of the title bar row that holds the traffic lights and the tabs.
    static let titleBarHeight: CGFloat = 36
    /// Room for the traffic lights when the sidebar is hidden.
    static let trafficLightsWidth: CGFloat = 78
    /// Smallest corner radius of the editor card; corners near the window's are concentric with it.
    static let cardCornerRadius: CGFloat = 10
    static let cardInset: CGFloat = 6
    /// How much of the sidebar list's built-in top inset to hide.
    static let sidebarListTopTrim: CGFloat = 8
    static let sidebarWidthRange: ClosedRange<Double> = 220...480
}

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260
    @State private var dragStartWidth: Double?

    var body: some View {
        HStack(spacing: 0) {
            if workspace.isSidebarVisible {
                FileTreeView(workspace: workspace)
                    .frame(width: min(max(sidebarWidth, WorkspaceLayout.sidebarWidthRange.lowerBound), WorkspaceLayout.sidebarWidthRange.upperBound))
                    .overlay(alignment: .trailing) { resizeHandle }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            EditorArea(workspace: workspace)
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if workspace.isQuickOpenVisible {
                QuickOpenOverlay(workspace: workspace)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(workspace.name)
        .background(KeyWindowTracker(workspace: workspace))
        .background(UnsavedChangesGuard(workspace: workspace, hasUnsavedChanges: workspace.hasUnsavedChanges))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refresh()
        }
    }

    /// Invisible strip on the sidebar's trailing edge that resizes it.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .offset(x: 4)
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? sidebarWidth
                        dragStartWidth = start
                        let proposed = start + value.translation.width
                        sidebarWidth = min(max(proposed, WorkspaceLayout.sidebarWidthRange.lowerBound),
                                           WorkspaceLayout.sidebarWidthRange.upperBound)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

struct SidebarToggleButton: View {
    let workspace: WorkspaceModel

    var body: some View {
        Button {
            workspace.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.titleBarIcon)
        .foregroundStyle(.secondary)
        .help(workspace.isSidebarVisible ? String(localized: "Hide Sidebar (⌃⌘S)") : String(localized: "Show Sidebar (⌃⌘S)"))
    }
}

struct TitleBarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconLabel(configuration: configuration)
    }

    private struct IconLabel: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(width: 26, height: 22)
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.14 : isHovering ? 0.08 : 0),
                    in: .rect(cornerRadius: 6, style: .continuous)
                )
                .contentShape(.rect(cornerRadius: 6, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

extension ButtonStyle where Self == TitleBarIconButtonStyle {
    static var titleBarIcon: TitleBarIconButtonStyle { TitleBarIconButtonStyle() }
}
