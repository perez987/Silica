import AppKit

/// The `silica` terminal command: a script in the app bundle (Resources/silica) that
/// hands its arguments to `open -a`, and the symlink on PATH that makes it a command.
enum CommandLineTool {
    static let name = "silica"

    /// Where Settings installs the command. On PATH for every shell through
    /// /etc/paths, but owned by root on most Macs.
    private static let installFolder = "/usr/local/bin"

    /// Where else a link to this copy may already be: Homebrew's cask puts it in
    /// its own bin.
    private static let knownFolders = [installFolder, "/opt/homebrew/bin"]

    private static var script: URL? {
        Bundle.main.url(forResource: name, withExtension: nil)
    }

    private static var linkPath: String { installFolder + "/" + name }

    /// The link on PATH that runs this copy's script, if there is one.
    static var installedPath: String? {
        guard let script else { return nil }
        let destination = script.resolvingSymlinksInPath().path(
            percentEncoded: false
        )
        return
            knownFolders
            .map { $0 + "/" + name }
            .first { path in
                (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: path
                )) != nil
                    && URL(filePath: path).resolvingSymlinksInPath().path(
                        percentEncoded: false
                    ) == destination
            }
    }

    /// Why the command can't be installed from where the app is running, if it can't.
    /// Opened straight from the disk image or the Downloads folder, the app runs from
    /// a read-only volume (macOS moves a quarantined app to one), and a link to a
    /// path there breaks as soon as the app quits.
    static var unavailableReason: String? {
        guard script != nil else {
            return "This copy of Silica doesn’t include the command."
        }
        let volumeIsReadOnly =
            (try? Bundle.main.bundleURL.resourceValues(forKeys: [
                .volumeIsReadOnlyKey
            ]).volumeIsReadOnly) ?? false
        if volumeIsReadOnly
            || Bundle.main.bundlePath.contains("/AppTranslocation/")
        {
            return "Move Silica to the Applications folder first."
        }
        return nil
    }

    /// Links the command into /usr/local/bin, asking for an administrator's password
    /// where the folder isn't the user's to write to (as on most Macs).
    static func install() async {
        guard unavailableReason == nil, let script else { return }
        let fileManager = FileManager.default
        let target = script.path(percentEncoded: false)

        // A link is replaced (it's an older install, or another copy's); anything
        // else there isn't Silica's to overwrite.
        let existingIsLink =
            (try? fileManager.destinationOfSymbolicLink(atPath: linkPath))
            != nil
        if !existingIsLink, fileManager.fileExists(atPath: linkPath) {
            let alert = NSAlert()
            alert.messageText =
                "There’s already a different “\(name)” in \(installFolder)."
            alert.informativeText =
                "Move or remove \(linkPath), then try again."
            alert.runModal()
            return
        }

        do {
            try fileManager.createDirectory(
                atPath: installFolder,
                withIntermediateDirectories: true
            )
            if existingIsLink { try fileManager.removeItem(atPath: linkPath) }
            try fileManager.createSymbolicLink(
                atPath: linkPath,
                withDestinationPath: target
            )
        } catch {
            switch await linkAsAdministrator(to: target) {
            case .linked, .cancelled: break
            case .failed: offerTerminalCommand(linking: target)
            }
        }
    }

    private enum AdministratorOutcome {
        case linked, cancelled, failed
    }

    /// Makes the link as root, behind the system's password prompt. AppleScript's
    /// `do shell script … with administrator privileges` is the supported way to ask
    /// for that without a privileged helper; `osascript` runs it so the wait for the
    /// password happens outside the app.
    private static func linkAsAdministrator(to target: String) async
        -> AdministratorOutcome
    {
        let command =
            "/bin/mkdir -p \(shellQuoted(installFolder)) && /bin/ln -sf \(shellQuoted(target)) \(shellQuoted(linkPath))"
        let prompt =
            "Silica wants to install the “\(name)” command in \(installFolder)."
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/osascript")
            // The command and the prompt go in as arguments, so neither needs
            // escaping as AppleScript.
            process.arguments = [
                "-e", "on run argv",
                "-e",
                "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
                "-e", "end run",
                command, prompt,
            ]
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            do {
                try process.run()
            } catch {
                return AdministratorOutcome.failed
            }
            let message = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            process.waitUntilExit()
            if process.terminationStatus == 0 { return .linked }
            // -128 is AppleScript's "User canceled": the prompt was dismissed.
            return message.contains("-128") ? .cancelled : .failed
        }.value
    }

    /// For when the password prompt itself fails: the same thing, to run by hand.
    private static func offerTerminalCommand(linking target: String) {
        var command = "sudo ln -sf \(shellQuoted(target)) \(linkPath)"
        if !FileManager.default.fileExists(atPath: installFolder) {
            command = "sudo mkdir -p \(installFolder) && " + command
        }
        let alert = NSAlert()
        alert.messageText = "The command couldn’t be installed."
        alert.informativeText =
            "Run this in Terminal to install it:\n\n\(command)"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
