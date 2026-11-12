import SwiftUI

/// Find in Project in the sidebar: a search field, then matches grouped by file.
/// Selecting a match opens the file with the match selected.
struct ProjectSearchView: View {
    let workspace: WorkspaceModel
    @Bindable var model: ProjectSearchModel
    @FocusState private var isFieldFocused: Bool
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field
                .padding(.horizontal, 10)
            summary
                .padding(.horizontal, 14)
            results
        }
        .padding(.top, 2)
        .onAppear { isFieldFocused = true }
        .onChange(of: model.focusRequest) { isFieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .onKeyPress(.escape) {
                    if model.query.isEmpty { workspace.showExplorer() } else { model.query = "" }
                    return .handled
                }
            Button {
                model.isCaseSensitive.toggle()
            } label: {
                Text("Aa")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(model.isCaseSensitive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 18)
                    .background {
                        if model.isCaseSensitive {
                            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(model.isCaseSensitive ? String(localized: "Match Case: On") : String(localized: "Match Case: Off"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.07)))
    }

    @ViewBuilder
    private var summary: some View {
        if model.isSearching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Searching…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if !model.query.isEmpty {
            Group {
                if model.matchCount == 0 {
                    Text("No results")
                } else {
                    let results = model.matchCount == 1 ? String(localized: "1 result") : String(localized: "\(model.matchCount.formatted()) results")
                    let files = model.results.count == 1 ? String(localized: "1 file") : String(localized: "\(model.results.count.formatted()) files")
                    let summary = String(localized: "\(results) in \(files)")
                    Text(summary + (model.isTruncated ? String(localized: " (first \(ProjectSearch.maxMatches.formatted()) shown)") : ""))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var results: some View {
        List(selection: $selection) {
            ForEach(model.results) { file in
                FileHeaderRow(file: file, isCollapsed: model.collapsedFiles.contains(file.url)) {
                    if model.collapsedFiles.contains(file.url) {
                        model.collapsedFiles.remove(file.url)
                    } else {
                        model.collapsedFiles.insert(file.url)
                    }
                }
                .tag(file.id)
                if !model.collapsedFiles.contains(file.url) {
                    ForEach(file.matches) { match in
                        MatchRow(match: match)
                            .tag(match.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .environment(\.sidebarRowSize, .small)
        .environment(\.defaultMinListRowHeight, 22)
        .onChange(of: selection) { _, id in
            guard let id else { return }
            for file in model.results {
                if let match = file.matches.first(where: { $0.id == id }) {
                    workspace.openSearchMatch(file.url, range: match.range)
                    return
                }
            }
        }
    }
}

private struct FileHeaderRow: View {
    let file: SearchFileResult
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            FileIcon(url: file.url)
                .padding(.trailing, 2)
            Text(file.url.lastPathComponent)
                .lineLimit(1)
                .layoutPriority(1)
            let folder = (file.path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Text(file.matches.count.formatted())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(.primary.opacity(0.08)))
        }
    }
}

private struct MatchRow: View {
    let match: SearchMatch

    var body: some View {
        Text(highlighted)
            .lineLimit(1)
            .truncationMode(.tail)
            .font(.callout)
            .padding(.leading, 32)
            .help("Line \(match.line)")
    }

    /// The line with the match in bold on a soft accent background.
    private var highlighted: AttributedString {
        let preview = match.preview as NSString
        let range = match.previewRange
        guard range.location >= 0, NSMaxRange(range) <= preview.length else { return AttributedString(match.preview) }
        var result = AttributedString(preview.substring(to: range.location))
        result.foregroundColor = .secondary
        var hit = AttributedString(preview.substring(with: range))
        hit.inlinePresentationIntent = .stronglyEmphasized
        hit.backgroundColor = Color.accentColor.opacity(0.25)
        var rest = AttributedString(preview.substring(from: NSMaxRange(range)))
        rest.foregroundColor = .secondary
        result.append(hit)
        result.append(rest)
        return result
    }
}
