import Foundation
import CoreGraphics
import ImageIO

/// Independent readers for the PDF conformance tests. Nothing here shares code with the writers (PDFKit, Core Graphics contexts, Vision): bytes are read
/// directly, structure through the low-level `CGPDFDocument` API and, when installed, through Poppler (`pdfinfo`, `pdftotext`, `pdfimages`), which is a
/// different PDF implementation altogether.
enum PdfOracle {
    // MARK: Bytes

    /// Real format from the first bytes: "pdf", "png", "jpeg", "tiff", "heic", "zip", "utf8" (valid UTF-8 text without control bytes) or "bin".
    static func sniff(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "missing" }
        defer { try? h.close() }
        let b = [UInt8]((try? h.read(upToCount: 4096)) ?? Data())
        func starts(_ s: [UInt8]) -> Bool { b.count >= s.count && Array(b.prefix(s.count)) == s }
        if starts(Array("%PDF-".utf8)) { return "pdf" }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if b.count > 12, Array(b[4..<8]) == Array("ftyp".utf8) { return "heic" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        if !b.isEmpty, String(data: Data(b), encoding: .utf8) != nil, !b.contains(where: { $0 < 9 }) { return "utf8" }
        return "bin"
    }

    /// `file --mime-type -b` (ships with macOS).
    static func mime(_ url: URL) -> String {
        run("/usr/bin/file", ["--mime-type", "-b", url.path]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func identical(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? Data(contentsOf: a), let y = try? Data(contentsOf: b) else { return false }
        return x == y
    }

    // MARK: Processes

    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 60) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let outData = Locked<Data>(Data()), errData = Locked<Data>(Data())
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData.value = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData.value = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        group.wait()
        return (p.terminationStatus, String(decoding: outData.value, as: UTF8.self), String(decoding: errData.value, as: UTF8.self))
    }

    /// Poppler tool by name (Homebrew or PATH), nil when it is not installed.
    static func poppler(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static var hasPoppler: Bool { poppler("pdfinfo") != nil && poppler("pdftotext") != nil }

    // MARK: Structure (Core Graphics, low level)

    struct Facts {
        var pages: Int
        var encrypted: Bool
        var unlocked: Bool
        var rotations: [Int]
        var sizes: [CGSize]          // media box as stored (rotation not applied)
    }

    /// Page count, encryption and per-page /Rotate and media box straight from the object model.
    static func facts(_ url: URL, password: String? = nil) -> Facts? {
        guard let doc = CGPDFDocument(url as CFURL) else { return nil }
        if doc.isEncrypted, !doc.isUnlocked, let password { _ = doc.unlockWithPassword(password) }
        var out = Facts(pages: 0, encrypted: doc.isEncrypted, unlocked: doc.isUnlocked, rotations: [], sizes: [])
        guard doc.isUnlocked else { return out }
        out.pages = doc.numberOfPages
        for n in 1...max(doc.numberOfPages, 1) {
            guard let page = doc.page(at: n) else { continue }
            out.rotations.append((Int(page.rotationAngle) % 360 + 360) % 360)
            out.sizes.append(page.getBoxRect(.mediaBox).size)
        }
        return out
    }

    /// One page drawn by Core Graphics' PDF interpreter at `pixels` wide (height follows the displayed aspect), on white. Independent of PDFKit's page drawing.
    static func render(_ url: URL, page n: Int = 1, width pixels: Int) -> CGImage? {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: n) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let turned = Int(page.rotationAngle) % 180 != 0
        let shown = turned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = CGFloat(pixels) / shown.width
        let w = pixels, h = max(1, Int((shown.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: shown), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    // MARK: Poppler

    struct PopplerInfo { var pages = 0; var encrypted = false; var pageSize = ""; var rotation = 0; var raw = "" }

    static func pdfinfo(_ url: URL, password: String? = nil) -> PopplerInfo? {
        guard let tool = poppler("pdfinfo") else { return nil }
        var args: [String] = []
        if let password { args += ["-upw", password] }
        let r = run(tool, args + [url.path])
        guard r.status == 0 else { return nil }
        var info = PopplerInfo(raw: r.out)
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Pages": info.pages = Int(parts[1]) ?? 0
            case "Encrypted": info.encrypted = parts[1].hasPrefix("yes")
            case "Page size": info.pageSize = parts[1]
            case "Page rot": info.rotation = Int(parts[1]) ?? 0
            default: break
            }
        }
        return info
    }

    /// Text of one page (1-based) or of all pages when `page` is nil; nil when the file cannot be read (wrong password, damaged).
    static func pdftotext(_ url: URL, page: Int? = nil, password: String? = nil) -> String? {
        guard let tool = poppler("pdftotext") else { return nil }
        var args = ["-enc", "UTF-8"]
        if let page { args += ["-f", String(page), "-l", String(page)] }
        if let password { args += ["-upw", password] }
        let r = run(tool, args + [url.path, "-"])
        return r.status == 0 ? r.out : nil
    }

    /// The pictures in a PDF in file order, from `pdfimages -list`: encoder ("jpeg", "image" for Flate, "ccitt", ...), pixel size and bytes per picture.
    static func images(_ url: URL) -> [(encoding: String, width: Int, height: Int)]? {
        guard let tool = poppler("pdfimages") else { return nil }
        let r = run(tool, ["-list", url.path])
        guard r.status == 0 else { return nil }
        return r.out.split(separator: "\n").dropFirst(2).compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count > 8, let w = Int(cols[3]), let h = Int(cols[4]) else { return nil }
            return (String(cols[8]), w, h)
        }
    }

    static func imageEncodings(_ url: URL) -> [String]? { images(url)?.map(\.encoding) }

    /// Words (letters and digits, case folded) of a text, for comparing extractions that differ in line breaks and spacing.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}
