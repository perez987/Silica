import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    private var store: RecentProjectsStore { .shared }
    private var opener: ProjectOpener { ProjectOpener(openWindow: openWindow) }

    var body: some View {
        HStack(spacing: 0) {
            hero
                .frame(width: 330)
            recents
                .padding(.vertical, 18)
                .padding(.trailing, 18)
        }
        // Up into the hidden title bar, so the recents list runs the window's full
        // height and the hero centers on the whole window.
        .ignoresSafeArea(.container, edges: .top)
        // Frosted, behind-window blur for the whole welcome window.
        .containerBackground(for: .window) {
          WindowBackground(material: .hudWindow)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .onAppear { ExternalOpener.shared.openWindow = openWindow }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            // The app icon, which carries its own margin and shadow.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)

            Text("Silica")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 10)

            Text("Version \(Bundle.main.shortVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Spacer(minLength: 28)

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 10) {
                    Button {
                        opener.chooseAndOpen()
                    } label: {
                        Label("Open Project…", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("o")

                    if let last = store.projects.first {
                        Button {
                            opener.open(last)
                        } label: {
                            Label("Reopen “\(last.name)”", systemImage: "arrow.uturn.backward")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .controlSize(.extraLarge)
            }
            .frame(width: 230)

            Text("or drop a project folder anywhere in this window")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 14)

            Spacer(minLength: 32)
        }
        .padding(.horizontal, 32)
    }

    // MARK: Recents

    private var recents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Projects")
                    .font(.headline)
                Spacer()
                if !store.projects.isEmpty {
                    Button("Clear") { store.clear() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            if store.projects.isEmpty {
                ContentUnavailableView(
                    "No Recent Projects",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Projects you open will show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.projects) { project in
                            RecentProjectRow(project: project) {
                                opener.open(project)
                            } remove: {
                                withAnimation { store.remove(project.id) }
                            }
                        }
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .vertical)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                // A folder opens as a project; a file in the project it belongs to.
                ExternalOpener.shared.open([url])
            }
        }
        return true
    }
}

private struct RecentProjectRow: View {
    let project: RecentProject
    let open: () -> Void
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(FileIconPalette.folder)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(project.displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if isHovering {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Recents")
                } else {
                    Text(project.lastOpened.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open", action: open)
            Button("Show in Finder") { Finder.reveal(URL(filePath: project.path)) }
            Button("Copy Path") { Finder.copyPath(URL(filePath: project.path)) }
            Divider()
            Button("Remove from Recents", role: .destructive, action: remove)
        }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
