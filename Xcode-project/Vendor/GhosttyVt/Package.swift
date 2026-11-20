// swift-tools-version: 5.9
import PackageDescription

// libghostty-vt, Ghostty's terminal emulation core, for the integrated terminal.
// It's published as a prebuilt XCFramework rather than as a Swift package, so this
// local package is only the binary target that fetches it.
//
// To update: change the version in the URL, and set the checksum to the line for
// the zip in https://release.files.ghostty.org/libghostty-vt/<version>/SHA256SUMS
let package = Package(
    name: "GhosttyVt",
    products: [
        .library(name: "GhosttyVt", targets: ["GhosttyVt"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://release.files.ghostty.org/libghostty-vt/1.0.1/ghostty-vt-1.0.1.xcframework.zip",
            checksum: "c0f9631277f726154c8f521954d17cdc41aac4626fc0df8cf925a19ee58e829b"
        ),
    ]
)
