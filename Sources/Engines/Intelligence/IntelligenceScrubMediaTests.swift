import Foundation
import AVFoundation
import CoreMedia

// D. Share-safe scrub for video and audio. ffmpeg builds the fixtures with known tags; a separate ffprobe run reads the result back, and a packet-level MD5 of the
// compressed streams proves that the copy changed tags only.

enum IntelligenceScrubMediaTests {
    static let ffmpegNeeds = ["tool.ffmpeg", "tool.ffprobe"]

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("intelligence", "scrub.video: location and camera tags are gone, title / author / dates stay, the streams are bit-identical", requires: ffmpegNeeds) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try makeClip(fx)
            let before = try IntelTest.sha256(src)
            let pre = try unwrap(IntelTest.probeTags(src))
            try expect(pre.format.keys.contains { $0.hasPrefix("location") } && pre.format["com.apple.quicktime.make"] != nil, "fixture lacks tags: \(pre.format)")

            let result = try await IntelTest.run("scrub.video", [src])
            let out = try unwrap(result.outputs.first)
            try expectEqual(out.lastPathComponent, "clip (clean).mp4")
            try expectEqual(try IntelTest.sha256(src), before, "the original must not change")
            try expect(try IntelTest.sha256(out) != before)
            let post = try unwrap(IntelTest.probeTags(out))
            try expect(!post.format.keys.contains { $0.hasPrefix("location") }, "location tag still present: \(post.format)")
            try expect(post.format["com.apple.quicktime.make"] == nil && post.format["com.apple.quicktime.model"] == nil, "make / model still present: \(post.format)")
            try expect((post.format["encoder"] ?? "").isEmpty, "ffmpeg version string still present: \(post.format["encoder"] ?? "")")
            try expectEqual(post.format["title"], "Holiday")
            try expectEqual(post.format["artist"], "Andris")
            try expect(post.format["creation_time"]?.hasPrefix("2024-05-01") == true, "creation time lost: \(post.format)")
            // The picture and the sound were copied, not re-encoded.
            try expectEqual(IntelTest.streamHash(out, stream: "0:v:0"), IntelTest.streamHash(src, stream: "0:v:0"))
            try expectEqual(IntelTest.streamHash(out, stream: "0:a:0"), IntelTest.streamHash(src, stream: "0:a:0"))
            try expect(IntelTest.streamHash(src, stream: "0:v:0") != nil, "hash oracle must work")
            let format = IntelTest.tool(.ffprobe, ["-v", "error", "-show_entries", "format=format_name", "-of", "csv=p=0", out.path]) ?? ""
            try expect(format.contains("mp4"), "output must be a real MP4: \(format)")
            let note = try unwrap(result.note).en
            try expect(note.lowercased().contains("location") && note.lowercased().contains("camera"), note)
            try expect(!note.lowercased().contains("title"), note)
        }

        t.register("intelligence", "scrub.video: dates, author and remove-all switches each do their own job", requires: ffmpegNeeds) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try makeClip(fx)
            let dates = try unwrap(try await IntelTest.run("scrub.video", [src], extra: [ScrubKeys.removeDates: true]).outputs.first)
            let d = try unwrap(IntelTest.probeTags(dates))
            try expect(d.format["creation_time"] == nil, "creation time still present")
            try expectEqual(d.format["artist"], "Andris", "author must stay when only dates are selected")

            let author = try unwrap(try await IntelTest.run("scrub.video", [src], extra: [ScrubKeys.removeAuthor: true]).outputs.first)
            let a = try unwrap(IntelTest.probeTags(author))
            try expect(a.format["artist"] == nil, "artist still present")
            try expectEqual(a.format["title"], "Holiday", "title is not part of the author group")
            try expect(a.format["creation_time"] != nil, "dates must stay when only the author is selected")

            // Location off: the tag stays.
            let keep = try unwrap(try await IntelTest.run("scrub.video", [src], extra: [ScrubKeys.removeGPS: false, ScrubKeys.removeCamera: false]).outputs.first)
            let k = try unwrap(IntelTest.probeTags(keep))
            try expect(k.format.keys.contains { $0.hasPrefix("location") }, "location must stay when its switch is off: \(k.format)")

            let all = try unwrap(try await IntelTest.run("scrub.video", [src], extra: [ScrubKeys.removeAll: true]).outputs.first)
            let e = try unwrap(IntelTest.probeTags(all))
            let personal = e.format.filter { MediaScrub.item(forTag: $0.key, value: $0.value) != nil }
            try expect(personal.isEmpty, "remove-all left \(personal)")
            for s in e.streams { try expect(s.filter { MediaScrub.item(forTag: $0.key, value: $0.value) != nil }.isEmpty, "stream tags left: \(s)") }
            try expectEqual(IntelTest.streamHash(all, stream: "0:v:0"), IntelTest.streamHash(src, stream: "0:v:0"))
        }

        t.register("intelligence", "scrub.audio: author tags go on request, the audio packets are bit-identical, FLAC and M4A both work", requires: ffmpegNeeds + ["ff.enc.flac"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            for ext in ["flac", "m4a"] {
                let src = fx.url("song.\(ext)")
                let codec = ext == "flac" ? "flac" : "aac"
                _ = IntelTest.tool(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=330:duration=2", "-c:a", codec,
                                              "-metadata", "title=Song", "-metadata", "artist=Andris", "-metadata", "album=Private Album", "-metadata", "comment=for me",
                                              "-metadata", "location=+50.0800+014.4200/", src.path])
                let pre = try unwrap(IntelTest.probeTags(src))
                try expect(pre.format["artist"] != nil || pre.streams.contains { $0["artist"] != nil }, "\(ext): fixture lacks the artist tag: \(pre)")
                let out = try unwrap(try await IntelTest.run("scrub.audio", [src], extra: [ScrubKeys.removeAuthor: true]).outputs.first)
                try expectEqual(out.lastPathComponent, "song (clean).\(ext)")
                let post = try unwrap(IntelTest.probeTags(out))
                let all = post.format.merging(post.streams.first ?? [:]) { a, _ in a }
                try expect(all["artist"] == nil, "\(ext): artist still present: \(all)")
                try expectEqual(all["title"], "Song", "\(ext): title must stay")
                try expect(!all.keys.contains { $0.hasPrefix("location") }, "\(ext): location still present: \(all)")
                try expectEqual(IntelTest.streamHash(out, stream: "0:a:0"), IntelTest.streamHash(src, stream: "0:a:0"), "\(ext): audio must be copied, not re-encoded")
                let dur = Double((IntelTest.tool(.ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out.path]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                try expectClose(dur, 2.0, tolerance: 0.1, "\(ext): duration")
            }
        }

        t.register("intelligence", "scrub.video: without ffmpeg AVFoundation copies the samples and removes location, make, model and software", requires: ["tool.ffprobe"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try await makeAVMovie(fx)
            let pre = await AVScrub.inspect(src).removed
            try expect(pre.contains(.gps) && pre.contains(.cameraMake), "fixture lacks tags: \(pre)")
            let item = FileItem(url: src)
            let op = try IntelTest.operation("scrub.video")
            let ctx = OperationContext.testing(op, items: [item])
            let out = fx.url("movie (clean).mov")
            let report = try await MetadataScrubber.scrub(input: item, output: out, selection: ScrubSelection(gps: true, device: true), keepColorProfile: true,
                                                          allowFFmpeg: false, ctx: ctx)
            ctx.cleanupTemp()
            try expect(report.removed.contains(.gps) && report.removed.contains(.cameraMake), "report: \(report.removed)")
            try expect(report.residual.isEmpty, "residual: \(report.residual)")
            let post = try unwrap(IntelTest.probeTags(out))
            try expect(!post.format.keys.contains { $0.contains("location") || $0.contains("iso6709") } && post.format["com.apple.quicktime.make"] == nil, "tags still present: \(post.format)")
            // Same samples: frame count and duration.
            let a = try await frameCount(src), b = try await frameCount(out)
            try expectEqual(b, a, "frame count")
            try expect(a >= 12, "source frame count \(a)")
            let playable = try await AVURLAsset(url: out).load(.isPlayable)
            try expect(playable, "the copy must play")
            // Remove-all empties the metadata list entirely.
            let bare = fx.url("movie (bare).mov")
            let r2 = try await MetadataScrubber.scrub(input: item, output: bare, selection: .all, keepColorProfile: true, allowFFmpeg: false, ctx: ctx)
            try expect(r2.residual.isEmpty, "remove-all residual: \(r2.residual)")
            let leftover = await AVScrub.inspect(bare).removed
            try expect(leftover.isEmpty, "remove-all left \(leftover)")
        }

        t.register("intelligence", "scrub: names with spaces, Cyrillic, dots and a leading dash work for pictures, video and PDF", requires: ffmpegNeeds) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let jpg = try IntelTest.richJPEG(fx, "-тест  v1.2 (копия).jpg")
            let clip = try makeClip(fx)
            let video = fx.url("-мой ролик  v2.final.mp4")
            try FileManager.default.moveItem(at: clip, to: video)
            let pdf = try IntelligenceScrubTests.makePDF(fx, name: "отчёт ..v3 .pdf", pages: 1)
            // Core's naming rule folds runs of spaces; everything else must survive untouched.
            func folded(_ s: String) -> String { s.split(separator: " ").joined(separator: " ") }
            for (id, url) in [("scrub.image", jpg), ("scrub.video", video), ("scrub.pdf", pdf)] {
                let out = try unwrap(try await IntelTest.run(id, [url]).outputs.first, id)
                try expectEqual(out.lastPathComponent, folded(url.deletingPathExtension().lastPathComponent + " (clean)." + url.pathExtension), id)
                try expect(TestFile.size(out) > 0, id)
                if id == "scrub.image" { try expect(!ImageScrub.inspect(out).removed.contains(.gps), "GPS left in \(out.lastPathComponent)") }
            }
        }

        t.register("intelligence", "scrub.video: ffmpeg arguments golden (selection -> command line)") {
            let url = URL(fileURLWithPath: "/tmp/in.mp4"), out = URL(fileURLWithPath: "/tmp/out.mp4")
            let probe = MediaScrub.Probe(
                format: [.init(key: "location", value: "+1+2/"), .init(key: "com.apple.quicktime.make", value: "Apple"), .init(key: "title", value: "T"), .init(key: "creation_time", value: "2024-05-01T10:00:00Z")],
                streams: [.init(index: 0, type: "video", codec: "h264", attachedPicture: false, tags: [.init(key: "encoder", value: "Lavc libx264"), .init(key: "language", value: "eng")]),
                          .init(index: 1, type: "audio", codec: "aac", attachedPicture: false, tags: [.init(key: "language", value: "rus")]),
                          .init(index: 2, type: "video", codec: "mjpeg", attachedPicture: true, tags: []),
                          .init(index: 3, type: "subtitle", codec: "ass", attachedPicture: false, tags: [])],
                hasChapters: true, duration: 10)
            let quick = try MediaScrub.arguments(input: url, output: out, probe: probe, selection: ScrubSelection(gps: true, device: true))
            try expect(quick.contains("location=") && quick.contains("com.apple.quicktime.make="), "\(quick)")
            try expect(!quick.contains("title=") && !quick.contains("-map_metadata"), "title must stay: \(quick)")
            try expect(quick.contains("creation_time=2024-05-01T10:00:00Z"), "dates are put back: \(quick)")
            try expect(quick.contains("-metadata:s:0") && quick.contains("encoder="), "stream encoder tag: \(quick)")
            try expect(quick.contains("0:2"), "cover art is kept without remove-all")
            try expect(!quick.contains("0:3"), "ASS subtitles cannot go into MP4: \(quick)")
            try expect(quick.contains("+bitexact") && quick.contains("-c") && quick.contains("copy"))
            let all = try MediaScrub.arguments(input: url, output: out, probe: probe, selection: .all)
            try expect(all.contains("-map_metadata") && all.contains("-map_chapters"), "\(all)")
            try expect(!all.contains("0:2"), "cover art goes with remove-all: \(all)")
            try expect(all.contains("language=rus") && all.contains("language=eng"), "language is not personal: \(all)")
            let mkv = try MediaScrub.arguments(input: url, output: URL(fileURLWithPath: "/tmp/out.mkv"), probe: probe, selection: ScrubSelection(gps: true))
            try expect(mkv.contains("0:3"), "MKV keeps subtitles of any kind")
            try expect(!mkv.contains("-movflags") && !mkv.contains("+bitexact"), "\(mkv)")
        }

        t.register("intelligence", "scrub: tag classification table") {
            let table: [(String, ScrubReport.Item?)] = [
                ("location", .gps), ("location-eng", .gps), ("com.apple.quicktime.location.ISO6709", .gps), ("©xyz", .gps), ("GPSLatitude", .gps),
                ("com.apple.quicktime.make", .cameraMake), ("com.apple.quicktime.model", .cameraModel), ("com.apple.quicktime.software", .software),
                ("creation_time", .creationTime), ("com.apple.quicktime.creationdate", .creationTime), ("ARTIST", .author), ("copyright", .author),
                ("title", .title), ("comment", .comment), ("DESCRIPTION", .comment), ("major_brand", nil), ("handler_name", nil), ("language", nil),
                ("com.apple.quicktime.camera.identifier", .serialNumber), ("somethingelse", .other)
            ]
            for (key, item) in table { try expectEqual(MediaScrub.item(forTag: key), item, key) }
            try expectEqual(MediaScrub.item(forTag: "encoder", value: "Lavf"), nil)
            try expectEqual(MediaScrub.item(forTag: "encoder", value: "Lavf61.7.100"), .encoder)
            // Selection semantics.
            let quick = ScrubSelection(gps: true, device: true)
            try expect(quick.selects(.gps) && quick.selects(.cameraModel) && quick.selects(.thumbnail) && !quick.selects(.creationTime) && !quick.selects(.author) && !quick.selects(.title))
            try expect(ScrubSelection.all.selects(.title) && ScrubSelection.all.selects(.xmp))
        }
    }

    // MARK: Fixtures

    static func makeClip(_ fx: TestFixtures) throws -> URL {
        let url = fx.url("clip.mp4")
        let codec = Capabilities.shared.has("ff.enc.libx264") ? "libx264" : "mpeg4"
        _ = IntelTest.tool(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=2:size=160x120:rate=10", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                                      "-c:v", codec, "-c:a", "aac", "-shortest", "-metadata", "location=+50.0800+014.4200/", "-metadata", "title=Holiday", "-metadata", "artist=Andris",
                                      "-metadata", "comment=private", "-metadata", "com.apple.quicktime.make=Apple", "-metadata", "com.apple.quicktime.model=iPhone 15",
                                      "-metadata", "creation_time=2024-05-01T10:00:00Z", "-movflags", "+use_metadata_tags+faststart", url.path], timeout: 120)
        try expect(TestFile.exists(url), "ffmpeg could not make the fixture")
        return url
    }

    /// A QuickTime movie of 12 frames with location, make, model, software and creation date written by AVAssetWriter.
    static func makeAVMovie(_ fx: TestFixtures) async throws -> URL {
        let url = fx.url("movie.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        func item(_ id: AVMetadataIdentifier, _ value: String, type: String = kCMMetadataBaseDataType_UTF8 as String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id; m.value = value as NSString; m.dataType = type
            return m
        }
        writer.metadata = [item(.quickTimeMetadataLocationISO6709, "+50.0800+014.4200/", type: kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String),
                           item(.quickTimeMetadataMake, "Apple"), item(.quickTimeMetadataModel, "iPhone 15"), item(.quickTimeMetadataSoftware, "17.4"),
                           item(.quickTimeMetadataCreationDate, "2024-05-01T10:00:00+0000")]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                                                                  kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TestFailure(message: "writer failed", file: #fileID, line: #line) }
        writer.startSession(atSourceTime: .zero)
        let finished = IntelSignal()
        nonisolated(unsafe) let pool = try unwrap(adaptor.pixelBufferPool)
        nonisolated(unsafe) let writerInput = input
        nonisolated(unsafe) let pixelAdaptor = adaptor
        let next = Locked(0)
        writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "swamp.test.movie")) {
            while writerInput.isReadyForMoreMediaData {
                let f = next.withLock { n -> Int in defer { n += 1 }; return n }
                if f >= 12 { finished.fire(); return }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let buf = pb else { finished.fire(); return }
                CVPixelBufferLockBaseAddress(buf, [])
                if let base = CVPixelBufferGetBaseAddress(buf) { memset(base, Int32(20 + f * 15), CVPixelBufferGetBytesPerRow(buf) * 48) }
                CVPixelBufferUnlockBaseAddress(buf, [])
                pixelAdaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 12))
            }
        }
        _ = await finished.wait(timeout: 30)
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? TestFailure(message: "writer did not complete", file: #fileID, line: #line) }
        return url
    }

    static func frameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var n = 0
        while output.copyNextSampleBuffer() != nil { n += 1 }
        return n
    }
}
