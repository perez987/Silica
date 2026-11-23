import AppKit
import SwiftUI

/// Shared "open a project" flow used by the welcome window and the menu bar.
struct ProjectOpener {
    let openWindow: OpenWindowAction

    private var store: RecentProjectsStore { .shared }

    /// The Open panel: a folder opens as a project; files open in the project they
    /// belong to (see `ExternalOpener`).
    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose a project folder or files to open in Silica")
        guard panel.runModal() == .OK else { return }
        ExternalOpener.shared.openWindow = openWindow
        ExternalOpener.shared.open(panel.urls)
    }

    func open(url: URL) {
        do {
            let project = try store.register(url)
            openWindow(id: WindowID.workspace, value: project.id)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func open(_ project: RecentProject) {
        do {
            let url = try store.resolveURL(for: project.id)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw CocoaError(.fileNoSuchFile)
            }
            store.markOpened(project.id)
            openWindow(id: WindowID.workspace, value: project.id)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(project.name)” couldn’t be opened.")
            alert.informativeText = String(localized: "It may have been moved, renamed or deleted.")
            alert.addButton(withTitle: String(localized: "Remove from Recents"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                store.remove(project.id)
            }
        }
    }
}

enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path(percentEncoded: false), forType: .string)
    }
}
