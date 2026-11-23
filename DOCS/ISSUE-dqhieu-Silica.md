# The editor view jumps by one line, or the lines above become blank, when typing in the middle or lower part of the file.

## Description

In long files (more than 120-150 lines), editing somewhere in the middle or lower part of the document makes the editor view misbehave. It happens after scrolling down with the scroll bar, so the view is neither at the top nor at the end of the file.

Two related symptoms:

1. **The view jumps by one line as soon as typing starts.** The line shown at the top becomes the one before it (for example, line 262 was at the top and line 261 now is).
2. **After pressing Return, the first one or more visible lines go blank.** The gutter still shows the correct line numbers for them. The text comes back after undoing. This is more likely the further down the file you are.

Both are frequent but intermittent. Typing at the end of the file, or with the view scrolled to the very top, works fine.

Reproduced in Silica 0.8.0 on macOS 26 and 27.

## Steps to reproduce

1. Open a long file (a few hundred lines).
2. Drag the vertical scroll bar to somewhere in the middle or lower of the file.
3. Click on a line and type a character or press Return: the view shifts by one line.
4. Press Return a few times on a line in the middle or lower of the view: occasionally the top two (or more) lines go blank.

## Assumptions about the cause

Both come from TextKit 2's viewport-based layout. The editor's text view uses TextKit 2 (`EditorTextView(usingTextLayoutManager: true)`).

- **Estimated line heights above the view.** TextKit 2 only lays out what is on screen. After jumping with the scroll bar, the lines above the view only have estimated heights. The next layout pass after an edit replaces those estimates with real heights, which moves the visible text.
- **Whole-file recoloring.** `SyntaxHighlighter.apply(_:)` re-applies `.foregroundColor` to the entire document about 120 ms after every edit. That invalidates the layout of every line, including the estimated ones above the view, and triggers the same correction.
- **Viewport out of sync after Return.** When AppKit scrolls the caret into view (`scrollRangeToVisible`), TextKit 2 can move its viewport toward the caret without scrolling the view, and nothing lays the viewport out again. Lines outside the viewport are not drawn, though the line-number gutter, which queries the layout manager directly, still numbers them. This is the same issue the existing find-bar workaround in `EditorTextView.scrollRangeToVisible(_:)` handles; that workaround is currently limited to the find bar.

## The implemented fixes improve the issue, but not completely

I have tried a fix, in two files. It greatly reduces both symptoms; the blank lines still show up very rarely when pressing Return near the end of very long files. But after numerous tests, the issue has not completely disappeared.

**`SyntaxHighlighter.swift`**
- `apply(_:)` computes the desired color for each UTF-16 unit and only sets `.foregroundColor` on runs whose color actually changes, usually just the token being typed.

**`EditorTextView.swift`**
- **Before each edit** (`shouldChangeText(in:replacementString:)` and `shouldChangeText(inRanges:replacementStrings:)`), it lays out the text from the start of the document through the bottom of the view with `ensureLayout(for:)`. If that moves the top line, it scrolls back so the top line stays put. This happens while handling the key press, not during layout or drawing, so the edit has no estimates left to correct. It is skipped until the view scrolls, resizes or changes font.
- **After `scrollRangeToVisible`**, outside the find bar, it checks whether the viewport now starts below the line at the top of the view. Only in that case does it call `layoutViewport()`, so normal typing does not force an extra layout on every edit.
- **After the layout pass that follows an edit**, it runs the same check on the next turn of the run loop, not in the middle of layout and drawing.

A full fix would probably mean moving syntax coloring to TextKit 2 rendering attributes (`NSTextLayoutManager.setRenderingAttributes`), which do not affect layout. That is a bigger change, since the minimap reads colors from the text storage.

## Requirement for you developers

Have you checked whether you’re also experiencing this issue? If you see it too, please try to find a fix; I’m giving up, as I haven’t been able to find a definitive solution despite spending several hours on it. 