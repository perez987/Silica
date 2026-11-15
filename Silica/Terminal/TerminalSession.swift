import AppKit
import GhosttyVt
import Observation

/// One terminal: the user's shell, the libghostty-vt emulator that turns what the
/// shell prints into a grid of cells, and the view that draws the grid.
///
/// libghostty-vt is only the emulator. It has no window, font or process of its own,
/// so the shell comes from `TerminalProcess` and the drawing and the keyboard from
/// `TerminalView`. The session stays alive while its card is hidden; `close()` ends it.
@Observable
final class TerminalSession {
    /// The name the shell, or a program running in it, gave the terminal. Empty until
    /// one does.
    private(set) var title = ""
    /// The terminal has the keyboard.
    private(set) var isFocused = false
    /// Where the link under the pointer leads, while there's one to follow.
    var linkDestination: String?
    /// "zsh", for the card's header until there's a title.
    let shellName: String
    /// What the card's header and the terminal's tab call it.
    var name: String { title.isEmpty ? shellName : title }

    /// The emulator; `nil` once the session is closed.
    @ObservationIgnored private(set) var terminal: GhosttyTerminal?
    /// A program asked for the screen to stay as it is while it draws a frame.
    @ObservationIgnored private(set) var isRenderHeld = false
    @ObservationIgnored private(set) var view: TerminalView!
    /// The shell exited by itself.
    @ObservationIgnored var onExit: (() -> Void)?
    /// A link to a file was followed, to a line of it if the link named one.
    @ObservationIgnored var onOpenFile: ((URL, Int?) -> Void)?

    @ObservationIgnored private let shell: String
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var process: TerminalProcess?
    @ObservationIgnored private var didAttemptStart = false
    @ObservationIgnored private var size: TerminalProcess.Size?
    @ObservationIgnored private var cellPixelSize: (width: UInt32, height: UInt32) = (0, 0)
    @ObservationIgnored private var isDark = false
    @ObservationIgnored private var renderHoldTimeout: DispatchWorkItem?

    /// Lines kept above the screen, give or take: the emulator trims a page at a time.
    private static let scrollbackLines = 10_000
    /// A second limit for lines that are unusually costly to keep.
    private static let scrollbackBytes = 256 << 20
    /// How long a program may hold the screen still before it's drawn anyway, so one
    /// that dies in the middle of a frame doesn't freeze the terminal.
    private static let renderHoldLimit: TimeInterval = 1

    /// A terminal whose shell starts in `directory` once the view knows its size.
    init?(directory: URL) {
        self.directory = directory
        shell = TerminalProcess.userShell
        shellName = (shell as NSString).lastPathComponent

        var terminal: GhosttyTerminal?
        // A placeholder size: the real one comes with the view's first layout.
        guard ghostty_terminal_new(nil, &terminal, 80, 24) == GHOSTTY_SUCCESS, terminal != nil else { return nil }
        self.terminal = terminal
        configure()
        view = TerminalView(session: self)
    }

    isolated deinit {
        close()
    }

    private func configure() {
        // The callbacks get the session back through this pointer. It isn't
        // retained: the session frees the terminal before it goes away.
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let writePty: GhosttyTerminalWritePtyFn = terminalWritePty
        let bell: GhosttyTerminalBellFn = terminalBell
        let titleChanged: GhosttyTerminalTitleChangedFn = terminalTitleChanged
        let size: GhosttyTerminalSizeFn = terminalSize
        let colorScheme: GhosttyTerminalColorSchemeFn = terminalColorScheme
        let renderHold: GhosttyTerminalRenderHoldFn = terminalRenderHold
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(colorScheme, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(renderHold, to: UnsafeRawPointer.self))

        // The emulator's own default keeps next to no history.
        var lines = Self.scrollbackLines
        var bytes = Self.scrollbackBytes
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)

