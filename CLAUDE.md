# Agent guidance

Read `CONTRIBUTING.md` before making changes.

## Project

- Silica is a macOS editor built with SwiftUI and AppKit. Open `Silica.xcodeproj` with Xcode 26 or later; the deployment target is macOS 26.
- App entry points are in `Silica/App`, views in `Silica/Views`, editor code in `Silica/Editor`, models in `Silica/Models`, terminal code in `Silica/Terminal`, and shared helpers in `Silica/Support`.
- Preserve opaque behavior when the user selects the opaque window style; reuse the existing appearance helpers.
- Maintain English and Spanish localization in `Silica/en.lproj/Localizable.strings` and `Silica/es.lproj/Localizable.strings` when changing user-facing text.

## Changes and validation

- Keep changes focused, follow existing patterns, and prefer platform APIs over new dependencies. Do not commit local signing changes.
- Build without new warnings. Manually check UI changes in light and dark appearances; for window appearance changes, check both glass and opaque styles.
- There is no automated app test suite. For tokenizer changes, run the standalone Dart checks documented in `CONTRIBUTING.md`.
- Do not change the app version in a pull request. Release instructions are in `RELEASING.md`.
