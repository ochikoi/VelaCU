import Foundation
import CoreGraphics
import ImageIO

func fail(_ message: String) -> Never {
    fputs("PreparePointerAsset: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: PreparePointerAsset INPUT.jpg OUTPUT.png")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("could not read input image")
}

let width = image.width
let height = image.height
var sourceBytes = [UInt8](repeating: 0, count: width * height * 4)
guard let sourceContext = CGContext(
    data: &sourceBytes,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fail("could not create source context") }
sourceContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func channel(_ offset: Int) -> Int {
    Int(sourceBytes[offset])
}

var minX = width
var minY = height
var maxX = -1
var maxY = -1
var maxDarkness = 0
for y in 0..<height {
    for x in 0..<width {
        let offset = (y * width + x) * 4
        let r = channel(offset)
        let g = channel(offset + 1)
        let b = channel(offset + 2)
        let darkness = 255 - min(r, g, b)
        maxDarkness = max(maxDarkness, darkness)
        if darkness > 5 {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
}
guard maxX >= minX, maxY >= minY else { fail("no foreground arrow found") }

let cropWidth = maxX - minX + 1
let cropHeight = maxY - minY + 1
var outputBytes = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
let fullDarkness = max(1, maxDarkness)

func unblend(_ channel: Int, alpha: Double) -> UInt8 {
    guard alpha > 0.001 else { return 0 }
    // Remove only the white JPEG background contribution, retaining the
    // original foreground channel and premultiplying it for the output PNG.
    let foreground = max(0.0, min(255.0, (Double(channel) - 255.0 * (1.0 - alpha)) / alpha))
    return UInt8(foreground * alpha)
}

for y in 0..<cropHeight {
    for x in 0..<cropWidth {
        let sourceOffset = ((minY + y) * width + minX + x) * 4
        let darkness = 255 - min(channel(sourceOffset), min(channel(sourceOffset + 1), channel(sourceOffset + 2)))
        let alpha = max(0.0, min(1.0, Double(darkness) / Double(fullDarkness)))
        let outputOffset = (y * cropWidth + x) * 4
        outputBytes[outputOffset] = unblend(channel(sourceOffset), alpha: alpha)
        outputBytes[outputOffset + 1] = unblend(channel(sourceOffset + 1), alpha: alpha)
        outputBytes[outputOffset + 2] = unblend(channel(sourceOffset + 2), alpha: alpha)
        outputBytes[outputOffset + 3] = UInt8(alpha * 255.0)
    }
}

guard let outputContext = CGContext(
    data: &outputBytes,
    width: cropWidth,
    height: cropHeight,
    bitsPerComponent: 8,
    bytesPerRow: cropWidth * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
), let outputImage = outputContext.makeImage(),
let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
    fail("could not create output PNG")
}
CGImageDestinationAddImage(destination, outputImage, nil)
guard CGImageDestinationFinalize(destination) else { fail("could not write output PNG") }
print("Prepared \(cropWidth)x\(cropHeight) pointer asset from \(width)x\(height) source")
