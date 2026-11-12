import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The rendered view of one Markdown buffer, kept alive with its tab so switching
/// back and forth is instant.
///
/// The page is HTML from `MarkdownHTMLRenderer`, styled to match the editor and drawn
/// on a transparent background so the editor card shows through. Scripts in the
/// document itself never run; Silica's own small script (scroll position, double-click)
/// runs in a separate script world. Relative images load from disk through the
/// `silica-preview:` scheme, links to project files open in Silica, and web links open
/// in the browser.
final class MarkdownPreview: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: PreviewWebView

    /// Opens another file in the project (a link to it was clicked).
    var onOpenFile: ((URL) -> Void)?
    /// Double-click: edit the source at this 1-based line.
    var onEditLine: ((Int) -> Void)?
    /// A character was typed; switch to the source and insert it.
    var onType: ((String) -> Void)?

    private let fileURL: URL
    private var pendingLine: Int?
    private var baseURL: URL {
        URL(string: Self.scheme + "://local" + Self.encodedPath(fileURL.deletingLastPathComponent().path(percentEncoded: false)))!
    }

    static let scheme = "silica-preview"

    init(fileURL: URL) {
        self.fileURL = fileURL

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: Self.scheme)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient
        ))
        webView = PreviewWebView(frame: .zero, configuration: configuration)
        super.init()

        // Through a weak proxy: the content controller retains its handlers.
        configuration.userContentController.add(WeakScriptHandler(self), contentWorld: .defaultClient, name: "silica")
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        webView.onType = { [weak self] characters in self?.onType?(characters) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(syntaxThemeDidChange),
            name: .syntaxThemeDidChange, object: nil
        )
    }

    /// Swaps in the new code colors without reloading, so the scroll position stays.
    @objc private func syntaxThemeDidChange() {
        guard let data = try? JSONEncoder().encode(Self.css), let css = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("{ const style = document.querySelector('head > style'); if (style) style.textContent = \(css); }", in: nil, in: .defaultClient) { _ in }
    }

    /// Renders `markdown` and, once loaded, scrolls to the block nearest `line`.
    func show(markdown: String, line: Int) {
        pendingLine = line
        let body = MarkdownHTMLRenderer.render(markdown)
        webView.loadHTMLString(Self.page(body: body), baseURL: baseURL)
    }

    /// The 1-based source line of the first block visible at the top.
    func topVisibleLine(_ completion: @escaping (Int) -> Void) {
        webView.evaluateJavaScript("silica.topLine()", in: nil, in: .defaultClient) { result in
            completion((try? result.get()) as? Int ?? 1)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let line = pendingLine else { return }
        pendingLine = nil
        webView.evaluateJavaScript("silica.scrollToLine(\(line))", in: nil, in: .defaultClient) { _ in }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // Only the page itself loads in place (and subframes, e.g. an embedded video);
        // every other navigation is a link and is handled here instead.
        guard let url = navigationAction.request.url,
              navigationAction.targetFrame?.isMainFrame != false,
              url.absoluteString != baseURL.absoluteString, url.scheme != "about" else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)

        if url.scheme == Self.scheme {
            let path = url.path(percentEncoded: false)
            if let fragment = url.fragment, path == baseURL.path(percentEncoded: false) || path == fileURL.path(percentEncoded: false) {
                // An #anchor in this document.
                let id = fragment.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                webView.evaluateJavaScript("document.getElementById('\(id)')?.scrollIntoView()", in: nil, in: .defaultClient) { _ in }
                return
            }
            let target = URL(filePath: path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false), isDirectory: &isDirectory), !isDirectory.boolValue {
                onOpenFile?(target)
            }
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let line = message.body as? Int {
            onEditLine?(line)
        }
    }

    // MARK: Page

    private static func encodedPath(_ path: String) -> String {
        let directory = path.hasSuffix("/") ? path : path + "/"
        return directory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directory
    }

    private static func page(body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>\(css)</style></head>
        <body><article>\(body)</article></body></html>
        """
    }

    private static func hex(_ value: UInt32) -> String {
        String(format: "#%06X", value)
    }

    private static var tokenCSS: (light: String, dark: String) {
        var light = "", dark = ""
        let theme = EditorSettings.shared.syntaxTheme
        for kind in TokenKind.allCases {
            let pair = theme.hexPair(for: kind)
            light += ".tok-\(kind) { color: \(hex(pair.light)); }\n"
            dark += ".tok-\(kind) { color: \(hex(pair.dark)); }\n"
        }
        return (light, dark)
    }

    private static var css: String {
        let size = Int(EditorSettings.shared.fontSize) + 1
        // Code in the editor's font, when one is chosen in Settings.
        let codeFont = EditorSettings.shared.fontFamily.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\", " } ?? ""
        let link = EditorSettings.shared.syntaxTheme.linkPair
        let tokens = tokenCSS
        return """
        :root { color-scheme: light dark; }
        html, body { background: transparent; margin: 0; }
        body {
          font: \(size)px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
          color: rgba(0, 0, 0, 0.86);
          -webkit-font-smoothing: antialiased;
        }
        article { max-width: 860px; margin: 0 auto; padding: 24px 32px 48px; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.6em; font-weight: 650; }
        h1 { font-size: 1.9em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }
        h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid rgba(128, 128, 128, 0.25); }
        article > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        a { color: \(hex(link.light)); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code, pre { font-family: \(codeFont)ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.88em; }
        :not(pre) > code { padding: 0.15em 0.35em; border-radius: 4px; background: rgba(128, 128, 128, 0.14); }
        pre { padding: 12px 14px; border-radius: 8px; background: rgba(128, 128, 128, 0.10); overflow-x: auto; line-height: 1.45; }
        blockquote { margin-left: 0; padding: 0 1em; border-left: 3px solid rgba(128, 128, 128, 0.35); color: rgba(0, 0, 0, 0.6); }
        ul, ol { padding-left: 1.6em; }
        li > p { margin: 0 0 0.4em; }
        li.task { list-style: none; margin-left: -1.3em; }
        li.task input { margin: 0 0.45em 0 0; vertical-align: -1px; }
        li.task > p:first-of-type { display: inline; }
        /* Leave a little room above whatever block the preview scrolls to. */
        [data-line] { scroll-margin-top: 20px; }
        /* No scroll bar, like the rest of Silica. */
        ::-webkit-scrollbar { display: none; }
        hr { border: none; border-top: 1px solid rgba(128, 128, 128, 0.3); margin: 1.6em 0; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid rgba(128, 128, 128, 0.3); padding: 6px 12px; }
        th { font-weight: 600; background: rgba(128, 128, 128, 0.08); }
        img { max-width: 100%; }
        ::selection { background: rgba(64, 120, 242, 0.25); }
        \(tokens.light)
        @media (prefers-color-scheme: dark) {
          body { color: rgba(255, 255, 255, 0.88); }
          a { color: \(hex(link.dark)); }
          blockquote { color: rgba(255, 255, 255, 0.6); }
          \(tokens.dark)
        }
        """
    }

    /// Runs in Silica's own script world, not the document's.
    private static let script = """
    window.silica = {
      blocks() { return Array.from(document.querySelectorAll('[data-line]')); },
      scrollToLine(line) {
        let target = null;
        const blocks = this.blocks();
        for (const el of blocks) { if (+el.dataset.line <= line) target = el; else break; }
        if (target && target !== blocks[0]) target.scrollIntoView({ block: 'start' }); else window.scrollTo(0, 0);
      },
      topLine() {
        for (const el of this.blocks()) { if (el.getBoundingClientRect().bottom > 1) return +el.dataset.line; }
        return 1;
      }
    };
    document.addEventListener('dblclick', (event) => {
      const block = event.target.closest('[data-line]');
      window.webkit.messageHandlers.silica.postMessage(block ? +block.dataset.line : 1);
    });
    """
}

/// The preview's web view: printable keys hand control back to the editor.
final class PreviewWebView: WKWebView {
    var onType: ((String) -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control])
        if modifiers.isEmpty, let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            onType?(characters)
            return
        }
        // Space, arrows and page keys keep scrolling the preview.
        super.keyDown(with: event)
    }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Serves local files (images next to the document) to the preview.
private final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let data = try? Data(contentsOf: URL(filePath: url.path(percentEncoded: false))) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// Hosts a buffer's preview web view in the editor card.
struct MarkdownPreviewHost: NSViewRepresentable {
    let preview: MarkdownPreview

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if preview.webView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        let webView = preview.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        DispatchQueue.main.async {
            webView.window?.makeFirstResponder(webView)
        }
    }
}
