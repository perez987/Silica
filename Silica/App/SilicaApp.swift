import SwiftUI

enum WindowID {
    static let welcome = "welcome"
    static let workspace = "workspace"
    static let settings = "settings"
}

@main
struct SilicaApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        EditorSettings.shared.installKeyboardShortcuts()
        MenuShortcutRefresh.install()
        KeyWorkspace.shared.installKeyboardShortcuts()
        // Starts Sparkle, which schedules the daily update check.
        _ = AppUpdater.shared
    }

    var body: some Scene {
        Window("Welcome to Silica", id: WindowID.welcome) {
            WelcomeView()
                .frame(width: 780, height: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.center)
        .defaultLaunchBehavior(EditorSettings.shared.showsWelcomeAtLaunch ? .automatic : .suppressed)
        .restorationBehavior(.disabled)
        // Files and folders from Finder go to AppDelegate/ExternalOpener; without
        // this, SwiftUI also brings up this window for each of them.
        .handlesExternalEvents(matching: [])

        WindowGroup("Workspace", id: WindowID.workspace, for: RecentProject.ID.self) { $projectID in
            WorkspaceWindow(projectID: projectID)
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .handlesExternalEvents(matching: [])
        .commands {
            TextEditingCommands()
            AppCommands()
        }

        // A regular window rather than a Settings scene: SwiftUI keeps Settings windows a
        // fixed size. AppCommands opens it from ⌘, and About Silica.
        Window("Settings", id: WindowID.settings) {
            SettingsView()
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])
        .commandsRemoved()
    }
}
