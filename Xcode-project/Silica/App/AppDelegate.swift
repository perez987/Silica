import AppKit

private let serviceProvider = ServiceProvider()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window shows, so none flashes in the other appearance.
        EditorSettings.shared.applyAppearance()
    }

    /// Files and folders from Finder's Open With, the Dock icon or `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpener.shared.open(urls)
    }
    
    /// Register Open in Silica service at launch
    /// If fails, run `/System/Library/CoreServices/pbs -flush;killall Finder`
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    /// Quitting asks about unsaved files in each project window first, in a sheet,
    /// so the answer comes back later.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard UnsavedChangesGuard.GuardView.hasUnsavedChanges else { return .terminateNow }
        UnsavedChangesGuard.GuardView.confirmQuitting { proceed in
            NSApp.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }
}
