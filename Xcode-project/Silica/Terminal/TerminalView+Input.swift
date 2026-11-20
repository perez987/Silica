import AppKit
import Carbon.HIToolbox
import GhosttyVt

// Keyboard, mouse and clipboard for the terminal view.
//
// libghostty-vt knows what bytes a key or a click is for the program that's
// running, which depends on the modes the program has set: its encoders are given
// the event and their output goes to the shell.

// MARK: - Keyboard

extension TerminalView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // The window names its new first responder after this returns.
        DispatchQueue.main.async { [weak self] in self?.updateFocus() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.updateFocus() }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let session, session.terminal != nil else { return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if !hasMarkedText(), let text = lineEditingText(for: event, modifiers: modifiers) {
            session.send(text)
            didType()
            return
        }
        // The rest of the ⌘ keys are the menus', and mean nothing to a terminal.
        guard !modifiers.contains(.command) else { return }

        // The input system turns the press into text: through the keyboard layout,
        // a dead key, or an input method that composes several presses into one
        // character. What it commits lands in the accumulator.
        let hadMarkedText = hasMarkedText()
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let committed = keyTextAccumulator ?? []
        keyTextAccumulator = nil

        let action = event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS
        if committed.isEmpty {
            // No text: a key like Return or an arrow, a key with Control, or a press
            // that only went into the composition, which the encoder is told so
            // that Delete or Return there isn't sent on to the shell.
            sendKey(event, action: action, text: Self.text(of: event), isComposing: hasMarkedText() || hadMarkedText)
        } else {
            for text in committed {
                sendKey(event, action: action, text: text)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        // Only programs that asked to hear about releases get anything from this.
        sendKey(event, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil)
    }

    /// The keys macOS users move around a line with, as the control characters
    /// shells have for the same: ⌥← and ⌥→ by word, ⌘← and ⌘→ to the ends, ⌘⌫ to
    /// delete to the start. Not for programs that read the keyboard in full (the
    /// Kitty protocol), which make their own sense of these keys.
    private func lineEditingText(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        guard kittyKeyboardFlags == 0 else { return nil }
        switch (Int(event.keyCode), modifiers) {
        case (kVK_LeftArrow, .option): return "\u{1B}b"
        case (kVK_RightArrow, .option): return "\u{1B}f"
        case (kVK_LeftArrow, .command): return "\u{01}"
        case (kVK_RightArrow, .command): return "\u{05}"
        case (kVK_Delete, .command): return "\u{15}"
        default: return nil
        }
    }

    private var kittyKeyboardFlags: UInt8 {
        var flags: UInt8 = 0
        ghostty_terminal_get(session?.terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
        return flags
    }

    /// The text of a key press for the encoder: what the key types without Control,
    /// which the encoder applies itself. `nil` for keys that type nothing.
    private static func text(of event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        guard characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first else { return characters }
        if scalar.isControlOrFunctionKey {
            guard let plain = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)),
                  plain.unicodeScalars.count == 1, plain.unicodeScalars.first?.isControlOrFunctionKey == false else { return nil }
            return plain
        }
        return characters
    }

    private func sendKey(_ event: NSEvent, action: GhosttyKeyAction, text: String?, isComposing: Bool = false) {
        guard let session, let terminal = session.terminal, let keyEncoder, let keyEvent else { return }
        // The modes that change what keys send: application cursor keys, the Kitty
        // keyboard protocol and so on.
        ghostty_key_encoder_set_from_terminal(keyEncoder, terminal)

        let mods = Self.mods(event.modifierFlags)
        let hasText = text?.isEmpty == false
        ghostty_key_event_set_action(keyEvent, action)
        ghostty_key_event_set_key(keyEvent, Self.key(forKeyCode: Int(event.keyCode)))
        ghostty_key_event_set_mods(keyEvent, mods)
        // Shift and Option went into making the text, so they aren't sent again as
        // modifiers: ⌥B is "∫", not Alt+B.
        ghostty_key_event_set_consumed_mods(keyEvent, hasText ? mods & GhosttyMods(GHOSTTY_MODS_SHIFT | GHOSTTY_MODS_ALT) : 0)
        ghostty_key_event_set_composing(keyEvent, isComposing)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0)

        let utf8 = Array((text ?? "").utf8)
        var output = [UInt8](repeating: 0, count: 64)
        var count = 0
        let result = utf8.withUnsafeBufferPointer { utf8 -> GhosttyResult in
            // The event borrows the text, which has to outlive the encoding.
            ghostty_key_event_set_utf8(keyEvent, GhosttyString(ptr: utf8.baseAddress, len: utf8.count))
            defer { ghostty_key_event_set_utf8(keyEvent, GhosttyString(ptr: nil, len: 0)) }
            var result = ghostty_key_encoder_encode(keyEncoder, keyEvent, &output, output.count, &count)
            if result == GHOSTTY_OUT_OF_SPACE {
                output = [UInt8](repeating: 0, count: count)
                result = ghostty_key_encoder_encode(keyEncoder, keyEvent, &output, output.count, &count)
            }
            return result
        }
        guard result == GHOSTTY_SUCCESS, count > 0 else { return }

        var bytes = Data(output.prefix(count))
        // For a few Control keys the encoder answers with the unambiguous "CSI u"
        // form (Control-[ as a key of its own rather than Escape), which shells and
        // editors that didn't ask for it don't read. They get the control character
        // the Mac keyboard has always sent.
        if kittyKeyboardFlags == 0, bytes.starts(with: [0x1B, 0x5B]), bytes.last == UInt8(ascii: "u"),
           let characters = event.characters, characters.unicodeScalars.count == 1,
           let scalar = characters.unicodeScalars.first, scalar.value < 0x20 {
            bytes = Data(characters.utf8)
        }
        session.send(bytes)
        if action != GHOSTTY_KEY_ACTION_RELEASE { didType() }
    }

    /// After input that the shell will echo: back to the live screen, with nothing
    /// selected and the cursor showing.
    private func didType() {
        session?.clearSelection()
        session?.scrollToBottom()
        restartCursorBlink()
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    fileprivate static func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var mods: Int32 = 0
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS_LOCK }
        return GhosttyMods(mods)
    }

    /// The physical key of a macOS key code, whatever the layout prints on it.
    private static func key(forKeyCode keyCode: Int) -> GhosttyKey {
        switch keyCode {
        case kVK_ANSI_A: GHOSTTY_KEY_A
        case kVK_ANSI_B: GHOSTTY_KEY_B
        case kVK_ANSI_C: GHOSTTY_KEY_C
        case kVK_ANSI_D: GHOSTTY_KEY_D
        case kVK_ANSI_E: GHOSTTY_KEY_E
        case kVK_ANSI_F: GHOSTTY_KEY_F
        case kVK_ANSI_G: GHOSTTY_KEY_G
        case kVK_ANSI_H: GHOSTTY_KEY_H
        case kVK_ANSI_I: GHOSTTY_KEY_I
        case kVK_ANSI_J: GHOSTTY_KEY_J
        case kVK_ANSI_K: GHOSTTY_KEY_K
        case kVK_ANSI_L: GHOSTTY_KEY_L
        case kVK_ANSI_M: GHOSTTY_KEY_M
        case kVK_ANSI_N: GHOSTTY_KEY_N
        case kVK_ANSI_O: GHOSTTY_KEY_O
        case kVK_ANSI_P: GHOSTTY_KEY_P
        case kVK_ANSI_Q: GHOSTTY_KEY_Q
        case kVK_ANSI_R: GHOSTTY_KEY_R
        case kVK_ANSI_S: GHOSTTY_KEY_S
        case kVK_ANSI_T: GHOSTTY_KEY_T
        case kVK_ANSI_U: GHOSTTY_KEY_U
        case kVK_ANSI_V: GHOSTTY_KEY_V
        case kVK_ANSI_W: GHOSTTY_KEY_W
        case kVK_ANSI_X: GHOSTTY_KEY_X
        case kVK_ANSI_Y: GHOSTTY_KEY_Y
        case kVK_ANSI_Z: GHOSTTY_KEY_Z
        case kVK_ANSI_0: GHOSTTY_KEY_DIGIT_0
        case kVK_ANSI_1: GHOSTTY_KEY_DIGIT_1
        case kVK_ANSI_2: GHOSTTY_KEY_DIGIT_2
        case kVK_ANSI_3: GHOSTTY_KEY_DIGIT_3
        case kVK_ANSI_4: GHOSTTY_KEY_DIGIT_4
        case kVK_ANSI_5: GHOSTTY_KEY_DIGIT_5
        case kVK_ANSI_6: GHOSTTY_KEY_DIGIT_6
        case kVK_ANSI_7: GHOSTTY_KEY_DIGIT_7
        case kVK_ANSI_8: GHOSTTY_KEY_DIGIT_8
        case kVK_ANSI_9: GHOSTTY_KEY_DIGIT_9
        case kVK_ANSI_Grave: GHOSTTY_KEY_BACKQUOTE
        case kVK_ANSI_Backslash: GHOSTTY_KEY_BACKSLASH
        case kVK_ANSI_LeftBracket: GHOSTTY_KEY_BRACKET_LEFT
        case kVK_ANSI_RightBracket: GHOSTTY_KEY_BRACKET_RIGHT
        case kVK_ANSI_Comma: GHOSTTY_KEY_COMMA
        case kVK_ANSI_Equal: GHOSTTY_KEY_EQUAL
        case kVK_ANSI_Minus: GHOSTTY_KEY_MINUS
        case kVK_ANSI_Period: GHOSTTY_KEY_PERIOD
        case kVK_ANSI_Quote: GHOSTTY_KEY_QUOTE
        case kVK_ANSI_Semicolon: GHOSTTY_KEY_SEMICOLON
        case kVK_ANSI_Slash: GHOSTTY_KEY_SLASH
        case kVK_ISO_Section: GHOSTTY_KEY_INTL_BACKSLASH
        case kVK_JIS_Yen: GHOSTTY_KEY_INTL_YEN
        case kVK_JIS_Underscore: GHOSTTY_KEY_INTL_RO
        case kVK_Delete: GHOSTTY_KEY_BACKSPACE
        case kVK_Return: GHOSTTY_KEY_ENTER
        case kVK_Space: GHOSTTY_KEY_SPACE
        case kVK_Tab: GHOSTTY_KEY_TAB
        case kVK_Escape: GHOSTTY_KEY_ESCAPE
        case kVK_ForwardDelete: GHOSTTY_KEY_DELETE
        case kVK_Help: GHOSTTY_KEY_INSERT
        case kVK_Home: GHOSTTY_KEY_HOME
        case kVK_End: GHOSTTY_KEY_END
        case kVK_PageUp: GHOSTTY_KEY_PAGE_UP
        case kVK_PageDown: GHOSTTY_KEY_PAGE_DOWN
        case kVK_UpArrow: GHOSTTY_KEY_ARROW_UP
        case kVK_DownArrow: GHOSTTY_KEY_ARROW_DOWN
        case kVK_LeftArrow: GHOSTTY_KEY_ARROW_LEFT
        case kVK_RightArrow: GHOSTTY_KEY_ARROW_RIGHT
        case kVK_F1: GHOSTTY_KEY_F1
        case kVK_F2: GHOSTTY_KEY_F2
        case kVK_F3: GHOSTTY_KEY_F3
        case kVK_F4: GHOSTTY_KEY_F4
        case kVK_F5: GHOSTTY_KEY_F5
        case kVK_F6: GHOSTTY_KEY_F6
        case kVK_F7: GHOSTTY_KEY_F7
        case kVK_F8: GHOSTTY_KEY_F8
        case kVK_F9: GHOSTTY_KEY_F9
        case kVK_F10: GHOSTTY_KEY_F10
        case kVK_F11: GHOSTTY_KEY_F11
        case kVK_F12: GHOSTTY_KEY_F12
        case kVK_F13: GHOSTTY_KEY_F13
        case kVK_F14: GHOSTTY_KEY_F14
        case kVK_F15: GHOSTTY_KEY_F15
        case kVK_F16: GHOSTTY_KEY_F16
        case kVK_F17: GHOSTTY_KEY_F17
        case kVK_F18: GHOSTTY_KEY_F18
        case kVK_F19: GHOSTTY_KEY_F19
        case kVK_F20: GHOSTTY_KEY_F20
        case kVK_ANSI_Keypad0: GHOSTTY_KEY_NUMPAD_0
        case kVK_ANSI_Keypad1: GHOSTTY_KEY_NUMPAD_1
        case kVK_ANSI_Keypad2: GHOSTTY_KEY_NUMPAD_2
        case kVK_ANSI_Keypad3: GHOSTTY_KEY_NUMPAD_3
        case kVK_ANSI_Keypad4: GHOSTTY_KEY_NUMPAD_4
        case kVK_ANSI_Keypad5: GHOSTTY_KEY_NUMPAD_5
        case kVK_ANSI_Keypad6: GHOSTTY_KEY_NUMPAD_6
        case kVK_ANSI_Keypad7: GHOSTTY_KEY_NUMPAD_7
        case kVK_ANSI_Keypad8: GHOSTTY_KEY_NUMPAD_8
        case kVK_ANSI_Keypad9: GHOSTTY_KEY_NUMPAD_9
        case kVK_ANSI_KeypadDecimal: GHOSTTY_KEY_NUMPAD_DECIMAL
        case kVK_ANSI_KeypadPlus: GHOSTTY_KEY_NUMPAD_ADD
        case kVK_ANSI_KeypadMinus: GHOSTTY_KEY_NUMPAD_SUBTRACT
        case kVK_ANSI_KeypadMultiply: GHOSTTY_KEY_NUMPAD_MULTIPLY
        case kVK_ANSI_KeypadDivide: GHOSTTY_KEY_NUMPAD_DIVIDE
        case kVK_ANSI_KeypadEnter: GHOSTTY_KEY_NUMPAD_ENTER
        case kVK_ANSI_KeypadEquals: GHOSTTY_KEY_NUMPAD_EQUAL
        case kVK_ANSI_KeypadClear: GHOSTTY_KEY_NUM_LOCK
        default: GHOSTTY_KEY_UNIDENTIFIED
        }
    }
}

