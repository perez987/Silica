import AppKit

/// "Open in Silica" in Finder's Services menu: opens the selected folders as
/// projects, the same way Open With or `silica <folder>` does.
final class ServiceProvider: NSObject {
    @objc func openAsProject(_ pasteboard: NSPasteboard,
                             userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        NSApp.activate()
        ExternalOpener.shared.open(urls)
    }
}
