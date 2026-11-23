import AppKit
import SwiftUI

/// Opens what's handed to Silica from outside the project tree: Finder's Open With,
/// files dropped on the Dock icon or the welcome window, the Open panel, `open -a`.
///
/// A folder opens as a project. A file opens as a tab in the open project that
/// contains it; otherwise in a window for the recent project or git repository it
/// belongs to, or else for the folder it's in.
final class ExternalOpener {
    static let shared = ExternalOpener()
    private init() {}

    /// SwiftUI's window opener, handed over by the menu commands (which exist even
    /// with no window open, as when Finder launches Silica with a file) and by the
    /// windows: the app delegate, where Finder's requests arrive, has no environment
    /// to read it from.
    var openWindow: OpenWindowAction? {
        // Later, as this can be set while SwiftUI is building the menus.
        didSet { DispatchQueue.main.async { self.flush() } }
    }

    /// For the menu commands, whose body runs on every update: sets the opener
    /// only the first time.
    func provide(_ openWindow: OpenWindowAction) {
        if self.openWindow == nil { self.openWindow = openWindow }
    }

    /// Requests that came in before any window could open others (at launch).
    private var queued: [URL] = []
    /// Files to open once their project's window has loaded.
    private var pendingFiles: [RecentProject.ID: [URL]] = [:]
    private var workspaces: [WeakWorkspace] = []

    private struct WeakWorkspace {
        weak var workspace: WorkspaceModel?
    }

    func open(_ urls: [URL]) {
        queued += urls
        flush()
    }

    // MARK: Project windows

    /// Called by a project window once its workspace has loaded; opens the files
    /// that were waiting for it.
    func workspaceDidOpen(_ workspace: WorkspaceModel, projectID: RecentProject.ID) {
        workspaces.removeAll { $0.workspace == nil }
        workspaces.append(WeakWorkspace(workspace: workspace))
        for url in pendingFiles.removeValue(forKey: projectID) ?? [] {
            open(url, in: workspace)
        }
    }

    func workspaceDidClose(_ workspace: WorkspaceModel) {
        workspaces.removeAll { $0.workspace == nil || $0.workspace === workspace }
    }

    // MARK: Opening

    private func flush() {
        guard let openWindow, !queued.isEmpty else { return }
        let urls = queued
        queued = []
        for url in urls {
            open(url, openWindow: openWindow)
        }
    }

    private func open(_ url: URL, openWindow: OpenWindowAction) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
            ProjectOpener(openWindow: openWindow).open(url: url)
            return
        }
        if let workspace = openWorkspace(containing: url) {
            open(url, in: workspace)
            workspace.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let project = try RecentProjectsStore.shared.register(Self.projectFolder(for: url))
            pendingFiles[project.id, default: []].append(url)
            openWindow(id: WindowID.workspace, value: project.id)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Opens `url` as a tab, spelled the way the project spells its own files
    /// (e.g. `/tmp` vs `/private/tmp`) so it matches the tree's rows and other tabs.
    private func open(_ url: URL, in workspace: WorkspaceModel) {
        var target = url
        if let relative = Self.relativeComponents(of: url, in: workspace.rootURL) {
            target = relative.reduce(workspace.rootURL) { $0.appending(path: $1, directoryHint: .notDirectory) }
        }
        workspace.open(target)
        workspace.reveal(target)
    }

    /// The open project with the deepest root above `url`.
    private func openWorkspace(containing url: URL) -> WorkspaceModel? {
        workspaces
            .compactMap(\.workspace)
            .filter { Self.relativeComponents(of: url, in: $0.rootURL) != nil }
            .max { Self.components($0.rootURL).count < Self.components($1.rootURL).count }
    }

    /// The folder to open a project window on for a file no open project contains:
    /// the deepest recent project above it, else the nearest git repository below
    /// the home folder, else the file's own folder.
    private static func projectFolder(for url: URL) -> URL {
        let recent = RecentProjectsStore.shared.projects
            .map { URL(filePath: $0.path, directoryHint: .isDirectory) }
            .filter { relativeComponents(of: url, in: $0) != nil }
            .max { components($0).count < components($1).count }
        if let recent { return recent }

        let folder = url.deletingLastPathComponent()
        let home = components(URL(filePath: RealHome.path, directoryHint: .isDirectory))
        var candidate = folder
        while components(candidate).count > home.count || !components(candidate).starts(with: home) {
            guard components(candidate).count > 1 else { break }
            let git = candidate.appending(path: ".git").path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: git) { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return folder
    }

    private static func components(_ url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    }

    /// Path components of `url` below `root`, or `nil` if it isn't inside it.
    private static func relativeComponents(of url: URL, in root: URL) -> [String]? {
        let rootComponents = components(root)
        let urlComponents = components(url)
        guard urlComponents.count > rootComponents.count, urlComponents.starts(with: rootComponents) else { return nil }
        return Array(urlComponents.dropFirst(rootComponents.count))
    }
}