        // An emoji with a skin tone or a flag takes one cell pair, as it's drawn,
        // rather than one per code point. Ghostty itself runs with this on.
        var graphemes = GhosttyTerminalModeConfig(mode: ghostty_mode_new(TerminalMode.graphemeCluster, false), value: true)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes)

        var blinks = true
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blinks)
    }

    /// Ends the shell and frees the emulator. The view draws nothing afterwards.
    func close() {
        guard terminal != nil else { return }
        renderHoldTimeout?.cancel()
        process?.terminate()
        process = nil
        // The view's own libghostty objects refer to the terminal.
        view?.releaseTerminal()
        ghostty_terminal_free(terminal)
        terminal = nil
    }

    // MARK: Size

    /// The grid the view has room for, and the size of a cell in pixels for programs
    /// that ask. The first call starts the shell, so that it starts at the right size
    /// instead of redrawing its prompt a moment later.
    func resize(columns: Int, rows: Int, cellPixelSize: CGSize) {
        guard let terminal else { return }
        let columns = UInt16(clamping: columns), rows = UInt16(clamping: rows)
        let cell = (width: UInt32(max(cellPixelSize.width, 1)), height: UInt32(max(cellPixelSize.height, 1)))
        let size = TerminalProcess.Size(
            columns: columns,
            rows: rows,
            pixelWidth: UInt16(clamping: UInt32(columns) * cell.width),
            pixelHeight: UInt16(clamping: UInt32(rows) * cell.height)
        )
        guard size != self.size else { return }
        self.size = size
        self.cellPixelSize = cell
        // Ends a render hold, if there was one.
        ghostty_terminal_resize(terminal, columns, rows, cell.width, cell.height)
        if let process {
            process.resize(to: size)
        } else if !didAttemptStart {
            didAttemptStart = true
            start(size: size)
        }
    }

    private func start(size: TerminalProcess.Size) {
        process = TerminalProcess(
            shell: shell,
            directory: directory,
            size: size,
            onOutput: { [weak self] in self?.receive($0) },
            onExit: { [weak self] in self?.onExit?() }
        )
        if process == nil {
            receive(Data((String(localized: "Silica couldn’t start \(shell).") + "\r\n").utf8))
        }
    }

    // MARK: Output

    private func receive(_ data: Data) {
        guard let terminal else { return }
        data.withUnsafeBytes { bytes in
            ghostty_terminal_vt_write(terminal, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        view.terminalDidChange()
    }

    fileprivate func titleDidChange() {
        var title = GhosttyString()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS else { return }
        // The bytes are the terminal's, good until its next change.
        self.title = String(decoding: UnsafeBufferPointer(start: title.ptr, count: title.len), as: UTF8.self)
    }

    fileprivate func reportSize(to report: inout GhosttySizeReportSize) -> Bool {
        guard let size else { return false }
        report.rows = size.rows
        report.columns = size.columns
        report.cell_width = cellPixelSize.width
        report.cell_height = cellPixelSize.height
        return true
    }

    fileprivate var colorScheme: GhosttyColorScheme {
        isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    fileprivate func setRenderHeld(_ held: Bool) {
        renderHoldTimeout?.cancel()
        renderHoldTimeout = nil
        if held {
            // What's on screen before the program starts its frame is what stays
            // there until the frame is done.
            view.terminalDidChange()
            isRenderHeld = true
            let timeout = DispatchWorkItem { [weak self] in self?.endOverdueRenderHold() }
            renderHoldTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.renderHoldLimit, execute: timeout)
        } else {
            isRenderHeld = false
            view?.terminalDidChange()
        }
    }

    private func endOverdueRenderHold() {
        guard isRenderHeld, terminal != nil else { return }
        // Setting the mode ourselves doesn't call back.
        setMode(TerminalMode.synchronizedOutput, false)
        isRenderHeld = false
        view.terminalDidChange()
    }

    /// The folders a path that a program printed may be relative to: the one the
    /// program is working in, then the project's.
    var workingDirectories: [URL] {
        guard let current = process?.currentDirectory, current.standardizedFileURL != directory.standardizedFileURL else {
            return [directory]
        }
        return [current, directory]
    }

    // MARK: Input

    /// Sends bytes to the shell as if typed.
    func send(_ data: Data) {
        process?.write(data)
    }

    func send(_ text: String) {
        send(Data(text.utf8))
    }

    /// Whether a mode the running program can switch (DECSET) is on.
    func isModeSet(_ mode: UInt16) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(mode, false), value: false)
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS && config.value
    }

    private func setMode(_ mode: UInt16, _ value: Bool) {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(mode, false), value: value)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &config)
    }

    /// A full-screen program (an editor, a pager) has the screen, which has no history.
    var isAlternateScreen: Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    /// The running program wants the mouse for itself.
    var tracksMouse: Bool {
        var tracking = false
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        return tracking
    }

    /// The view took or gave up the keyboard; programs that asked to be told are.
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        guard terminal != nil, isModeSet(TerminalMode.focusEvents) else { return }
        var bytes = [UInt8](repeating: 0, count: 8)
        var count = 0
        if ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, &bytes, bytes.count, &count) == GHOSTTY_SUCCESS {
            send(Data(bytes.prefix(count)))
        }
    }

    // MARK: Scrolling

    /// Scrolls through the history: negative is up, towards older lines.
    func scroll(byRows rows: Int) {
        guard let terminal, rows != 0 else { return }
        ghostty_terminal_scroll_viewport(terminal, GhosttyTerminalScrollViewport(tag: GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA, value: .init(delta: rows)))
        view.terminalDidChange()
    }

    /// Back to the live screen, as typing does.
    func scrollToBottom() {
        guard let terminal else { return }
        var isAtBottom = true
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &isAtBottom)
        guard !isAtBottom else { return }
        ghostty_terminal_scroll_viewport(terminal, GhosttyTerminalScrollViewport(tag: GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM, value: .init()))
        view.terminalDidChange()
    }

    /// Clears the screen and the history, like ⌘K in Terminal.
    func clear() {
        guard terminal != nil, !isAlternateScreen else { return }
        receive(Data("\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8))
        // Control-L: a shell at its prompt draws the prompt again on the empty screen.
        send("\u{0C}")
    }

    // MARK: Selection

    var hasSelection: Bool {
        var selection = GhosttySelection()
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
    }

    /// The selected text, with wrapped lines joined back together.
    var selectedText: String? {
        guard let terminal else { return nil }
        var selection = GhosttySelection()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS else { return nil }
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal) == GHOSTTY_SUCCESS else { return nil }
        defer { ghostty_formatter_free(formatter) }
        var format = GHOSTTY_FORMATTER_FORMAT_PLAIN
        var yes = true
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &format)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &yes)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection)
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &bytes, &count) == GHOSTTY_SUCCESS else { return nil }
        defer { ghostty_free(nil, bytes, count) }
        let text = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    func select(_ selection: GhosttySelection) {
        var selection = selection
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        view.terminalDidChange()
    }

    func selectAll() {
        var selection = GhosttySelection()
        guard ghostty_terminal_select_all(terminal, &selection) == GHOSTTY_SUCCESS else { return }
        select(selection)
    }

    func clearSelection() {
        guard terminal != nil, hasSelection else { return }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        view.terminalDidChange()
    }

    // MARK: Paste

    enum PasteResult {
        case pasted
        /// The text has line breaks and the program didn't ask for pastes to be
        /// marked as such, so it would run each line as it arrives.
        case needsConfirmation
        case failed
    }

    /// Pastes text the way the running program expects it: marked as a paste when it
    /// asked for that (bracketed paste), and with line breaks as the Return key.
    func paste(_ text: String, allowingUnsafe: Bool = false) -> PasteResult {
        guard let terminal, !text.isEmpty else { return .failed }
        let source = PasteSource(text)
        let mime = Array("text/plain".utf8)
        let result = mime.withUnsafeBufferPointer { mime in
            var mimes = [GhosttyString(ptr: mime.baseAddress, len: mime.count)]
            return mimes.withUnsafeMutableBufferPointer { mimes in
                var paste = GhosttyPaste()
                paste.size = MemoryLayout<GhosttyPaste>.size
                paste.location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD
                paste.source = GHOSTTY_PASTE_SOURCE_CLIPBOARD
                paste.mimes = UnsafePointer(mimes.baseAddress)
                paste.mimes_len = mimes.count
                paste.reader = GhosttyMimeReader(read: terminalPasteRead, userdata: Unmanaged.passUnretained(source).toOpaque())
                paste.allow_unsafe = allowingUnsafe
                var didPaste = false
                // The encoded paste comes back through the write callback.
                return ghostty_terminal_paste(terminal, &paste, &didPaste)
            }
        }
        if result == GHOSTTY_SUCCESS {
            scrollToBottom()
            return .pasted
        }
        return result == GHOSTTY_REJECTED ? .needsConfirmation : .failed
    }

    // MARK: Colors

    /// Follows the window's appearance: the sixteen ANSI colors, and the text and
    /// background colors that programs are told when they ask.
    func setAppearance(isDark: Bool) {
        guard let terminal else { return }
        self.isDark = isDark
        let colors = isDark ? TerminalColors.dark : TerminalColors.light
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        ghostty_color_palette_default(&palette)
        for (index, hex) in colors.ansi.enumerated() {
            palette[index] = GhosttyColorRgb(hex: hex)
        }
        var foreground = GhosttyColorRgb(hex: colors.foreground)
        var background = GhosttyColorRgb(hex: colors.background)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
    }
}

