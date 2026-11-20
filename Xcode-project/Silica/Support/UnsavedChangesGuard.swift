import AppKit
import SwiftUI

/// Keeps a project window from closing, and the app from quitting, without asking
/// about unsaved files. Also shows the dot in the window's close button while any
/// file is edited, as document windows do.
///
/// SwiftUI owns the window's delegate, so a proxy is put in front of it: it answers
/// `windowShouldClose(_:)` and forwards everything else to SwiftUI's delegate.
struct UnsavedChangesGuard: NSViewRepresentable {
    let workspace: WorkspaceModel
    let hasUnsavedChanges: Bool

    func makeNSView(context: Context) -> GuardView {
        GuardView(workspace: workspace)
    }

    func updateNSView(_ nsView: GuardView, context: Context) {
        nsView.workspace = workspace
        nsView.installDelegateProxy()
        nsView.window?.isDocumentEdited = hasUnsavedChanges
    }

    final class GuardView: NSView {
        weak var workspace: WorkspaceModel?
        private var proxy: WindowDelegateProxy?

        /// Every project window currently on screen, for the quit check.
        private static let all = NSHashTable<GuardView>.weakObjects()

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
            if window != nil {
                Self.all.add(self)
                installDelegateProxy()
                window?.isDocumentEdited = workspace?.hasUnsavedChanges == true
            } else {
                Self.all.remove(self)
            }
        }

        /// Puts the proxy in front of the window's delegate, again if SwiftUI has
        /// replaced it since.
        func installDelegateProxy() {
            guard let window, proxy == nil || window.delegate !== proxy else { return }
            let proxy = WindowDelegateProxy(
                original: window.delegate,
                needsConfirmation: { [weak self] in self?.workspace?.hasUnsavedChanges == true },
                confirm: { [weak self] window, proceed in
                    guard let workspace = self?.workspace else { return proceed(true) }
                    workspace.confirmClosing(in: window, completion: proceed)
                }
            )
            self.proxy = proxy
            window.delegate = proxy
        }

        // MARK: Quitting

        /// Asks about unsaved files in each project window in turn. `completion(false)`
        /// if the user cancelled in any of them.
        static func confirmQuitting(completion: @escaping (Bool) -> Void) {
            confirm(pending[...], completion: completion)
        }

        static var hasUnsavedChanges: Bool { !pending.isEmpty }

        private static var pending: [GuardView] {
            all.allObjects.filter { $0.window != nil && $0.workspace?.hasUnsavedChanges == true }
        }

        private static func confirm(_ views: ArraySlice<GuardView>, completion: @escaping (Bool) -> Void) {
            guard let view = views.first else { return completion(true) }
            guard let window = view.window, let workspace = view.workspace else {
                return confirm(views.dropFirst(), completion: completion)
            }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            workspace.confirmClosing(in: window) { proceed in
                if proceed {
                    confirm(views.dropFirst(), completion: completion)
                } else {
                    completion(false)
                }
            }
        }
    }
}

/// Stands in as a window's delegate: decides whether the window may close, and
/// passes every other delegate call to the original delegate.
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    private weak var original: (any NSWindowDelegate)?
    private let needsConfirmation: () -> Bool
    private let confirm: (NSWindow, @escaping (Bool) -> Void) -> Void
    /// Set once the user has answered, for the close that follows.
    private var isConfirmed = false
    private var isAsking = false

    init(
        original: (any NSWindowDelegate)?,
        needsConfirmation: @escaping () -> Bool,
        confirm: @escaping (NSWindow, @escaping (Bool) -> Void) -> Void
    ) {
        self.original = original
        self.needsConfirmation = needsConfirmation
        self.confirm = confirm
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isConfirmed || !needsConfirmation() {
            isConfirmed = false
            return original?.windowShouldClose?(sender) ?? true
        }
        guard !isAsking else { return false }
        isAsking = true
        // Asked in a sheet, so the answer comes later; close again once it's yes.
        confirm(sender) { [weak self, weak sender] proceed in
            guard let self else { return }
            self.isAsking = false
            guard proceed, let sender else { return }
            self.isConfirmed = true
            DispatchQueue.main.async { sender.performClose(nil) }
        }
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
