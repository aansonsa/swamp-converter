import Foundation

// The default oracles Core ships. They are matched on what an operation DECLARES (its inputs, target format, family, wheel), never on its id, so a new
// operation is covered the moment it is registered. Engines add sharper oracles (higher priority) with ConformanceRegistry.shared.add.

enum ConformanceOracles {
    static func registerBuiltins(into registry: ConformanceRegistry) {
        registry.add(genericFallback)
        registry.add(imageConvert)
        registry.add(imageToPDF)
        registry.add(audioConvert)
        registry.add(videoConvert)
        registry.add(videoToAudio)
        for o in [pdfToImages, pdfToText, pdfToDocument, pdfMerge, pdfSplit, pdfRotate, pdfOptimize, pdfProtect, pdfUnlock,
                  imageHalf, imageMax1920, imageRotateRight, imageRotateLeft, imageFlip, imageSquare, imageGrayscale, imageStrip, imageCompress, imageMergePDF,
                  videoCompress, video720p, videoMute, videoTrim, videoRotate, videoSpeed2, videoThumbnail,
                  documentConvert, sheetConvert, subsConvert, archiveRepack, archiveExtract, packArchive,
                  smartBest, smartMax, smartUniversal, fitToSize,
                  pdfExtract, toolsOCR, slidesConvert, pdfToPptx, videoConcat] { registry.add(o) }
    }

    /// Last resort: only the generic checks (real format by the bytes, decodable, not a copy, input untouched, no partials, naming). It claims nothing
    /// beyond that: it is marked `isFallback`, so an operation it is the only match for counts as UNCOVERED in `conformance.coverage` (it still gets the
    /// generic anti-fake checks when it runs). The coverage report names every such operation.
    static let genericFallback = ConformanceOracle(
        id: "generic.format-and-integrity", priority: -100, isFallback: true, match: { !$0.isAppAction && !$0.acceptsLinks },
        cases: { meta, fx in try await ConformanceInputs.cases(for: meta, fx: fx) },
        verify: { _ in },
        proves: "right format by the bytes, decodable by an independent reader, not a copy of the input, input untouched, no partial files")
}
