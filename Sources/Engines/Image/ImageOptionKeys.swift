import Foundation

/// Stable option keys of the image schemas (the JSON keys of presets). Names follow spec/handbrake.md 3.1.
/// Adding keys is free; renaming or removing one breaks stored presets and quick recipes (report it).
enum ImageKeys {
    // Format
    static let format = "img.format"            // same, jpeg, png, heic, avif, webp, tiff, gif, bmp, jp2, tga, ico, icns, pdf
    static let quality = "img.quality"          // 1...100
    static let targetKB = "img.targetKB"        // 0 = off
    static let lossless = "img.lossless"        // WebP only
    static let progressive = "img.jpeg.progressive"
    static let subsampling = "img.jpeg.subsampling"   // "420" | "444" (444 needs ffmpeg)
    static let alphaBackground = "img.alpha.bg"
    static let pngInterlace = "img.png.interlace"
    static let pngPalette = "img.png.palette"         // quantise to 256 colours (Floyd-Steinberg) when the picture has no translucency
    static let tiffCompression = "img.tiff.compression"   // none, lzw, packbits, deflate
    static let icoSizes = "img.ico.sizes"             // "256,128,64,48,32,16"
    // Size and crop
    static let sizeMode = "img.size.mode"       // original, longEdge, fit, exact, fill, percent, megapixels
    static let sizeLong = "img.size.long"
    static let sizePercent = "img.size.percent"
    static let sizeWidth = "img.size.w"
    static let sizeHeight = "img.size.h"
    static let sizeMegapixels = "img.size.mp"
    static let upscale = "img.size.upscale"
    static let dpi = "img.dpi"                  // keep, 72 ... 600
    static let autoOrient = "img.orient.auto"
    static let cropMode = "img.crop.mode"       // none, ratio, autoTrim, rect
    static let cropRatio = "img.crop.ratio"
    static let cropAnchor = "img.crop.anchor"   // center, top, bottom, left, right, subject
    static let cropTrim = "img.crop.trim"       // tolerance in percent
    static let cropX = "img.crop.x"
    static let cropY = "img.crop.y"
    static let cropW = "img.crop.w"
    static let cropH = "img.crop.h"
    static let rotate = "img.rotate"            // 0, 90, 180, 270 (clockwise)
    static let flipH = "img.flipH"
    static let flipV = "img.flipV"
    // Colour
    static let colorSpace = "img.cs"            // keep, srgb, p3, adobe, gray
    static let gray = "img.gray"
    // Metadata
    static let mdMode = "img.md.mode"           // keep, noGPS, strip
    static let frames = "img.frames"            // first, all, animated
    // image.pdf (merge)
    static let pdfPageSize = "imgpdf.pageSize"  // image, a4, a5, a3, letter
    static let pdfFit = "imgpdf.fit"            // contain, cover
    static let pdfMargin = "imgpdf.margin"      // millimetres
    static let pdfOrder = "imgpdf.order"        // natural, name, date, selection
    static let pdfOrientation = "imgpdf.orientation"   // auto, portrait, landscape
}
