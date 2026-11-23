import Darwin
import Foundation

/// The user's shell, running on a pseudo-terminal.
///
/// What the shell prints is read on a background queue and handed to `onOutput` on
/// the main thread, a batch at a time. `terminate()` has to be called when the
/// terminal is done with: until the shell exits the process keeps itself alive, so
/// that the shell is always reaped.
nonisolated final class TerminalProcess: @unchecked Sendable {
    struct Size: Equatable, Sendable {
        var columns: UInt16
        var rows: UInt16
        var pixelWidth: UInt16
        var pixelHeight: UInt16
    }

    /// `ioctl` request that sets a terminal's size. The C macro isn't imported.
    private static let setWindowSize: UInt = 0x8008_7467
    /// Unread output past which reading pauses until the main thread catches up, so
    /// a command that floods the terminal can't grow the buffer without bound.
    private static let highWaterMark = 1 << 20

    private let master: Int32
    private let pid: pid_t
    private let onOutput: @MainActor (Data) -> Void
    private let onExit: @MainActor () -> Void

    /// Reads the shell's output and watches for its exit.
    private let ioQueue = DispatchQueue(
        label: "com.hieudinh.Silica.terminal.io"
    )
    /// Writes block while the shell isn't reading, so they have their own queue.
    private let writeQueue = DispatchQueue(
        label: "com.hieudinh.Silica.terminal.write"
    )
    private let readSource: DispatchSourceRead
    private let exitSource: DispatchSourceProcess

    private let lock = NSLock()
    // Guarded by `lock`.
    private var pending = Data()
    private var isDrainScheduled = false
    private var isReadSuspended = false
    private var isClosed = false
    private var isTerminated = false
    // Used on `ioQueue` only.
    private var didReap = false
    private var readBuffer = [UInt8](repeating: 0, count: 1 << 16)

    /// The user's login shell: from the directory service as Terminal does, since
    /// `SHELL` is whatever the app happened to be launched with.
    static var userShell: String {
        let files = FileManager.default
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if files.isExecutableFile(atPath: path) { return path }
        }
        if let path = ProcessInfo.processInfo.environment["SHELL"],
            files.isExecutableFile(atPath: path)
        {
            return path
        }
        return "/bin/zsh"
    }

    /// Starts `shell` as a login shell in `directory`, or returns `nil` if the system
    /// has no pseudo-terminal or process to give.
    init?(
        shell: String,
        directory: URL,
        size: Size,
        onOutput: @escaping @MainActor (Data) -> Void,
        onExit: @escaping @MainActor () -> Void
    ) {
        // A leading "-" is how a shell is told it's a login shell, which is what
        // sets up the user's PATH: an app launched from the Finder has a bare one.
        let arguments = ["-" + (shell as NSString).lastPathComponent]
        let environment = Self.environment(shell: shell, directory: directory)

        // Everything the child needs is made before the fork. After it the child may
        // only make system calls: another thread could have been holding the
        // allocator's lock when the fork copied it.
        let path = strdup(shell)
        let workingDirectory = strdup(directory.path)
        let home = strdup(NSHomeDirectory())
        let argv: [UnsafeMutablePointer<CChar>?] =
            arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup($0) } + [nil]
        defer {
            free(path)
            free(workingDirectory)
            free(home)
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        let descriptorLimit = getdtablesize()
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var windowSize = winsize(
            ws_row: size.rows,
            ws_col: size.columns,
            ws_xpixel: size.pixelWidth,
            ws_ypixel: size.pixelHeight
        )
        var master: Int32 = -1

        let pid = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp -> pid_t in
                let pid = forkpty(&master, nil, nil, &windowSize)
                if pid == 0 {
                    // The child: the terminal is already its standard input, output
                    // and error, and its controlling terminal.
                    var descriptor: Int32 = 3
                    while descriptor < descriptorLimit {
                        close(descriptor)
                        descriptor += 1
                    }
                    // Signals the app blocks or ignores would stay that way in the shell.
                    sigprocmask(SIG_SETMASK, &noSignals, nil)
                    signal(SIGHUP, SIG_DFL)
                    signal(SIGINT, SIG_DFL)
                    signal(SIGQUIT, SIG_DFL)
                    signal(SIGPIPE, SIG_DFL)
                    signal(SIGTERM, SIG_DFL)
                    signal(SIGCHLD, SIG_DFL)
                    signal(SIGTSTP, SIG_DFL)
                    signal(SIGTTIN, SIG_DFL)
                    signal(SIGTTOU, SIG_DFL)
                    if chdir(workingDirectory) != 0 { chdir(home) }
                    execve(path, argv.baseAddress, envp.baseAddress)
                    _exit(127)
                }
                return pid
            }
        }
        guard pid > 0, master >= 0 else { return nil }

        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // Tell the line editor in the kernel that input is UTF-8, so that Delete
        // takes a whole character while a program reads a line the simple way.
        var attributes = termios()
        if tcgetattr(master, &attributes) == 0 {
            attributes.c_iflag |= tcflag_t(IUTF8)
            tcsetattr(master, TCSANOW, &attributes)
        }

        self.master = master
        self.pid = pid
        self.onOutput = onOutput
        self.onExit = onExit
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: master,
            queue: ioQueue
        )
        exitSource = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: ioQueue
        )

        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        // The descriptor closes once nothing reads it, and behind any write under way.
        readSource.setCancelHandler { [writeQueue] in
            writeQueue.async { close(master) }
        }
        // Holding `self` keeps the process around until the shell has been reaped,
        // whatever becomes of the terminal; cancelling the source lets go again.
        exitSource.setEventHandler { self.reap() }
        readSource.resume()
        exitSource.resume()
        // In case the shell was gone before the source started watching for it.
        ioQueue.async { self.reap() }
    }

    // MARK: Input

    /// Sends bytes to the shell as if typed.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [self] in
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard !closed else { return }
                    let written = Darwin.write(
                        master,
                        bytes.baseAddress! + offset,
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EAGAIN {
                        // The shell isn't reading: wait for room, but not so long
                        // that closing the terminal has to wait too.
                        var descriptor = pollfd(
                            fd: master,
                            events: Int16(POLLOUT),
                            revents: 0
                        )
                        poll(&descriptor, 1, 100)
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
    }

    /// Tells the shell, and whatever runs in it, the terminal's new size.
    func resize(to size: Size) {
        writeQueue.async { [self] in
            guard !closed else { return }
            var windowSize = winsize(
                ws_row: size.rows,
                ws_col: size.columns,
                ws_xpixel: size.pixelWidth,
                ws_ypixel: size.pixelHeight
            )
            _ = ioctl(master, Self.setWindowSize, &windowSize)
        }
    }

    /// The folder the program in front is working in: the shell's after a `cd`, or
    /// that of what the shell is running.
    var currentDirectory: URL? {
        guard !closed else { return nil }
        for process in [tcgetpgrp(master), pid] where process > 0 {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard
                proc_pidinfo(process, PROC_PIDVNODEPATHINFO, 0, &info, size)
                    == size
            else { continue }
            let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }

    /// Hangs up on the shell and stops reporting its output and its exit.
    func terminate() {
        lock.lock()
        isTerminated = true
        pending = Data()
        lock.unlock()
        closeMaster()
        // Closing the terminal hangs up on whatever runs in the foreground; the
        // shell is told directly too. On the queue that reaps it, so the signal
        // can't reach another process that was given the same id since.
        ioQueue.async { [self] in
            if !didReap { kill(pid, SIGHUP) }
        }
    }

    private var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    private func closeMaster() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        // A suspended source never runs its cancel handler.
        if isReadSuspended {
            isReadSuspended = false
            readSource.resume()
        }
        readSource.cancel()
    }

    // MARK: Output

    private func readAvailable() {
        var chunk = Data()
        var reachedEnd = false
        while chunk.count < Self.highWaterMark {
            let count = read(master, &readBuffer, readBuffer.count)
            if count > 0 {
                chunk.append(readBuffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                // Nothing more for now (EAGAIN), or every process that had the
                // terminal open is gone.
                reachedEnd = !(count < 0 && errno == EAGAIN)
                break
            }
        }

        if !chunk.isEmpty {
            lock.lock()
            let wasDrainScheduled = isDrainScheduled
            if !isTerminated {
                pending.append(chunk)
                isDrainScheduled = true
                if pending.count >= Self.highWaterMark, !isReadSuspended,
                    !isClosed, !reachedEnd
                {
                    isReadSuspended = true
                    readSource.suspend()
                }
            }
            let schedulesDrain = isDrainScheduled && !wasDrainScheduled
            lock.unlock()
            if schedulesDrain {
                DispatchQueue.main.async { self.drain() }
            }
        }
        if reachedEnd { closeMaster() }
    }

    /// On the main thread: hands over what was read since the last time.
    private func drain() {
        lock.lock()
        let data = pending
        pending = Data()
        isDrainScheduled = false
        if isReadSuspended {
            isReadSuspended = false
            readSource.resume()
        }
        let isTerminated = isTerminated
        lock.unlock()
        guard !isTerminated, !data.isEmpty else { return }
        MainActor.assumeIsolated { onOutput(data) }
    }

    // MARK: Exit

    private func reap() {
        guard !didReap else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        // Still running.
        guard result != 0 else { return }
        didReap = true
        exitSource.cancel()
        DispatchQueue.main.async { [self] in
            // After the output read so far: it was queued first.
            lock.lock()
            let isTerminated = isTerminated
            lock.unlock()
            guard !isTerminated else { return }
            MainActor.assumeIsolated { onExit() }
        }
    }

    // MARK: Environment

    private static func environment(shell: String, directory: URL) -> [String] {
        // Without what makes the app load its debugging libraries when run from Xcode.
        var environment = ProcessInfo.processInfo.environment.filter {
            name,
            _ in
            !name.hasPrefix("DYLD_") && !name.hasPrefix("__XPC_DYLD_")
                && name != "OS_ACTIVITY_DT_MODE"
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Silica"
        environment["TERM_PROGRAM_VERSION"] =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
        environment["SHELL"] = shell
        environment["PWD"] = directory.path
        environment["OLDPWD"] = nil
        if environment["HOME"] == nil {
            environment["HOME"] = NSHomeDirectory()
        }
        if environment["USER"] == nil { environment["USER"] = NSUserName() }
        if environment["LOGNAME"] == nil {
            environment["LOGNAME"] = NSUserName()
        }
        // Apps aren't launched with a locale; without one, programs take the
        // terminal for ASCII-only.
        if environment["LANG"] == nil, environment["LC_ALL"] == nil,
            environment["LC_CTYPE"] == nil
        {
            environment["LANG"] = utf8Locale
        }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    /// The user's locale if the system has it in UTF-8, as Terminal sets `LANG`.
    private static var utf8Locale: String {
        let locale = Locale.current
        if let language = locale.language.languageCode?.identifier,
            let region = locale.region?.identifier
        {
            let name = "\(language)_\(region).UTF-8"
            if FileManager.default.fileExists(
                atPath: "/usr/share/locale/\(name)"
            ) {
                return name
            }
        }
        return "en_US.UTF-8"
    }
}
