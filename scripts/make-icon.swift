// Builds a macOS app-icon .iconset from a square logo PNG.
//
// The logo is trimmed by a few pixels (removes export edge artefacts), scaled into the
// standard macOS icon body (824 pt inside a 1024 pt canvas), masked with a superellipse
// ("squircle") and given the usual soft drop shadow and a hairline rim.
//
// Usage (compile with the Command Line Tools swiftc, then run):
//   make-icon <logo.png> <output.iconset>
//   iconutil -c icns <output.iconset> -o AppIcon.icns

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let body: CGFloat = 824
let trim = 3

func squircle(in rect: CGRect, exponent n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let cx = Double(rect.midX), cy = Double(rect.midY)
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make-icon <logo.png> <output.iconset>"); exit(2) }
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(src, 0, nil),
      let trimmed = logo.cropping(to: CGRect(x: trim, y: trim, width: logo.width - 2 * trim, height: logo.height - 2 * trim))
else { print("cannot read \(args[1])"); exit(1) }

// Master 1024 x 1024.
let master = makeContext(Int(canvas))
master.interpolationQuality = .high
let bodyRect = CGRect(x: (canvas - body) / 2, y: (canvas - body) / 2, width: body, height: body)
let shape = squircle(in: bodyRect)

master.saveGState()
master.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.32))
master.addPath(shape)
master.setFillColor(CGColor(gray: 0.5, alpha: 1))
master.fillPath()
master.restoreGState()

master.saveGState()
master.addPath(shape)
master.clip()
master.draw(trimmed, in: bodyRect)
master.restoreGState()

master.saveGState()
master.addPath(shape)
master.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
master.setLineWidth(2)
master.strokePath()
master.restoreGState()

let masterImage = master.makeImage()!

let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    let ctx = makeContext(px)
    ctx.interpolationQuality = .high
    ctx.draw(masterImage, in: CGRect(x: 0, y: 0, width: px, height: px))
    writePNG(ctx.makeImage()!, to: outDir.appendingPathComponent(name + ".png"))
}
print("wrote \(variants.count) icons to \(outDir.path)")