/// Told apart by which object they are, for the tabs in the card's header.
extension TerminalSession: Identifiable {}

/// The private terminal modes (DECSET numbers) the app looks at.
nonisolated enum TerminalMode {
    /// Arrow keys send their application sequences.
    static let cursorKeys: UInt16 = 1
    static let focusEvents: UInt16 = 1004
    /// On the alternate screen, the scroll wheel sends arrow keys.
    static let alternateScroll: UInt16 = 1007
    static let synchronizedOutput: UInt16 = 2026
    static let graphemeCluster: UInt16 = 2027
}

/// The terminal's colors in one appearance.
///
/// The card is glass, so there's no background to paint: `background` is only what a
/// program is told when it asks whether the terminal is light or dark, and what text
/// drawn in reverse takes for its color.
nonisolated struct TerminalColors {
    var foreground: UInt32
    var background: UInt32
    /// Black, red, green, yellow, blue, magenta, cyan, white, then their bright versions.
    var ansi: [UInt32]

    // GitHub's terminal palettes: one of the few sets with a light half that is
    // drawn for a light background rather than derived from the dark one.
    static let light = TerminalColors(
        foreground: 0x1F2328,
        background: 0xFFFFFF,
        ansi: [
            0x24292F, 0xCF222E, 0x116329, 0x7D4E00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
            0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
        ]
    )

    static let dark = TerminalColors(
        foreground: 0xE6EDF3,
        background: 0x1E1E1E,
        ansi: [
            0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
            0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF,
        ]
    )
}