private extension Unicode.Scalar {
    /// A control character, or one of the private-use code points AppKit gives the
    /// arrow and function keys: not text to type.
    var isControlOrFunctionKey: Bool {
        value < 0x20 || value == 0x7F || (0xF700...0xF8FF).contains(value)
    }
}

// MARK: - Text input

extension TerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        // Committing ends the composition.
        markedText = ""
        guard !text.isEmpty else { return }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            // Not from a key press: the emoji picker, dictation, a text replacement.
            session?.send(text)
            session?.scrollToBottom()
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? string as? String ?? ""
    }

    func unmarkText() {
        markedText = ""
    }

    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Where the input method puts its candidate window: by the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(cursorRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    /// The input system's name for keys that aren't text ("moveLeft:",
    /// "insertNewline:"). The encoder handles those from the key itself; without
    /// this, AppKit beeps at each one.
    override func doCommand(by selector: Selector) {}
}

// MARK: - Mouse

extension TerminalView {
    /// The running program asked for the mouse (an editor, a pager, a file
    /// manager) and gets it, unless Shift is held: that keeps a way to select text.
    private func programTakesMouse(_ event: NSEvent) -> Bool {
        guard let session, session.terminal != nil else { return false }
        return session.tracksMouse && !event.modifierFlags.contains(.shift)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A ⌘ click on a link follows it, whoever has the mouse: programs aren't
        // told about ⌘ in any case.
        if event.modifierFlags.contains(.command), let link = link(at: convert(event.locationInWindow, from: nil)) {
            pressedLink = link
        } else if programTakesMouse(event) {
            pressedMouseButtons |= 1
            sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT, event: event)
        } else {
            beginSelection(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedLink != nil {
            // Dragging away from a link and letting go there leaves it be.
        } else if pressedMouseButtons & 1 != 0 {
            sendMouse(GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_LEFT, event: event)
        } else {
            lastDragLocation = convert(event.locationInWindow, from: nil)
            continueSelection(isRectangle: event.modifierFlags.contains(.option))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let link = pressedLink {
            pressedLink = nil
            if self.link(at: convert(event.locationInWindow, from: nil)) == link { open(link) }
        } else if pressedMouseButtons & 1 != 0 {
            pressedMouseButtons &= ~1
            sendMouse(GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_LEFT, event: event)
        } else {
            endSelection(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if programTakesMouse(event) {
            pressedMouseButtons |= 2
            sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_RIGHT, event: event)
        } else {
            // Shows the context menu.
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if pressedMouseButtons & 2 != 0 {
            sendMouse(GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_RIGHT, event: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if pressedMouseButtons & 2 != 0 {
            pressedMouseButtons &= ~2
            sendMouse(GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_RIGHT, event: event)
        } else {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, programTakesMouse(event) else { return }
        pressedMouseButtons |= 4
        sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_MIDDLE, event: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        if pressedMouseButtons & 4 != 0 {
            sendMouse(GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_MIDDLE, event: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard pressedMouseButtons & 4 != 0 else { return }
        pressedMouseButtons &= ~4
        sendMouse(GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_MIDDLE, event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredLink(modifiers: event.modifierFlags, pointerMoved: true)
        // Programs that follow the pointer without a button down.
        if programTakesMouse(event) {
            sendMouse(GHOSTTY_MOUSE_ACTION_MOTION, button: nil, event: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: hoveredLink == nil ? .iBeam : .pointingHand)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session, session.terminal != nil else { return }
        // A trackpad reports points; a wheel reports notches, taken as three rows each.
        scrollRemainder += event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / cellSize.height
            : event.scrollingDeltaY * 3
        let rows = Int(scrollRemainder.rounded(.towardZero))
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows)
        // Positive is towards the top: older output.
        let steps = min(abs(rows), 30)

        if programTakesMouse(event) {
            // To a program the wheel is two more buttons.
            let button = rows > 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
            for _ in 0..<steps {
                sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: button, event: event)
            }
        } else if session.isAlternateScreen {
            // A full-screen program has no history to scroll. One that didn't ask for
            // the mouse gets arrow keys, so pagers and editors scroll all the same.
            guard session.isModeSet(TerminalMode.alternateScroll) else { return }
            let introducer = session.isModeSet(TerminalMode.cursorKeys) ? "\u{1B}O" : "\u{1B}["
            session.send(String(repeating: introducer + (rows > 0 ? "A" : "B"), count: steps))
        } else {
            session.scroll(byRows: -rows)
        }
    }

    private func sendMouse(_ action: GhosttyMouseAction, button: GhosttyMouseButton?, event: NSEvent) {
        guard let session, let terminal = session.terminal, let mouseEncoder, let mouseEvent else { return }
        // Which events the program wants and in what format.
        ghostty_mouse_encoder_set_from_terminal(mouseEncoder, terminal)

        // In pixels, as everything else the encoder is told.
        func pixels(_ points: CGFloat) -> UInt32 { UInt32(max(points * scale, 0).rounded()) }
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = pixels(bounds.width)
        size.screen_height = pixels(bounds.height)
        size.cell_width = pixels(cellSize.width)
        size.cell_height = pixels(cellSize.height)
        size.padding_left = pixels(Self.inset.width)
        size.padding_top = pixels(Self.inset.height)
        size.padding_right = pixels(bounds.width - Self.inset.width - CGFloat(columns) * cellSize.width)
        size.padding_bottom = pixels(bounds.height - Self.inset.height - CGFloat(rows) * cellSize.height)
        ghostty_mouse_encoder_set(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var isAnyButtonPressed = pressedMouseButtons != 0
        ghostty_mouse_encoder_set(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &isAnyButtonPressed)

        let point = convert(event.locationInWindow, from: nil)
        ghostty_mouse_event_set_action(mouseEvent, action)
        if let button {
            ghostty_mouse_event_set_button(mouseEvent, button)
        } else {
            ghostty_mouse_event_clear_button(mouseEvent)
        }
        ghostty_mouse_event_set_mods(mouseEvent, Self.mods(event.modifierFlags))
        ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: Float(point.x * scale), y: Float(point.y * scale)))

        var output = [UInt8](repeating: 0, count: 64)
        var count = 0
        guard ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, &output, output.count, &count) == GHOSTTY_SUCCESS, count > 0 else { return }
        session.send(Data(output.prefix(count)))
    }
}

// MARK: - Selection

// libghostty-vt has the rules of selecting with the mouse: a drag selects by
// character, a double click by word and a triple click by line, and a drag past the
// top or bottom scrolls. The view reports presses, drags and releases to its
// "selection gesture" and installs the selection that comes back.

extension TerminalView {
    private func gridRef(at point: CGPoint) -> GhosttyGridRef? {
        guard let terminal = session?.terminal else { return nil }
        let cell = cell(at: point)
        let coordinate = GhosttyPointCoordinate(x: UInt16(clamping: cell.column), y: UInt32(clamping: cell.row))
        var ref = GhosttyGridRef()
        let result = ghostty_terminal_grid_ref(terminal, GhosttyPoint(tag: GHOSTTY_POINT_TAG_VIEWPORT, value: .init(coordinate: coordinate)), &ref)
        return result == GHOSTTY_SUCCESS ? ref : nil
    }

    private var selectionGeometry: GhosttySelectionGestureGeometry {
        GhosttySelectionGestureGeometry(
            columns: UInt32(max(columns, 1)),
            cell_width: UInt32(max(cellSize.width * scale, 1)),
            padding_left: UInt32(Self.inset.width * scale),
            screen_height: UInt32(max(bounds.height * scale, 1))
        )
    }

    private func surfacePosition(_ point: CGPoint) -> GhosttySurfacePosition {
        GhosttySurfacePosition(x: Double(point.x * scale), y: Double(point.y * scale))
    }

    private func beginSelection(with event: NSEvent) {
        guard let session, let terminal = session.terminal, let selectionGesture, let selectionPress else { return }
        let point = convert(event.locationInWindow, from: nil)
        lastDragLocation = point
        guard var ref = gridRef(at: point) else { return }
        var position = surfacePosition(point)
        // When and where, so that the gesture can tell a double click from two clicks.
        var time = UInt64(max(event.timestamp, 0) * 1_000_000_000)
        var interval = UInt64(NSEvent.doubleClickInterval * 1_000_000_000)
        var distance = Double(4 * scale)
        var isRectangle = event.modifierFlags.contains(.option)
        ghostty_selection_gesture_event_set(selectionPress, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        ghostty_selection_gesture_event_set(selectionPress, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
        ghostty_selection_gesture_event_set(selectionPress, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time)
        ghostty_selection_gesture_event_set(selectionPress, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
        ghostty_selection_gesture_event_set(selectionPress, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
        ghostty_selection_gesture_event_set(selectionPress, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &isRectangle)

        var selection = GhosttySelection()
        if ghostty_selection_gesture_event(selectionGesture, terminal, selectionPress, &selection) == GHOSTTY_SUCCESS {
            session.select(selection)
        } else {
            // A single click selects nothing, and drops what was selected.
            session.clearSelection()
        }
    }

    private func continueSelection(isRectangle: Bool) {
        guard let session, let terminal = session.terminal, let selectionGesture, let selectionDrag,
              var ref = gridRef(at: lastDragLocation) else { return }
        var position = surfacePosition(lastDragLocation)
        var geometry = selectionGeometry
        var isRectangle = isRectangle
        ghostty_selection_gesture_event_set(selectionDrag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        ghostty_selection_gesture_event_set(selectionDrag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
        ghostty_selection_gesture_event_set(selectionDrag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
        ghostty_selection_gesture_event_set(selectionDrag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &isRectangle)
        var selection = GhosttySelection()
        if ghostty_selection_gesture_event(selectionGesture, terminal, selectionDrag, &selection) == GHOSTTY_SUCCESS {
            session.select(selection)
        }

        // Past the top or bottom edge, the history scrolls under the pointer for
        // as long as it's held there.
        var direction = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
        ghostty_selection_gesture_get(selectionGesture, terminal, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &direction)
        if direction == GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE {
            stopAutoscroll()
        } else if autoscrollTimer == nil {
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscroll(isRectangle: isRectangle) }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoscrollTimer = timer
        }
    }

    private func autoscroll(isRectangle: Bool) {
        guard let session, let terminal = session.terminal, let selectionGesture, let selectionTick else {
            stopAutoscroll()
            return
        }
        let cell = cell(at: lastDragLocation)
        var viewport = GhosttyPointCoordinate(x: UInt16(clamping: cell.column), y: UInt32(clamping: cell.row))
        var position = surfacePosition(lastDragLocation)
        var geometry = selectionGeometry
        var isRectangle = isRectangle
        ghostty_selection_gesture_event_set(selectionTick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &viewport)
        ghostty_selection_gesture_event_set(selectionTick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
        ghostty_selection_gesture_event_set(selectionTick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
        ghostty_selection_gesture_event_set(selectionTick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &isRectangle)
        // Scrolls one row and extends the selection to the pointer.
        var selection = GhosttySelection()
        if ghostty_selection_gesture_event(selectionGesture, terminal, selectionTick, &selection) == GHOSTTY_SUCCESS {
            session.select(selection)
        } else {
            stopAutoscroll()
        }
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    private func endSelection(with event: NSEvent) {
        stopAutoscroll()
        guard let terminal = session?.terminal, let selectionGesture, let selectionRelease else { return }
        if var ref = gridRef(at: convert(event.locationInWindow, from: nil)) {
            ghostty_selection_gesture_event_set(selectionRelease, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        }
        ghostty_selection_gesture_event(selectionGesture, terminal, selectionRelease, nil)
    }
}

// MARK: - Clipboard and menu

extension TerminalView: NSUserInterfaceValidations {
    @objc func copy(_ sender: Any?) {
        guard let text = session?.selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        if let text = Self.pasteableText(from: .general) { pasteText(text) }
    }

    override func selectAll(_ sender: Any?) {
        session?.selectAll()
    }

    @objc func clearTerminal(_ sender: Any?) {
        session?.clear()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): session?.hasSelection == true
        case #selector(paste(_:)): Self.pasteableText(from: .general) != nil
        case #selector(selectAll(_:)), #selector(clearTerminal(_:)): session?.terminal != nil
        default: true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let link = link(at: convert(event.locationInWindow, from: nil)) {
            let open = menu.addItem(withTitle: link.url.isFileURL ? String(localized: "Open File") : String(localized: "Open Link"), action: #selector(openLink(_:)), keyEquivalent: "")
            let copy = menu.addItem(withTitle: link.url.isFileURL ? String(localized: "Copy Path") : String(localized: "Copy Link"), action: #selector(copyLink(_:)), keyEquivalent: "")
            open.representedObject = link
            copy.representedObject = link
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Paste"), action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Clear"), action: #selector(clearTerminal(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    /// Text from a pasteboard: copied files and folders paste as their paths.
    private static func pasteableText(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { shellEscaped($0.path) }.joined(separator: " ")
        }
        return pasteboard.string(forType: .string)
    }

    /// A path as it's typed at a shell prompt, with a backslash before each
    /// character the shell would otherwise read as its own.
    private static func shellEscaped(_ path: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+:@%,=~"))
        return path.unicodeScalars.reduce(into: "") { escaped, scalar in
            if !plain.contains(scalar) { escaped.append("\\") }
            escaped.unicodeScalars.append(scalar)
        }
    }

    private func pasteText(_ text: String) {
        guard let session else { return }
        guard session.paste(text) == .needsConfirmation, let window else { return }
        // A program that hasn't asked for pastes to be marked as such (a shell at
        // its prompt has) can't tell pasted lines from typed ones, and runs each.
        let alert = NSAlert()
        alert.messageText = String(localized: "Paste text with several lines?")
        alert.informativeText = String(localized: "Each line is run as it’s pasted, as if you had typed it and pressed Return.")
        alert.addButton(withTitle: String(localized: "Paste"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                _ = self?.session?.paste(text, allowingUnsafe: true)
            }
        }
    }

    // MARK: Dropped files

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        session?.terminal != nil ? .copy : []
    }

    /// A file dragged from the Finder types its path.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = Self.pasteableText(from: sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        pasteText(text + " ")
        return true
    }
}
