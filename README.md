# Silica

![Platform](https://img.shields.io/badge/macOS-15+-orange.svg)
![Swift](https://img.shields.io/badge/Swift-5+-lavender.svg)
![Xcode](https://img.shields.io/badge/Xcode-26+-blue.svg)

A lightweight code editor for macOS, made of glass. Open a folder, find files fast, and edit with syntax highlighting, a minimap and a Markdown preview, all in a native SwiftUI and AppKit app.

![Window](Images/screenshot.png)

## Personal motivation

I really like the original project and the Silica app, which works very well. It’s now my text and code editor in macOS. I have made a few changes to the project, tailored to my personal preferences. Without any intention of interfering with the original project—which I consider an excellent piece of work—here are the changes I have made in my fork:

- Migrate the Xcode project from the JSON `xcproj` format (introduced in Xcode 27) to the older `pbxproj` format to ensure compatibility (this change allows me to work on the project using Xcode 26 on macOS Tahoe)
- Fix a crash when building Release in Xcode 26 on macOS Tahoe
- Lower the minimum macOS version to 15 (ported from the original project); Liquid Glass stays exclusive to macOS 26 and later.
- Localize the interface and alerts, adding a simple language system with English (default) and Spanish
- Add an option to switch between glass and opaque window styles, since I prefer opaque windows
- Enable New File (⌘N) menu and keyboard shortcut from the app startup → open a blank text file without an associated project
- Choose whether to start with the welcome window, an empty workspace, or a blank text file
- Add "Open in Silica" to the Finder's Services menu for folders

## Download

Get the latest DMG from [Releases](https://github.com/perez987/Silica/releases/latest), open it and drag Silica to Applications. Silica checks for updates once a day and installs them for you; you can turn that off in Settings › General.

Silica needs macOS 15 or later. The Liquid Glass look needs macOS 26; earlier versions always use the opaque window style with plain bordered cards.

## Features

- **Projects.** Open a folder to get a window with a file tree and Finder folder icons. Files and folders your `.gitignore` excludes are dimmed, and the tree updates as files change on disk. Create, rename and move files to the Trash, drag files and folders (including the project icon beside its name) to other apps, filter the tree as you type, and reveal a tab's file from its menu.
- **Quick Open and project search.** Jump to any file with fuzzy matching, or search the text of every file in the project.
- **Syntax highlighting** for 27 languages, including Swift, JavaScript, TypeScript, Python, Go, Rust, C, C++, Java, Kotlin, Dart, HTML, CSS, JSON, YAML, Markdown and diff files.
- **Nine color themes**, each with a light and a dark palette: Atom One, GitHub,
  Xcode, Solarized, Catppuccin, Gruvbox, Tokyo Night, Rosé Pine and Dracula.
- **Markdown preview**, with highlighted code blocks.
- **CSV and TSV preview**, with a table view.
- **HTML preview**, including unsaved edits, project assets and page scripts.
- **PDF viewing**, including password-protected files.
- **Editing tools.** Tabs, in-file search with highlighted matches, line numbers, indent guides, a vertical scrollbar (following macOS scroll bar preferences), an optional minimap, word wrap, go to line, toggle comment, and moving or duplicating lines.
- **Integrated terminal.** Open a resizable terminal below the editor using the title bar or ⌃`. Shells start in the project folder (or home for a standalone window); add tabs, drag to reorder them, and hide the card without stopping them. Command-click links or file paths to open them.
- **New files.** Press `⌘N` to start an empty plain-text file, even without an open project. Choose where to save it when ready; the suggested filename uses `.txt`, which you can change.
- **Picks up where you left off.** Projects reopen their tabs, and recent projects are on the welcome window. Choose the welcome window, an empty workspace, or a blank text file at launch in Settings › General. Reopen the welcome window with File › Welcome Window or `⇧⌘1`.
- **Appearance and language.** Choose glass or opaque windows in Settings › General. The opaque editor background is black in dark appearance and white in light appearance. Silica follows the macOS language preference, with English and Spanish available.
- **Works with Finder.** Use Open With or drop files on the Dock icon. Drag a file or folder out of the sidebar, or the project's folder icon from beside its name, to hand it to Terminal, Finder or another app.
- **Opens from the terminal.** `silica .` opens the current folder as a project, and `silica <file>` opens a file in the project it belongs to. Homebrew installs the command with the app; otherwise install it from Settings › General.

## Keyboard shortcuts

| Shortcut     | Action                                    |
| ------------ | ----------------------------------------- |
| ⇧⌘1          | Show welcome window                       |
| ⌘N           | New file                                  |
| ⌘P           | Quick Open                                |
| ⇧⌘F          | Find in Project                           |
| ⌥⌘J          | Filter files in the tree                  |
| ⌘L           | Go to Line                                |
| ⇧⌘V          | Toggle Markdown, CSV, TSV or HTML preview  |
| ⌃⌘S          | Show or hide the sidebar                  |
| ⌃`           | Show or focus the terminal; hide it when focused |
| ⌃⇧`          | New terminal                              |
| ⌘K           | Clear the focused terminal                |
| ⌃Tab / ⌃⇧Tab | Select the next or previous file or terminal tab (also ⇧⌘] / ⇧⌘[) |
| ⌘/           | Toggle comment                            |
| ⌥↑ / ⌥↓      | Move lines up or down                     |
| ⇧⌥↑ / ⇧⌥↓    | Duplicate lines up or down                |
| ⌥Z           | Word wrap                                 |
| ⌘+ / ⌘− / ⌘0 | Increase, decrease or reset the font size |

## Building from source

You need Xcode 26.

1. Clone the repository and open `Silica.xcodeproj`.
2. In the Silica target's Signing & Capabilities, choose your own team (or "Sign to
   Run Locally"). Please don't commit that change.
3. Press ⌘R. Xcode fetches the Swift packages on the first build.

## Contributing

Bug reports, ideas and pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) before you start on a change.

## License

Silica is released under the [MIT License](LICENSE). It includes
[swift-markdown](https://github.com/swiftlang/swift-markdown),
[swift-cmark](https://github.com/swiftlang/swift-cmark),
[Sparkle](https://sparkle-project.org) and [libghostty-vt](https://lib.ghostty.org), whose licenses are in
`Silica/Resources/Licenses` and in Settings › About.