nonisolated extension GhosttyColorRgb {
    init(hex: UInt32) {
        self.init(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF))
    }
}

/// The text of a paste, for the callback libghostty reads it through.
private nonisolated final class PasteSource {
    let bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8)
    }
}

// MARK: - Callbacks

// libghostty calls these from inside `ghostty_terminal_vt_write` and
// `ghostty_terminal_paste`, so on the main thread, with the session as `userdata`.
// They can't write to the terminal again from in here.

private nonisolated func session(_ userdata: UnsafeMutableRawPointer?) -> TerminalSession? {
    userdata.map { Unmanaged<TerminalSession>.fromOpaque($0).takeUnretainedValue() }
}

/// The terminal's own replies to a program's questions (where's the cursor, what
/// kind of terminal is this), and encoded pastes.
private nonisolated func terminalWritePty(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) {
    guard let bytes, count > 0 else { return }
    let data = Data(bytes: bytes, count: count)
    MainActor.assumeIsolated { session(userdata)?.send(data) }
}

private nonisolated func terminalBell(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated { NSSound.beep() }
}

private nonisolated func terminalTitleChanged(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated { session(userdata)?.titleDidChange() }
}

private nonisolated func terminalSize(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?, _ size: UnsafeMutablePointer<GhosttySizeReportSize>?) -> Bool {
    guard let size else { return false }
    return MainActor.assumeIsolated { session(userdata)?.reportSize(to: &size.pointee) ?? false }
}

private nonisolated func terminalColorScheme(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?, _ scheme: UnsafeMutablePointer<GhosttyColorScheme>?) -> Bool {
    guard let scheme else { return false }
    return MainActor.assumeIsolated {
        guard let session = session(userdata) else { return false }
        scheme.pointee = session.colorScheme
        return true
    }
}

private nonisolated func terminalRenderHold(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?, _ held: Bool) {
    MainActor.assumeIsolated { session(userdata)?.setRenderHeld(held) }
}

private nonisolated func terminalPasteRead(_ userdata: UnsafeMutableRawPointer?, _ mime: GhosttyString, _ writer: GhosttyWriter) -> Bool {
    guard let userdata else { return false }
    let source = Unmanaged<PasteSource>.fromOpaque(userdata).takeUnretainedValue()
    return source.bytes.withUnsafeBufferPointer { writer.write(writer.userdata, $0.baseAddress, $0.count) }
}
