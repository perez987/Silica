import Foundation

/// The kinds of file that can be shown rendered as well as in source.
nonisolated enum PreviewFormat: Sendable {
    case markdown
    /// Comma-separated values, or semicolon-separated as some spreadsheets export them.
    case csv
    /// Tab-separated values.
    case tsv

    init?(url: URL) {
        if SyntaxLanguage(url: url) == .markdown {
            self = .markdown
            return
        }
        switch url.pathExtension.lowercased() {
        case "csv": self = .csv
        case "tsv": self = .tsv
        default: return nil
        }
    }

    /// What the source side of the preview is called, as in "Show Markdown".
    var sourceName: String {
        switch self {
        case .markdown: "Markdown"
        case .csv: "CSV"
        case .tsv: "TSV"
        }
    }

    /// Shown as a table that can be wider than the window, not as a column of text.
    var isTable: Bool {
        self != .markdown
    }

    /// The body of the preview page for the file's `text`.
    func html(for text: String) -> String {
        switch self {
        case .markdown: MarkdownHTMLRenderer.render(text)
        case .csv: CSVHTMLRenderer.render(text)
        case .tsv: CSVHTMLRenderer.render(text, delimiter: "\t")
        }
    }
}
