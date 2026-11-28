# CLAUDE.md — Silica

Guidance for AI coding agents (Claude Code and similar) working in this repository.
Read it fully before changing code. If anything here disagrees with the actual repo, **the repo wins**: fix this file in the same change.

## What Silica is

A text and code editor for macOS, written in **Swift** with **SwiftUI + AppKit**.
- Repo: https://github.com/perez987/Silica
- Default UI language: **English**, with a full **Spanish** translation.
- Platform: macOS only (no iOS targets).

## Repository layout

```
Silica/
├── Xcode-project/     # Xcode project (Silica.xcodeproj) and app sources
├── Scripts/
│   ├── release.sh     # Builds, signs, creates the DMG and notarizes it
│   └── publish.sh     # Publishes the DMG as a GitHub release
├── Distribute/        # Generated DMG output (do not commit binaries)
└── CLAUDE.md
```

> Before assuming source file paths, explore `Xcode-project/` (e.g. `find Xcode-project -name '*.swift'`).

## Development environment

The project is worked on across several machines; code must build on all of them:

| Machine | Architecture | macOS | Xcode |
|---|---|---|---|
| Mac Pro (main, holds the repo) | Intel x86_64 | Tahoe (26) | 26 (sometimes 27) |
| Mac M4 (secondary) | Apple Silicon | 27 | 27 |

Resulting rules:
- **Do not use Xcode 27 / macOS 27-only APIs** without guarding them with `if #available(macOS 27, *)`.
- Do not raise the deployment target or Swift version unless explicitly asked.
- Build with **Universal (x86_64 + arm64)** in mind.
- The Intel Mac Pro has **no Homebrew**. Do not suggest `brew install`; tools are installed from their source repo (`make install`) or via `npm`.

## Build and test

From the repo root:

```bash
# List available schemes
xcodebuild -list -project Xcode-project/Silica.xcodeproj

# Debug build
xcodebuild -project Xcode-project/Silica.xcodeproj -scheme Silica -configuration Debug build

# Tests (if a test target exists)
xcodebuild -project Xcode-project/Silica.xcodeproj -scheme Silica test
```

- After any code change, **build** before calling the task done.
- If you cannot build (e.g. a Linux environment without Xcode), say so clearly in your summary and review the code with extra care.

## Architecture and conventions

- **SwiftUI** for app structure, windows, menus and settings.
- **AppKit** (`NSTextView`, `NSScrollView`, `NSTextFinder`, …) for the editor, wrapped with `NSViewRepresentable` / `NSViewControllerRepresentable`.
- All UI and `NSTextStorage` manipulation happens on the **main thread** (`@MainActor`).
- When touching the SwiftUI ↔ AppKit bridge, respect the `makeNSView` / `updateNSView` / `Coordinator` lifecycle: `updateNSView` is called often; do not recreate state or reset the selection there.
- Style: idiomatic Swift, prefer `let` over `var`, descriptive names, no force unwraps unless failure is clearly impossible.
- Keep changes minimal and focused: do not reformat or reorganize files unrelated to the task.

### Known bug: find bar highlighting (Cmd+F)

When the find bar is opened and text is typed, **matches are not highlighted**. They are highlighted if the bar is closed and reopened, or if the bar already contains the last search term.
Leads: `NSTextFinder` configuration (`isIncrementalSearchingEnabled`, `incrementalSearchingShouldDimContentView`), the assigned `client` / `findBarContainer`, `noteClientStringWillChange()`, and whether the `NSTextView` is recreated or loses its `textFinder` in `updateNSView`.

## Localization (English + Spanish)

Translations live in `.lproj` folders (`en.lproj`, `es.lproj`), each containing:
- `Localizable.strings` — app UI strings.
- `ServicesMenu.strings` — strings for the Services menu entries.

Rules:
- Every user-facing string must be localized; **never** leave hard-coded literals in the UI.
- Every new key must be added to **both** `en.lproj` and `es.lproj`, in the matching file, with the same key.
- Keep the `"key" = "value";` format valid (escaped quotes, trailing semicolon); a single syntax error breaks the whole file at runtime.
- Spanish: Spain Spanish, neutral and concise, consistent with existing translations.

## Distribution: signed and notarized DMG

- `Scripts/release.sh` → builds Release, signs with *Developer ID*, creates the DMG in `Distribute/` and notarizes it (`xcrun notarytool` + `xcrun stapler`).
- `Scripts/publish.sh` → creates the GitHub release and uploads the DMG.
- The DMG is built with **`create-dmg` from npm (sindresorhus)** or **`appdmg`**. Do **not** use the shell `create-dmg`: on Tahoe Intel it does not apply the window layout.
- **Credentials**: never write passwords, private Team IDs, API keys or notarization profiles into the repo. Use a keychain profile (`notarytool --keychain-profile`) or environment variables.
- Scripts must work with macOS's **bash 3.2** and with `set -euo pipefail`.
- Do not run `publish.sh` or create releases/tags without the user's explicit confirmation.

## Git

- Do not commit or push unless asked. If on `main`, create a branch first.
- Clear, imperative commit messages in English.
- Do not commit build artifacts: `build/`, `DerivedData/`, `*.dmg`, `Distribute/*`, `xcuserdata/`, `.DS_Store`.

## Checklist before finishing

1. The project builds (or you state why it could not be built).
2. New strings exist in both `en.lproj` and `es.lproj`.
3. Nothing requires macOS/Xcode 27 without `#available`.
4. No credentials or binaries were added to the repo.
5. The final summary explains what changed and what is still pending.
