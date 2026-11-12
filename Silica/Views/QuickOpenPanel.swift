import SwiftUI

/// Full-window layer for Quick Open: a click outside the panel dismisses it.
struct QuickOpenOverlay: View {
    let workspace: WorkspaceModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { workspace.hideQuickOpen() }

            QuickOpenPanel(workspace: workspace, model: workspace.quickOpen)
                .padding(.top, WorkspaceLayout.titleBarHeight + 12)
                .padding(.horizontal, 24)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }
}

/// The ⌘P file picker: a search field over a fuzzy-ranked list of the project's files.
private struct QuickOpenPanel: View {
    let workspace: WorkspaceModel
    @Bindable var model: QuickOpenModel
    @FocusState private var isSearchFocused: Bool
    @State private var fieldSelection: TextSelection?

    private static let rowHeight: CGFloat = 30
    private static let maxListHeight: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultList
        }
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onAppear {
            isSearchFocused = true
            placeCursorAtEnd()
        }
        .onChange(of: model.presentationCount) { placeCursorAtEnd() }
        .onChange(of: isSearchFocused) { _, focused in
            if focused { placeCursorAtEnd() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Search files by name (add :line to jump)", text: $model.query, selection: $fieldSelection)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit(openSelection)
                .onKeyPress(.upArrow) {
                    model.moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    workspace.hideQuickOpen()
                    return .handled
                }
            if model.isIndexing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var resultList: some View {
        if model.isGoToLine {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.to.line")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(goToLinePrompt)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.rowHeight + 8)
        } else if model.results.isEmpty {
            Text(model.isIndexing ? String(localized: "Indexing files…") : String(localized: "No matching files"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            QuickOpenRow(result: result, isSelected: index == model.selectedIndex)
                                .frame(height: Self.rowHeight)
                                .contentShape(.rect)
                                .onTapGesture { workspace.openFromQuickOpen(result.item.url, line: model.lineTarget) }
                                .id(result.id)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(height: min(CGFloat(model.results.count) * Self.rowHeight + 12, Self.maxListHeight))
                .onChange(of: model.selectedIndex) { _, index in
                    guard model.results.indices.contains(index) else { return }
                    proxy.scrollTo(model.results[index].id)
                }
            }
        }
    }

    /// Puts the cursor after a prefilled ":" (Go to Line) instead of selecting it.
    ///
    /// Focusing a field selects all of its text, and focus can land after this runs,
    /// so it's applied again once focus arrives and shortly after. It only ever undoes
    /// a select-all, so it can't move a cursor the user has placed.
    private func placeCursorAtEnd() {
        for delay in [0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !model.query.isEmpty else { return }
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                   editor.string == model.query {
                    let length = (editor.string as NSString).length
                    guard editor.selectedRange() == NSRange(location: 0, length: length) else { return }
                    editor.setSelectedRange(NSRange(location: length, length: 0))
                }
                fieldSelection = TextSelection(insertionPoint: model.query.endIndex)
            }
        }
    }

    private var goToLinePrompt: String {
        let count = workspace.activeLineCount ?? 1
        if let line = model.lineTarget {
            return String(localized: "Go to line \(min(max(line, 1), count))")
        }
        return String(localized: "Type a line number between 1 and \(count)")
    }

    private func openSelection() {
        if model.isGoToLine {
            if let line = model.lineTarget { workspace.goToLineFromQuickOpen(line) }
            return
        }
        guard let result = model.selectedResult else { return }
        workspace.openFromQuickOpen(result.item.url, line: model.lineTarget)
    }
}

private struct QuickOpenRow: View {
    let result: QuickOpenResult
    let isSelected: Bool

    var body: some View {
        let item = result.item
        let matched = Set(result.positions)
        HStack(spacing: 8) {
            FileIcon(url: item.url)
            Text(Self.highlight(item.scalars[item.nameStart...], matched: matched))
                .lineLimit(1)
                .layoutPriority(1)
            if item.nameStart > 0 {
                // The containing folder, without its trailing slash.
                Text(Self.highlight(item.scalars[..<(item.nameStart - 1)], matched: matched))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            if result.isRecent {
                Text("recently opened")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
            }
        }
    }

    /// Bolds the matched characters and draws them in the primary color.
    private static func highlight(_ scalars: ArraySlice<Unicode.Scalar>, matched: Set<Int>) -> AttributedString {
        var result = AttributedString()
        var run = String.UnicodeScalarView()
        var runIsMatched = false

        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(String(run))
            if runIsMatched {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .primary
            }
            result.append(piece)
            run = String.UnicodeScalarView()
        }

        for index in scalars.indices {
            let isMatched = matched.contains(index)
            if isMatched != runIsMatched {
                flush()
                runIsMatched = isMatched
            }
            run.append(scalars[index])
        }
        flush()
        return result
    }
}
