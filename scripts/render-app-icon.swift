import AppKit
import ImageIO
import UniformTypeIdentifiers

// Export the approved Mac artwork as an opaque iOS icon; no redesign or regeneration.
// Usage: swift scripts/render-app-icon.swift OUTPUT [SOURCE]
let output = CommandLine.arguments[1]
let source = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "macos/Assets/AppIcon.png"
guard let input = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
    fatalError("Could not read approved icon artwork")
}
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.035, green: 0.16, blue: 0.11, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
    UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
