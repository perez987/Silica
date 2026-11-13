import AppKit
import Combine
import SwiftUI

/// The workspace whose window is key, for menu commands and shortcuts to act on.
final class KeyWorkspace: ObservableObject {
    static let shared = KeyWorkspace()
    @Published var current: WorkspaceModel?
    private init() {}

    private var keyMonitor: Any?

    /// ⇧⌘ shortcuts for the key workspace, handled here as well as in the menus
    /// because menu items bound to ⇧⌘ + a letter didn't reliably win over the plain
    /// ⌘ + letter items (⇧⌘V lost to Paste, ⇧⌘F to Find).
    func installKeyboardShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // Quick Open's field takes focus a moment after the panel appears; keys typed
            // in between (⌘L then a quick "100") belong in the query, not the editor.
            if let workspace = self?.current, workspace.isQuickOpenVisible,
               !flags.contains(.command), !flags.contains(.control),
               !((event.window?.firstResponder as? NSTextView)?.isFieldEditor ?? false),
               let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && $0.value < 0xF700 }) {
                workspace.quickOpen.query += characters
                return nil
            }
            guard flags == [.command, .shift], let workspace = self?.current,
                  // Not while a sheet or alert is up.
                  event.window?.attachedSheet == nil, NSApp.modalWindow == nil,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch key {
            case "v":
                guard let buffer = workspace.activeBuffer, buffer.previewFormat != nil else { return event }
                buffer.togglePreview()
            case "f":
                workspace.showSearch()
            case "e":
                workspace.showExplorer()
            case "s":
                guard workspace.activeBuffer?.textController != nil else { return event }
                workspace.saveActiveAs()
            case "w":
                event.window?.performClose(nil)
            // The other usual pair for stepping through tabs, next to ⌃Tab in the menu.
            case "}", "]":
                workspace.activateTab(offsetBy: 1)
            case "{", "[":
                workspace.activateTab(offsetBy: -1)
            default:
                return event
            }
            return nil
        }
    }
}

/// Invisible view that reports when its window becomes or stops being key.
struct KeyWindowTracker: NSViewRepresentable {
    let workspace: WorkspaceModel

    func makeNSView(context: Context) -> TrackerView {
        TrackerView(workspace: workspace)
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.workspace = workspace
    }

    final class TrackerView: NSView {
        weak var workspace: WorkspaceModel?

        init(workspace: WorkspaceModel) {
            self.workspace = workspace
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            workspace?.window = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification, object: window
            )
            if window.isKeyWindow { windowDidBecomeKey() }
        }

        @objc private func windowDidBecomeKey() {
            KeyWorkspace.shared.current = workspace
        }

        @objc private func windowDidResignKey() {
            if KeyWorkspace.shared.current === workspace {
                KeyWorkspace.shared.current = nil
            }
        }
    }
}
