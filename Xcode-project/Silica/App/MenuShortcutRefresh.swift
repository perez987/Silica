import AppKit

/// Keeps menu keyboard shortcuts in step with the app's state.
///
/// SwiftUI refreshes its menu items' enabled state only when a menu is about to
/// open, so a shortcut could hit an item that was still disabled from earlier:
/// ⌘S right after typing, ⌘P once a project window came forward, ⌘0 after
/// zooming. Before AppKit matches a key equivalent, every menu is asked to update.
enum MenuShortcutRefresh {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            if !flags.isEmpty, let menu = NSApp.mainMenu {
                refresh(menu)
            }
            return event
        }
    }

    private static func refresh(_ menu: NSMenu) {
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            submenu.delegate?.menuNeedsUpdate?(submenu)
            refresh(submenu)
        }
    }
}
