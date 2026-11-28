// Draws the DMG window "background" for release.sh: a fully transparent PNG holding only an
// arrow from the app icon to the Applications link. Transparent pixels let Finder's own window
// colour show through, so the window follows Light and Dark mode; the arrow is a mid grey that
// reads on both (about 3.5:1 on white and 4.5:1 on Finder's dark grey).
//
// Usage: swift dmg-arrow.swift <out.png> <width> <height> <fromX> <toX> <y> <scale>
//   width, height, fromX, toX and y are in points (y from the top, like appdmg); scale is 1 or 2.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 8,
      let width = Double(args[2]), let height = Double(args[3]),
      let fromX = Double(args[4]), let toX = Double(args[5]), let y = Double(args[6]),
      let scale = Double(args[7]), width > 0, height > 0, toX > fromX, scale > 0
else {
    FileHandle.standardError.write(Data("usage: dmg-arrow.swift <out.png> <width> <height> <fromX> <toX> <y> <scale>\n".utf8))
    exit(2)
}

let pixelsWide = Int(width * scale)
let pixelsHigh = Int(height * scale)
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }

// Work in points with the origin at the top left, as appdmg places the icons.
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: 0, y: height)
ctx.scaleBy(x: 1, y: -1)
ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

let lineWidth = 7.0
let head = 22.0 // length of each side of the arrow head
let tip = CGPoint(x: toX, y: y)
let path = CGMutablePath()
path.move(to: CGPoint(x: fromX, y: y))
path.addLine(to: tip)
path.move(to: CGPoint(x: toX - head * 0.75, y: y - head * 0.75))
path.addLine(to: tip)
path.addLine(to: CGPoint(x: toX - head * 0.75, y: y + head * 0.75))

ctx.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.55, blue: 0.57, alpha: 1)) // ≈ systemGray
ctx.setLineWidth(lineWidth)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.addPath(path)
ctx.strokePath()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
// DPI tells Finder the @2x image is Retina, not twice as large.
let dpi = 72 * scale
CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
guard CGImageDestinationFinalize(dest) else { exit(1) }
