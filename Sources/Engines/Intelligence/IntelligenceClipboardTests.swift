import Foundation
import AppKit
import ImageIO

// E. Clipboard source, always against a private NSPasteboard(name:) so the person's real clipboard is never read or changed.

enum IntelligenceClipboardTests {
    static func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("swamp.selftest.\(UUID().uuidString)"))
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("intelligence", "clipboard: files first, then a picture saved as PNG, then links, then empty") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let folder = try fx.makeDirectory("incoming")
            let pb = privatePasteboard()
            defer { pb.releaseGlobally() }

            // Empty.
            pb.clearContents()
            guard case .empty = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "empty pasteboard should read as .empty", file: #fileID, line: #line) }
            try expect(ClipboardContent.empty.hint != nil && ClipboardContent.denied.hint != nil)

            // Files: existing ones only, even when a picture and a link are present too.
            let a = try fx.png("a.png"), b = try fx.text("b.txt", "hello")
                        pb.clearContents()
            pb.writeObjects([a as NSURL, b as NSURL, fx.url("gone.txt") as NSURL])
            pb.setString("https://example.com/video", forType: .string)
            guard case .files(let files) = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "expected files", file: #fileID, line: #line) }
            try expectEqual(files.map(\.name).sorted(), ["a.png", "b.txt"])
            try expectEqual(files.first { $0.name == "a.png" }?.kind, .image)

            // A picture (TIFF + PNG like a screenshot): saved once as a real PNG in the incoming folder, same file for the same clipboard, no litter.
            let image = fx.cgImage(width: 120, height: 80, pattern: .quadrants)
            let png = NSMutableData()
            let dest = try unwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
                        pb.clearContents()
            pb.setData(png as Data, forType: .png)
            pb.setString("see https://example.com/x", forType: .string)
            guard case .image(let first) = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "expected an image", file: #fileID, line: #line) }
            try expectEqual(first.url.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path)
            try expectEqual(first.url.pathExtension, "png")
            try expect(first.name.hasPrefix("Screenshot") || first.name.hasPrefix("Снимок экрана"), first.name)
            try expectEqual(TestFile.magic(first.url, 4), [0x89, 0x50, 0x4E, 0x47])
            try expectEqual(TestImage.size(of: first.url)?.width, 120)
            try expect(TestImage.close(TestImage.pixel(of: first.url, x: 3, y: 3), .red) && TestImage.close(TestImage.pixel(of: first.url, x: 116, y: 76), .yellow), "pixels must be the clipboard's")
            guard case .image(let second) = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "expected an image again", file: #fileID, line: #line) }
            try expectEqual(second.url, first.url, "reading the same clipboard twice must not save a second file")
            try expectEqual(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count, 1)

            // TIFF only (what some apps copy): converted to a PNG with the same pixels.
            let tiff = try unwrap(NSBitmapImageRep(cgImage: image).representation(using: .tiff, properties: [:]))
            pb.clearContents(); pb.setData(tiff, forType: .tiff)
            guard case .image(let fromTIFF) = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "expected an image from TIFF", file: #fileID, line: #line) }
            try expectEqual(TestFile.magic(fromTIFF.url, 4), [0x89, 0x50, 0x4E, 0x47], "TIFF must be converted to PNG")
            try expect(fromTIFF.url != first.url)
            try expect(TestImage.close(TestImage.pixel(of: fromTIFF.url, x: 3, y: 76), .blue))

            // Discarding removes only what this type created.
            let removed = ClipboardSource.discard(fromTIFF)
            try expect(removed && !TestFile.exists(fromTIFF.url))
            let twice = ClipboardSource.discard(fromTIFF)
            try expect(!twice && !TestFile.exists(fromTIFF.url), "a second discard of the same screenshot (the wheel can report a close twice) does nothing and does not fail")
            guard case .image(let reread) = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "expected the clipboard picture again after its copy was discarded", file: #fileID, line: #line) }
            try expect(TestFile.exists(reread.url), "a discarded copy is not served again from the cache: the clipboard is saved afresh")
            _ = ClipboardSource.discard(reread)
            let keep = ClipboardSource.discard(FileItem(url: a))
            try expect(!keep && TestFile.exists(a), "a file the clipboard code did not create must never be deleted")

            // Links: trimmed, validated, tracking removed from identity, duplicates folded, hostile schemes refused.
                        pb.clearContents()
            pb.setString("Watch https://youtu.be/dQw4w9WgXcQ, or https://www.youtube.com/watch?v=dQw4w9WgXcQ&utm_source=x. Also javascript:alert(1) and file:///etc/passwd", forType: .string)
            guard case .links(let links) = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "expected links", file: #fileID, line: #line) }
            try expectEqual(links.count, 1, "youtu.be and youtube.com/watch are the same video: \(links.map(\.url))")
            try expect(links[0].url.absoluteString.hasPrefix("https://"), links[0].url.absoluteString)
            pb.clearContents(); pb.setString("javascript:alert(1) file:///etc/passwd http://localhost:8080/x", forType: .string)
            guard case .empty = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "hostile or private links must not become links", file: #fileID, line: #line) }
            // A copied web address (URL type) also counts.
            pb.clearContents(); pb.writeObjects([URL(string: "https://example.org/video/1")! as NSURL])
            guard case .links(let direct) = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "expected a link from a URL item", file: #fileID, line: #line) }
            try expectEqual(direct.first?.url.host, "example.org")
        }

        t.register("intelligence", "clipboard.put: results go back as file URLs plus the picture's own bytes (Paste as file)") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let pb = privatePasteboard()
            defer { pb.releaseGlobally() }
            let png = try fx.png("result.png", width: 30, height: 20), pdf = try fx.pdf("doc.pdf", pages: 1)
            let ok = ClipboardSource.put(results: [png, pdf, fx.url("missing.png")], pasteboard: pb)
            try expect(ok)
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            try expectEqual(urls.map(\.lastPathComponent), ["result.png", "doc.pdf"], "missing files are left out")
            let items = pb.pasteboardItems ?? []
            let bytes = items.first?.data(forType: .png)
            try expectEqual(bytes, try Data(contentsOf: png), "the picture travels byte for byte")
            let pdfBytes = items.last?.data(forType: .png)
            try expect(pdfBytes == nil, "only pictures carry data")
            let none = ClipboardSource.put(results: [fx.url("nothing.png")], pasteboard: pb)
            try expect(!none, "nothing to put")
            // What the person pastes round-trips through the reader.
            _ = ClipboardSource.put(results: [png], pasteboard: pb)
            let folder = try fx.makeDirectory("in2")
            guard case .files(let back) = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "expected files back", file: #fileID, line: #line) }
            try expectEqual(back.map(\.name), ["result.png"])
        }

        t.register("intelligence", "clipboard.wheel: a clipboard picture is offered convert, compress, cut out and Save as") {
            let reg = OperationRegistry()
            let png = FileItem(url: URL(fileURLWithPath: "/tmp/Screenshot.png"), isDirectory: false)
            // With only this module's operations registered, the cut-out is the one id that must be there; the rest depends on the other modules.
            reg.register(IntelligenceCatalog.operations())
            let ids = ClipboardSource.wheelOperationIDs(for: png, registry: reg)
            try expect(ids.contains("image.removebg"), "\(ids)")
            let full = OperationRegistry.shared
            if full.operation(id: "image.to.jpg") != nil {
                let all = ClipboardSource.wheelOperationIDs(for: png, registry: full)
                try expect(all.contains("image.to.jpg") && !all.contains("image.to.png"), "a PNG is not offered PNG: \(all)")
                try expect(all.first?.hasPrefix("image.to.") == true, "convert comes first: \(all)")
            }
        }
    }
}
