import CoreServices
import Foundation

/// Reports changes anywhere under a project folder (FSEvents), batched over a
/// short delay so a `git checkout` or a build arrives as one callback.
final class ProjectWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    /// `onChange` runs on the main queue.
    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            // Released in `stop()`, so the stream never outlives its watcher.
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.handle(changed) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            [url.path(percentEncoded: false)] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Unmanaged.passUnretained(self).release()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        Unmanaged.passUnretained(self).release()
    }

    private func handle(_ paths: [String]) {
        // Git rewrites its own files constantly (index, locks, logs); the working
        // tree changes a checkout makes arrive as their own events.
        let relevant = paths.contains { path in
            !path.contains("/.git/") && !path.hasSuffix("/.git")
        }
        if relevant { onChange() }
    }
}
