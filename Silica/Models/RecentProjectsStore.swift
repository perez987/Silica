import Foundation
import Observation

struct RecentProject: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var path: String
    var bookmark: Data
    var lastOpened: Date

    /// Path with the user's real home directory abbreviated to `~`.
    var displayPath: String {
        let home = RealHome.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

enum RecentProjectError: LocalizedError {
    case notFound

    var errorDescription: String? {
        String(localized: "This project is no longer in the recent projects list.")
    }
}

/// Persists the projects the user has opened as security-scoped bookmarks,
/// so the sandboxed app can reopen them across launches.
@Observable
final class RecentProjectsStore {
    static let shared = RecentProjectsStore()

    private(set) var projects: [RecentProject] = []

    private let defaultsKey = "RecentProjects"
    private let maxCount = 15

    private init() {
        load()
    }

    func project(withID id: RecentProject.ID) -> RecentProject? {
        projects.first { $0.id == id }
    }

    /// Adds (or bumps) a project the user just granted access to.
    @discardableResult
    func register(_ url: URL) throws -> RecentProject {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let path = url.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlash

        var entry: RecentProject
        if let index = projects.firstIndex(where: { $0.path == path }) {
            entry = projects.remove(at: index)
            entry.bookmark = bookmark
            entry.name = url.lastPathComponent
            entry.lastOpened = .now
        } else {
            entry = RecentProject(id: UUID(), name: url.lastPathComponent, path: path, bookmark: bookmark, lastOpened: .now)
        }
        projects.insert(entry, at: 0)
        if projects.count > maxCount {
            projects.removeLast(projects.count - maxCount)
        }
        save()
        return entry
    }

    func markOpened(_ id: RecentProject.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var entry = projects.remove(at: index)
        entry.lastOpened = .now
        projects.insert(entry, at: 0)
        save()
    }

    func remove(_ id: RecentProject.ID) {
        projects.removeAll { $0.id == id }
        save()
    }

    func clear() {
        projects.removeAll()
        save()
    }

    /// Resolves the bookmark to a URL. The caller is responsible for
    /// starting/stopping security-scoped access.
    func resolveURL(for id: RecentProject.ID) throws -> URL {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw RecentProjectError.notFound
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: projects[index].bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                projects[index].bookmark = fresh
                projects[index].path = url.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlash
                projects[index].name = url.lastPathComponent
                save()
            }
        }
        return url
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([RecentProject].self, from: data)
        else { return }
        projects = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

enum RealHome {
    /// The user's home directory (not the sandbox container).
    static let path: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()
}

nonisolated extension String {
    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
