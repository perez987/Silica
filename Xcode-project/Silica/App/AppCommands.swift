import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    /// The project in the key window. Tracked from AppKit key-window changes, since
    /// `focusedSceneValue` came back nil while the editor's NSTextView had focus.
    @ObservedObject private var keyWorkspace = KeyWorkspace.shared
    private var workspace: WorkspaceModel? { keyWorkspace.current }
    @ObservedObject private var updater = AppUpdater.shared

    private var recents: RecentProjectsStore { .shared }
    private var settings: EditorSettings { .shared }
    private var opener: ProjectOpener { ProjectOpener(openWindow: openWindow) }

    /// "Show Markdown" or "Show CSV" while the preview is up, to go back to the source.
    private var previewToggleTitle: String {
        guard let buffer = workspace?.activeBuffer, buffer.isShowingPreview,
            let format = buffer.previewFormat
        else { return String(localized: "Show Preview") }
        return String(localized: "Show \(format.sourceName)")
    }

    var body: some Commands {
        // Lets Finder's open requests at launch open windows before any exists.
        let _ = ExternalOpener.shared.provide(openWindow)

        // About lives in Settings, next to the open-source licenses.
        CommandGroup(replacing: .appInfo) {
            Button("About Silica") {
                UserDefaults.standard.set(
                    SettingsView.Pane.about.rawValue,
                    forKey: SettingsView.paneKey
                )
                openWindow(id: WindowID.settings)
            }

            Button("Check for Updates…") { updater.checkForUpdates() }
                .keyboardShortcut("u", modifiers: [.command])
                .disabled(!updater.canCheckForUpdates)
        }

        // Settings is a regular Window scene (so it can resize), which doesn't get
        // the Settings… item on its own.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: WindowID.settings) }
                .keyboardShortcut(",")
        }

        CommandGroup(replacing: .newItem) {
            Button("New File") {
                if let workspace {
                    workspace.newUntitledFile()
                } else {
                    openWindow(id: WindowID.untitled, value: UUID())
                }
            }
            .keyboardShortcut("n")

            Button("New File in Project…") {
                workspace?.beginNewItem(isDirectory: false)
            }
            .disabled(workspace?.isStandalone != false)

            Button("New Folder") { workspace?.beginNewItem(isDirectory: true) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(workspace?.isStandalone != false)

            Divider()

            Button("Open…") { opener.chooseAndOpen() }
                .keyboardShortcut("o")

            Menu("Open Recent") {
                ForEach(recents.projects) { project in
                    Button(project.name) { opener.open(project) }
                }
                Divider()
                Button("Clear Menu") { recents.clear() }
                    .disabled(recents.projects.isEmpty)
            }

            Divider()

            Button("Quick Open…") { workspace?.toggleQuickOpen() }
                .keyboardShortcut("p")
                .disabled(workspace?.isStandalone != false)

            Divider()

            Button("Welcome Window") { openWindow(id: WindowID.welcome) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }

        // No printing; ⌘P is Quick Open, as in other code editors.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(replacing: .saveItem) {
            Button("Save") { workspace?.saveActive() }
                .keyboardShortcut("s")
                .disabled(
                    workspace?.activeBuffer.map { $0.isDirty || $0.isUntitled }
                        != true
                )

            Button("Save As…") { workspace?.saveActiveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(workspace?.activeBuffer?.textController == nil)

            Button("Save All") { workspace?.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(workspace?.hasUnsavedChanges != true)

            Divider()

            // As in VS Code: ⌘W closes the tab, and the window once no tabs are left.
            Button("Close Tab") {
                if let workspace, workspace.activeTab != nil {
                    workspace.closeActiveTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")

            // ⇧⌘W is also handled by KeyWorkspace.installKeyboardShortcuts().
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .sidebar) {
            Button(
                workspace?.isSidebarVisible == false
                    ? String(localized: "Show Sidebar")
                    : String(localized: "Hide Sidebar")
            ) {
                workspace?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(workspace?.isStandalone != false)

            // ⇧⌘E, ⇧⌘F and ⇧⌘S are also handled by KeyWorkspace.installKeyboardShortcuts().
            Button("Explorer") { workspace?.showExplorer() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace?.isStandalone != false)

            Button("Find in Project") { workspace?.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace?.isStandalone != false)

            Button("Filter Files") { workspace?.focusTreeFilter() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(workspace?.isStandalone != false)

            Button("Refresh Explorer") { workspace?.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspace?.isStandalone != false)

            Divider()

            Button("Terminal") { workspace?.toggleTerminal() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(workspace == nil)

            Button("New Terminal") { workspace?.newTerminal() }
                .keyboardShortcut("`", modifiers: [.control, .shift])
                .disabled(workspace == nil)

            Button("Clear Terminal") { workspace?.terminal?.clear() }
                .keyboardShortcut("k")
                .disabled(workspace?.terminal?.isFocused != true)

            Divider()

            // ⇧⌘V itself is handled by KeyWorkspace.installKeyboardShortcuts().
            Button(previewToggleTitle) {
                workspace?.activeBuffer?.togglePreview()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(workspace?.activeBuffer?.previewFormat == nil)

            Divider()

            // The file tabs, not the window tabs of the Window menu's Show Next Tab, which
            // has ⌃Tab as well: this menu comes first, so the file tabs get the key.
            // ⇧⌘] and ⇧⌘[ do the same; see KeyWorkspace.installKeyboardShortcuts().
            // From a terminal with others beside it, they step through the terminals.
            let hasOtherTabs = workspace?.canSelectOtherTab == true

            Button("Select Next Tab") { workspace?.selectTab(offsetBy: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(!hasOtherTabs)

            Button("Select Previous Tab") { workspace?.selectTab(offsetBy: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(!hasOtherTabs)
        }

        CommandGroup(after: .sidebar) {
            Divider()

            Toggle(
                "Word Wrap",
                isOn: Binding(
                    get: { settings.wrapsLines },
                    set: { settings.wrapsLines = $0 }
                )
            )
            .keyboardShortcut("z", modifiers: .option)

            Toggle(
                "Minimap",
                isOn: Binding(
                    get: { settings.showsMinimap },
                    set: { settings.showsMinimap = $0 }
                )
            )

            Divider()

            // ⌘= also zooms in; see EditorSettings.installKeyboardShortcuts().
            Button("Increase Font Size") { settings.increaseFontSize() }
                .keyboardShortcut("+")
                .disabled(!settings.canIncreaseFontSize)

            Button("Decrease Font Size") { settings.decreaseFontSize() }
                .keyboardShortcut("-")
                .disabled(!settings.canDecreaseFontSize)

            Button("Reset Font Size") { settings.resetFontSize() }
                .keyboardShortcut("0")
                .disabled(settings.isDefaultFontSize)
        }

        CommandMenu("Editor") {
            let hasText = workspace?.activeBuffer?.textController != nil

            Button("Go to Line…") { workspace?.showGoToLine() }
                .keyboardShortcut("l")
                .disabled(!hasText)

            Divider()

            editorAction(
                "Toggle Comment",
                #selector(EditorTextView.toggleComment(_:)),
                key: "/",
                modifiers: .command
            )
            editorAction(
                "Indent",
                #selector(EditorTextView.indentLines(_:)),
                key: "]",
                modifiers: .command
            )
            editorAction(
                "Outdent",
                #selector(EditorTextView.outdentLines(_:)),
                key: "[",
                modifiers: .command
            )

            Divider()

            editorAction(
                "Move Line Up",
                #selector(EditorTextView.moveLinesUp(_:)),
                key: .upArrow,
                modifiers: .option
            )
            editorAction(
                "Move Line Down",
                #selector(EditorTextView.moveLinesDown(_:)),
                key: .downArrow,
                modifiers: .option
            )
            editorAction(
                "Duplicate Line Up",
                #selector(EditorTextView.duplicateLinesUp(_:)),
                key: .upArrow,
                modifiers: [.option, .shift]
            )
            editorAction(
                "Duplicate Line Down",
                #selector(EditorTextView.duplicateLinesDown(_:)),
                key: .downArrow,
                modifiers: [.option, .shift]
            )
        }
    }

    /// A menu item that sends `action` to the focused editor through the responder chain.
    private func editorAction(
        _ title: LocalizedStringKey,
        _ action: Selector,
        key: KeyEquivalent,
        modifiers: EventModifiers
    ) -> some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(workspace?.activeBuffer?.textController == nil)
    }
}
