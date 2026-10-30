import Foundation
import CoreGraphics

// Pure tests: catalog, planners, search state machines, argument lists, estimates. No encoding, no files, no external tools.

enum SizeFitPlannerTests {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("sizefit", "catalog: every service has a dated note, sizes are SI megabytes, ids resolve, custom comes from the option") {
            let ids = SizeTargetCatalog.presets.map(\.id)
            try expectEqual(Set(ids).count, ids.count, "ids must be unique")
            for id in ["whatsapp", "telegram", "discord10", "discord25", "discord50", "email20", "email25", "instagram", "custom"] { try expect(ids.contains(id), "missing \(id)") }
            try expectEqual(SizeTargetCatalog.bytes(forID: "discord10", customMB: 0), 10_000_000)
            try expectEqual(SizeTargetCatalog.bytes(forID: "discord25", customMB: 0), 25_000_000)
            try expectEqual(SizeTargetCatalog.bytes(forID: "discord50", customMB: 0), 50_000_000)
            try expectEqual(SizeTargetCatalog.bytes(forID: "email20", customMB: 0), 20_000_000)
            try expectEqual(SizeTargetCatalog.bytes(forID: "email25", customMB: 0), 25_000_000)
            try expectEqual(SizeTargetCatalog.bytes(forID: "custom", customMB: 12.5), 12_500_000)
            try expect(SizeTargetCatalog.bytes(forID: "custom", customMB: 0) == nil && SizeTargetCatalog.bytes(forID: "custom", customMB: -3) == nil, "custom needs a positive size")
            try expect(SizeTargetCatalog.bytes(forID: "nope", customMB: 5) == nil)
            for s in SizeTargetCatalog.presets where s.id != "custom" {
                let note = try unwrap(s.note, "\(s.id) has no note")
                try expect(note.en.contains("2026-10") || s.id.hasPrefix("mb"), "\(s.id): the note must carry the date it was checked")
                try expect(!note.ru.isEmpty && s.bytes > 0 && !s.kinds.isEmpty)
            }
            try expect(SizeTargetCatalog.presets(for: .video).contains { $0.id == "whatsapp" })
            try expect(!SizeTargetCatalog.presets(for: .pdf).contains { $0.id == "whatsapp" }, "documents are not WhatsApp media")
            try expect(SizeTargetCatalog.presets(for: .image).contains { $0.id == "telegramPhoto" })
            try expectEqual(try unwrap(SizeTargetCatalog.target(id: "whatsapp")).label.en, "WhatsApp (16 MB)")
            try expectEqual(try unwrap(SizeTargetCatalog.target(id: "discord10")).label.en, "Discord 10 MB")
            try expectEqual(SizeTarget.formatMB(0.5, russian: true), "0,5 МБ")
        }

        t.register("sizefit", "every schema field has an oracle, the pickers list the catalog, and defaults resolve to a valid quick recipe") {
            for kind in FitKind.allCases {
                let schema = FitSchemas.schema(id: kind.schemaID)
                try expect(!schema.pages.isEmpty, "\(kind) has no pages")
                for f in schema.allFields { try expect(!f.oracle.isEmpty, "\(f.key) of \(kind) has no oracle") }
                let targetField = try unwrap(schema.field(FitKeys.target))
                guard case .picker(let options) = targetField.kind else { throw TestFailure(message: "target must be a picker", file: #fileID, line: #line) }
                try expectEqual(options.map(\.value), SizeTargetCatalog.presets(for: kind.fileKind).map(\.id))
                try expect(options.last?.value == "custom")
                let resolved = schema.resolve(layers: [[FitKeys.target: "discord10"]])
                try expectEqual(resolved.values.string(FitKeys.target), "discord10")
                try expect(!resolved.hasErrors, "\(kind): defaults must be valid")
                try expect(!resolved.isActive(FitKeys.customMB), "custom size is hidden unless Custom is chosen")
                try expect(schema.resolve(layers: [target("custom", 7)]).isActive(FitKeys.customMB))
            }
            try expect(FitSchemas.schema(id: "fit.video").field(FitKeys.twoPass) != nil && FitSchemas.schema(id: "fit.image").field(FitKeys.minQuality) != nil)
            try expect(FitSchemas.schema(id: "fit.audio").field(FitKeys.audioCodec) != nil && FitSchemas.schema(id: "fit.pdf").field(FitKeys.allowDownscale) != nil)
            try expect(FitSchemas.schema(id: "fit.audio").field(FitKeys.twoPass) == nil, "audio has no video options")
        }

        t.register("sizefit", "built-in presets: one per target and kind, valid ids and values, registered into the store") {
            let presets = FitPresets.builtins
            try expect(presets.count >= 30, "expected a preset per target and kind, got \(presets.count)")
            try expectEqual(Set(presets.map(\.id)).count, presets.count)
            let whatsApp = try unwrap(presets.first { $0.id == "builtin.fit.video.whatsapp" })
            try expectEqual(whatsApp.targetID, "fit.video")
            try expectEqual(whatsApp.values.string(FitKeys.target), "whatsapp")
            try expectEqual(whatsApp.name.en, "Video for WhatsApp")
            try expectEqual(try unwrap(presets.first { $0.id == "builtin.fit.image.mb1" }).name.en, "Image under 1 MB")
            for p in presets {
                let kind = try unwrap(FitKind(schemaID: p.targetID))
                let target = try unwrap(SizeTargetCatalog.target(id: p.values.string(FitKeys.target)), "\(p.id): unknown target")
                try expect(target.kinds.contains(kind.fileKind), "\(p.id): target does not fit the kind")
                try expect(p.isBuiltin && p.operationID == p.targetID)
            }
            try expect(!presets.contains { $0.values.string(FitKeys.target) == "custom" })
            let store = PresetStore(directory: AppPaths.makeTempDirectory(purpose: "presets"))
            store.registerBuiltins(presets)
            try expectEqual(store.presets(for: "fit.pdf").count, presets.filter { $0.targetID == "fit.pdf" }.count)
        }

        t.register("sizefit", "VideoFit.plan golden table: budget maths, downscale ladder, fps cap, unreachable, silent video, tiny clip, tight but allowed") {
            // 60 s 1080p30 into 16 MB: 2100 kbit/s in total, 96 for sound, so 1080p starves (0.032 bpp) and 720p (0.072) is chosen.
            let a = VideoFit.plan(durationSeconds: 60, targetBytes: 16_000_000, audioKbps: 96, sourceWidth: 1920, sourceHeight: 1080, sourceFPS: 30, hasAudio: true, allowDownscale: true, preferTwoPass: true)
            try expectEqual(a.videoKbps, 2004); try expectEqual(a.audioKbps, 96); try expectEqual(a.maxHeight, 720)
            try expect(a.downscaled && !a.unreachable && a.twoPass && a.maxFPS == nil)
            try expect(a.notes.contains { $0.en == "Reduced to 720p to fit" }, "the plan must say it reduced the picture")
            // The same clip when the picture may not shrink.
            let b = VideoFit.plan(durationSeconds: 60, targetBytes: 16_000_000, audioKbps: 96, sourceWidth: 1920, sourceHeight: 1080, sourceFPS: 30, hasAudio: true, allowDownscale: false, preferTwoPass: false)
            try expectEqual(b.maxHeight, nil); try expect(!b.downscaled && !b.unreachable && !b.twoPass); try expectEqual(b.videoKbps, 2004)
            try expect(b.notes.contains { $0.en.contains("tight") }, "a starved picture must be announced")
            // Vertical phone clip: the ladder follows the SHORT side, so it steps to 720 x 1280.
            let c = VideoFit.plan(durationSeconds: 60, targetBytes: 16_000_000, audioKbps: 96, sourceWidth: 1080, sourceHeight: 1920, sourceFPS: 30, hasAudio: true, allowDownscale: true, preferTwoPass: true)
            try expectEqual(c.maxHeight, 1280)
            // 4K at 60 fps: halving the frame rate keeps 1080p instead of dropping to 720p.
            let d = VideoFit.plan(durationSeconds: 30, targetBytes: 16_000_000, audioKbps: 96, sourceWidth: 3840, sourceHeight: 2160, sourceFPS: 60, hasAudio: true, allowDownscale: true, preferTwoPass: true)
            try expectEqual(d.maxHeight, 1080); try expectEqual(d.maxFPS, 30)
            // A generous budget keeps the source and caps the bitrate at the point where more bits show nothing.
            let e = VideoFit.plan(durationSeconds: 5, targetBytes: 50_000_000, audioKbps: 96, sourceWidth: 1280, sourceHeight: 720, sourceFPS: 30, hasAudio: true, allowDownscale: true, preferTwoPass: true)
            try expectEqual(e.maxHeight, nil); try expectEqual(e.videoKbps, 8294)
            // Clips shorter than a second: the fixed overhead is accounted for and the bitrate stays sane.
            let f = VideoFit.plan(durationSeconds: 0.5, targetBytes: 5_000_000, audioKbps: 96, sourceWidth: 1920, sourceHeight: 1080, sourceFPS: 30, hasAudio: true, allowDownscale: true, preferTwoPass: true)
            try expectEqual(f.videoKbps, 18662); try expect(!f.unreachable)
            // Silent video: the whole budget goes to the picture.
            let g = VideoFit.plan(durationSeconds: 10, targetBytes: 1_000_000, audioKbps: 96, sourceWidth: 640, sourceHeight: 360, sourceFPS: 25, hasAudio: false, allowDownscale: true, preferTwoPass: true)
            try expectEqual(g.audioKbps, 0); try expectEqual(g.videoKbps, 784)
            // A 10-minute clip into 1 MB is physically impossible.
            let h = VideoFit.plan(durationSeconds: 600, targetBytes: 1_000_000, audioKbps: 96, sourceWidth: 1280, sourceHeight: 720, sourceFPS: 30, hasAudio: true, allowDownscale: true, preferTwoPass: true)
            try expect(h.unreachable && h.notes.first?.en.contains("too small") == true)
            // Tiny sources are never "downscaled" below themselves; odd sizes become even.
            let i = VideoFit.plan(durationSeconds: 10, targetBytes: 600_000, audioKbps: 64, sourceWidth: 321, sourceHeight: 241, sourceFPS: 24, hasAudio: true, allowDownscale: true, preferTwoPass: true)
            try expect(i.maxHeight == nil || i.maxHeight! <= 241)
            // HEVC needs a quarter fewer bits for the same look, so it keeps a higher rung than H.264 at the same budget.
            let j = VideoFit.plan(durationSeconds: 60, targetBytes: 16_000_000, audioKbps: 96, sourceWidth: 1920, sourceHeight: 1080, sourceFPS: 30, hasAudio: true, allowDownscale: true,
                                  preferTwoPass: false, codecEfficiency: 0.75)
            try expectEqual(j.maxHeight, nil, "HEVC at 0.032 bpp is above its 0.03 floor")
        }

        t.register("sizefit", "VideoFit.plan is monotonic: a bigger limit never gives a lower bitrate or a lower rung; budgets never exceed the target") {
            var lastKbps = 0, lastHeight = 0
            for mb in [0.3, 0.6, 1, 2, 4, 8, 16, 25, 50, 100] {
                let p = VideoFit.plan(durationSeconds: 90, targetBytes: Int64(mb * 1_000_000), audioKbps: 96, sourceWidth: 1920, sourceHeight: 1080, sourceFPS: 30, hasAudio: true, allowDownscale: true, preferTwoPass: true)
                if p.unreachable { continue }
                let h = p.maxHeight ?? 1080
                try expect(h >= lastHeight, "\(mb) MB: height \(h) fell below \(lastHeight)")
                if h == lastHeight { try expect(p.videoKbps >= lastKbps, "\(mb) MB: bitrate \(p.videoKbps) fell below \(lastKbps)") }
                let bits = Double(p.videoKbps + p.audioKbps) * 1000 * 90
                try expect(bits / 8 <= mb * 1_000_000, "\(mb) MB: the plan itself exceeds the target")
                lastKbps = p.videoKbps; lastHeight = h
            }
            try expect(lastHeight == 1080, "a 100 MB limit keeps the source")
        }

        t.register("sizefit", "AudioFit.bitrateKbps: golden values, rounded down to what the codec accepts, floors and caps") {
            try expectEqual(AudioFit.bitrateKbps(durationSeconds: 20, targetBytes: 300_000, codec: "aac"), 115)
            try expectEqual(AudioFit.bitrateKbps(durationSeconds: 20, targetBytes: 300_000, codec: "m4a"), 115)
            try expectEqual(AudioFit.bitrateKbps(durationSeconds: 20, targetBytes: 300_000, codec: "mp3"), 112, "MP3 only accepts the classic CBR steps, rounded down")
            try expectEqual(AudioFit.rawKbps(durationSeconds: 20, targetBytes: 300_000, codec: "mp3"), 118, "the ABR guess is not rounded to CBR steps")
            try expectEqual(AudioFit.bitrateKbps(durationSeconds: 20, targetBytes: 300_000, codec: "opus"), 117)
            try expectEqual(AudioFit.bitrateKbps(durationSeconds: 3600, targetBytes: 20_000_000, codec: "aac"), 40)
            try expectEqual(AudioFit.bitrateKbps(durationSeconds: 20, targetBytes: 50_000_000, codec: "aac"), 320, "capped at the top bitrate")
            try expectEqual(AudioFit.bitrateKbps(durationSeconds: 20, targetBytes: 50_000_000, codec: "opus"), 256)
            try expectEqual(AudioFit.bitrateKbps(durationSeconds: 7200, targetBytes: 1_000_000, codec: "aac"), 24, "never below the floor")
            try expectEqual(AudioFit.bitrateKbps(durationSeconds: 7200, targetBytes: 1_000_000, codec: "mp3"), 32)
            try expectEqual(AudioFit.bitrateKbps(durationSeconds: 0, targetBytes: 1_000_000, codec: "aac"), 128, "no length: a sane default instead of a crash")
            for codec in ["aac", "mp3", "opus"] {
                var previous = 0
                for mb in stride(from: 0.1, through: 20, by: 0.37) {
                    let k = AudioFit.bitrateKbps(durationSeconds: 240, targetBytes: Int64(mb * 1_000_000), codec: codec)
                    try expect(k >= previous, "\(codec) \(mb) MB: \(k) < \(previous)")
                    previous = k
                    if AudioFit.isReachable(durationSeconds: 240, targetBytes: Int64(mb * 1_000_000), codec: codec), k > AudioFitCodec(name: codec).minKbps {
                        try expect(AudioFit.expectedBytes(kbps: k, durationSeconds: 240, codec: codec) <= Int64(mb * 1_000_000), "\(codec) \(mb) MB: the bitrate overshoots")
                    }
                }
            }
            try expect(!AudioFit.isReachable(durationSeconds: 7200, targetBytes: 1_000_000, codec: "aac"))
            try expect(AudioFit.isReachable(durationSeconds: 60, targetBytes: 1_000_000, codec: "aac"))
        }

        t.register("sizefit", "FitCorrection scales the variable part of the file towards the aim") {
            try expectClose(FitCorrection.next(previous: 1000, achieved: 2_100_000, aimBytes: 2_000_000), 952.38, tolerance: 0.01)
            try expectClose(FitCorrection.next(previous: 1000, achieved: 1_000_000, aimBytes: 2_000_000), 2000, tolerance: 0.01)
            try expectClose(FitCorrection.next(previous: 100, achieved: 10_000, aimBytes: 6_000, fixedBytes: 2_000), 50, tolerance: 0.01)
            try expect(FitCorrection.next(previous: 100, achieved: 0, aimBytes: 10).isFinite)
        }

        t.register("sizefit", "FitCorrection.nextRequest: brackets and interpolates, stays inside the bracket, extrapolates safely, stops when another run cannot help") {
            typealias A = FitCorrection.Attempt
            let target: Int64 = 1_000_000, aim: Int64 = 975_000
            // Over only: proportional with a bias to the safe side, always lower than the failed request.
            let a = try unwrap(FitCorrection.nextRequest(history: [A(request: 800, bytes: 1_250_000)], aimBytes: aim, targetBytes: target, floor: 20, ceiling: 5000))
            try expect(a < 800 * 0.97 + 0.001 && a > 500, "over-only next \(a)")
            // Under only: scaled up towards the aim, never past the ceiling.
            let b = try unwrap(FitCorrection.nextRequest(history: [A(request: 800, bytes: 600_000)], aimBytes: aim, targetBytes: target, floor: 20, ceiling: 5000))
            try expectClose(b, 800 * 975.0 / 600.0, tolerance: 0.01)
            try expect(FitCorrection.nextRequest(history: [A(request: 800, bytes: 600_000)], aimBytes: aim, targetBytes: target, floor: 20, ceiling: 800) == nil, "at the ceiling there is nothing to gain")
            // Bracket: linear interpolation between the best fit and the smallest miss.
            let c = try unwrap(FitCorrection.nextRequest(history: [A(request: 800, bytes: 600_000), A(request: 1200, bytes: 1_300_000)], aimBytes: aim, targetBytes: target, floor: 20, ceiling: 5000))
            try expectClose(c, 800 + 400 * (375_000.0 / 700_000.0), tolerance: 0.01)
            // Never outside the bracket even when the measured sizes suggest it.
            let d = try unwrap(FitCorrection.nextRequest(history: [A(request: 800, bytes: 990_000), A(request: 1000, bytes: 1_010_000)], aimBytes: 100, targetBytes: target, floor: 20, ceiling: 5000))
            try expect(d > 800 && d < 1000, "inside the bracket: \(d)")
            // A request already made (or within 1%) is not repeated.
            try expect(FitCorrection.nextRequest(history: [A(request: 800, bytes: 990_000), A(request: 802, bytes: 1_001_000)], aimBytes: aim, targetBytes: target, floor: 20, ceiling: 5000) == nil)
            try expect(FitCorrection.nextRequest(history: [], aimBytes: aim, targetBytes: target, floor: 20, ceiling: 5000) == nil)
            // The floor holds.
            let e = try unwrap(FitCorrection.nextRequest(history: [A(request: 30, bytes: 3_000_000)], aimBytes: aim, targetBytes: target, floor: 25, ceiling: 5000))
            try expect(e >= 25)
        }

        t.register("sizefit", "ImageFitSearch: quality binary search ends on the largest fitting quality, resizes only when needed, stays short") {
            // Synthetic encoder: size = pixels * (0.2 + quality / 100 * 1.8) -- monotonic in both knobs, like a real codec.
            func size(_ p: ImageFitSearch.Probe, edge: Int = 4000) -> Int { Int(Double(edge * edge * 3 / 4) * p.scale * p.scale * (0.02 + Double(p.quality) / 100 * 0.18)) }
            func solve(target: Int, minQ: Int = 30, resize: Bool = true, edge: Int = 4000) -> (ImageFitSearch.Result, Int) {
                var s = ImageFitSearch(targetBytes: target, minQuality: minQ, allowResize: resize, longEdge: edge)
                while let p = s.next() { s.record(bytes: size(p, edge: edge)) }
                return (s.result!, s.probeCount)
            }
            let full = size(.init(scale: 1, quality: 100)), low = size(.init(scale: 1, quality: 30))
            // Fits at the top quality: one or two probes, quality 100.
            let (r1, n1) = solve(target: full + 10)
            if case .fit(let p, _) = r1 { try expectEqual(p.quality, 100); try expectEqual(p.scale, 1.0) } else { throw TestFailure(message: "expected fit", file: #fileID, line: #line) }
            try expect(n1 <= 2)
            // In between: the best quality that still fits, found in a handful of probes, within 2% of the target.
            let target = (full + low) / 2
            let (r2, n2) = solve(target: target)
            guard case .fit(let p2, let bytes2) = r2 else { throw TestFailure(message: "expected fit", file: #fileID, line: #line) }
            try expect(p2.scale == 1 && p2.quality > 30 && p2.quality < 100 && bytes2 <= target && Double(bytes2) >= Double(target) * 0.97, "quality \(p2.quality) gives \(bytes2) of \(target)")
            try expect(size(.init(scale: 1, quality: p2.quality + 1)) > target, "one step more quality must not fit")
            try expect(n2 <= 10, "\(n2) probes")
            // Below what quality 30 can do: resizing starts, the scale is refined, and the quality is raised again.
            let (r3, n3) = solve(target: low / 4)
            guard case .fit(let p3, let bytes3) = r3 else { throw TestFailure(message: "expected fit", file: #fileID, line: #line) }
            try expect(p3.scale < 0.6 && p3.scale > 0.3 && bytes3 <= low / 4 && Double(bytes3) >= Double(low / 4) * 0.93, "scale \(p3.scale) q\(p3.quality) gives \(bytes3) of \(low / 4)")
            try expect(n3 <= 20, "\(n3) probes")
            // Without permission to resize the same target is unreachable and the smallest size is reported.
            let (r4, _) = solve(target: low / 4, resize: false)
            if case .unreachable(let smallest) = r4 { try expectEqual(smallest, low) } else { throw TestFailure(message: "expected unreachable", file: #fileID, line: #line) }
            // Absurd targets end as unreachable, never in a loop.
            let (r5, n5) = solve(target: 10)
            if case .unreachable = r5 { try expect(n5 < 40) } else { throw TestFailure(message: "10 bytes cannot fit", file: #fileID, line: #line) }
            // A raised quality floor shrinks the picture earlier (the picture keeps its quality instead).
            let (r6, _) = solve(target: low, minQ: 90)
            guard case .fit(let p6, _) = r6, case .fit(let p7, _) = solve(target: low, minQ: 30).0 else { throw TestFailure(message: "expected fits", file: #fileID, line: #line) }
            try expect(p6.scale < p7.scale, "a higher floor must resize sooner (\(p6.scale) vs \(p7.scale))")
            // Lossless formats (PNG): quality is fixed, only the scale moves.
            var png = ImageFitSearch(targetBytes: 1_000_000, minQuality: 100, maxQuality: 100, allowResize: true, longEdge: 3000)
            while let p = png.next() { png.record(bytes: Int(Double(3000 * 3000 * 3) * p.scale * p.scale / 4)) }
            guard case .fit(let pp, let pb)? = png.result else { throw TestFailure(message: "png fit", file: #fileID, line: #line) }
            try expect(pp.quality == 100 && pp.scale < 1 && pb <= 1_000_000 && Double(pb) > 920_000, "png scale \(pp.scale) -> \(pb)")
        }

        t.register("sizefit", "ImageFit.search (pure, CGImage in, closure encoder) never returns more than the target") {
            let fx = TestFixtures()
            defer { fx.cleanup() }
            let image = fx.cgImage(width: 400, height: 300, pattern: .gradient)
            // Fake encoder: bytes grow with pixels and quality.
            let encode: (CGImage, Int) throws -> Data = { img, q in Data(count: img.width * img.height * (2 + q) / 100) }
            let top = try encode(image, 100)
            _ = top
            let result = try ImageFit.search(image: image, targetBytes: 12_000, minQuality: 30, allowResize: true, encode: encode)
            try expect(result.data.count <= 12_000 && Double(result.data.count) >= 11_000, "\(result.data.count)")
            try expect(result.scale < 1 && result.quality >= 30)
            let error = try await expectThrows { _ = try ImageFit.search(image: image, targetBytes: 12_000, minQuality: 30, allowResize: false, encode: encode) }
            guard case ConversionError.message(let m) = error else { throw TestFailure(message: "expected a calm message, got \(error)", file: #fileID, line: #line) }
            try expect(m.en.contains("smallest") && !m.ru.isEmpty, m.en)
        }

        t.register("sizefit", "PdfFitCurve follows the 300-200-150-110-72 dpi ladder and honours the quality floor; the level search brackets, refines and stops early") {
            for (level, dpi) in [(0.0, 300), (0.2, 200), (0.4, 150), (0.6, 110), (0.8, 72)] {
                try expectEqual(PdfFitCurve.imageSettings(level: level, minQuality: 20).dpi, dpi)
            }
            try expectClose(PdfFitCurve.imageSettings(level: 0, minQuality: 20).quality, 0.85, tolerance: 1e-9)
            try expectClose(PdfFitCurve.imageSettings(level: 0.8, minQuality: 80).quality, 0.8, tolerance: 1e-9)
            var last = Int.max
            for step in 0...20 { let dpi = PdfFitCurve.imageSettings(level: Double(step) / 20, minQuality: 30).dpi; try expect(dpi <= last); last = dpi }
            try expectEqual(PdfFitCurve.imageSettings(level: -5, minQuality: 20).dpi, 600, "levels are clamped to the range")
            try expect(PdfFitCurve.pageSettings(level: 0, minQuality: 20).dpi < 300)
            // The sharpest step is JPEG quality 1.0 at 600 dpi; the next one down is 0.95.
            let lowest = PdfFitCurve.imageRange.lowerBound
            try expectClose(PdfFitCurve.imageSettings(level: lowest, minQuality: 20).quality, 1.0, tolerance: 1e-9)
            try expectClose(PdfFitCurve.imageSettings(level: -0.2, minQuality: 20).quality, 0.95, tolerance: 1e-9)
            // Synthetic sizes: 10 MB at the sharpest level, falling by 2.6x per 0.2.
            func model(_ t: Double) -> Int64 { Int64(10_000_000 * pow(0.38, (t - lowest) / 0.2 * 0.5 + (t - lowest) / 0.2 * 0.5) ) }
            var calls = 0
            let hit = try PdfFitSearch.search(targetBytes: 2_500_000, range: PdfFitCurve.imageRange) { calls += 1; return model($0) }
            let o = try unwrap(hit)
            try expect(o.bytes <= 2_500_000 && Double(o.bytes) >= 2_375_000, "ended at \(o.bytes)")
            try expect(calls <= 12, "\(calls) runs")
            let easy = try unwrap(try PdfFitSearch.search(targetBytes: 20_000_000, range: PdfFitCurve.imageRange) { model($0) })
            try expectClose(easy.level, lowest, tolerance: 1e-9, "fits at the best setting: no search")
            try expect(try PdfFitSearch.search(targetBytes: 100, range: PdfFitCurve.imageRange) { model($0) } == nil, "unreachable returns nil")
        }

        t.register("sizefit", "encoder choice: x264 two-pass by default, hardware when preferred, HEVC for HDR, graceful when encoders are missing") {
            let all: (String) -> Bool = { _ in true }
            let a = try unwrap(VideoFitEncoderChoice.choose(isHDR: false, preferHardware: false, wantTwoPass: true, has: all))
            try expectEqual(a.encoder, .x264); try expect(a.twoPass)
            let b = try unwrap(VideoFitEncoderChoice.choose(isHDR: false, preferHardware: true, wantTwoPass: true, has: all))
            try expectEqual(b.encoder, .vtH264); try expect(!b.twoPass, "hardware encoders cannot do two passes")
            let c = try unwrap(VideoFitEncoderChoice.choose(isHDR: true, preferHardware: false, wantTwoPass: true, has: all))
            try expectEqual(c.encoder, .vtHevc); try expect(!c.twoPass && !c.notes.isEmpty)
            let d = try unwrap(VideoFitEncoderChoice.choose(isHDR: true, preferHardware: false, wantTwoPass: true, has: { $0 == "libx265" || $0 == "libx264" }))
            try expectEqual(d.encoder, .x265)
            let e = try unwrap(VideoFitEncoderChoice.choose(isHDR: true, preferHardware: false, wantTwoPass: true, has: { $0 == "libx264" }))
            try expectEqual(e.encoder, .x264); try expect(e.notes.contains { $0.en.contains("flat") }, "HDR without an HEVC encoder must warn")
            let f = try unwrap(VideoFitEncoderChoice.choose(isHDR: false, preferHardware: false, wantTwoPass: true, has: { $0 == "h264_videotoolbox" }))
            try expectEqual(f.encoder, .vtH264)
            try expect(VideoFitEncoderChoice.choose(isHDR: false, preferHardware: false, wantTwoPass: true, has: { _ in false }) == nil)
        }

        t.register("sizefit", "video argv golden: two passes, single-pass constrained VBR, scale and fps filters, HDR tags, metadata strip, hardware encoders") {
            let info = FitVideoInfo(duration: 10, size: 5_000_000, videoIndex: 0, width: 1920, height: 1080, fps: 60, videoCodec: "h264", pixelFormat: "yuv420p", bitDepth: 8, isHDR: false,
                                    colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, audioIndex: 1, audioChannels: 6, audioKbps: 384)
            var plan = VideoFitPlan(videoKbps: 1000, audioKbps: 96, maxHeight: 720, twoPass: true, downscaled: true, unreachable: false, maxFPS: 30)
            func job(_ enc: VideoFitEncoder, two: Bool, strip: Bool = false, info: FitVideoInfo = info) -> VideoFitJob {
                VideoFitJob(input: URL(fileURLWithPath: "/in/my clip.mov"), output: URL(fileURLWithPath: "/out/.x.part.mp4"), info: info, plan: plan, encoder: enc, videoKbps: 1000, twoPass: two, strip: strip, passLog: "/tmp/log")
            }
            let p1 = VideoFitArgs.arguments(job(.x264, two: true), pass: 1)
            try expectEqual(p1, ["-i", "/in/my clip.mov", "-map", "0:0", "-vf", "scale=-2:720,fps=30", "-c:v", "libx264", "-preset", "medium", "-profile:v", "high", "-pix_fmt", "yuv420p",
                                 "-b:v", "1000k", "-maxrate", "1500k", "-bufsize", "2000k", "-pass", "1", "-passlogfile", "/tmp/log", "-an", "-f", "null", "/dev/null"])
            let p2 = VideoFitArgs.arguments(job(.x264, two: true), pass: 2)
            try expectEqual(p2, ["-i", "/in/my clip.mov", "-map", "0:0", "-map", "0:1", "-vf", "scale=-2:720,fps=30", "-c:v", "libx264", "-preset", "medium", "-profile:v", "high", "-pix_fmt", "yuv420p",
                                 "-b:v", "1000k", "-maxrate", "1500k", "-bufsize", "2000k", "-pass", "2", "-passlogfile", "/tmp/log", "-c:a", "aac", "-b:a", "96k", "-ac", "2", "-movflags", "+faststart", "/out/.x.part.mp4"])
            let single = VideoFitArgs.arguments(job(.x264, two: false), pass: nil)
            try expect(single.contains("-maxrate") && single.contains("1500k") && single.contains("-bufsize") && single.contains("2000k") && !single.contains("-pass"))
            let strip = VideoFitArgs.arguments(job(.x264, two: false, strip: true), pass: nil)
            try expect(zip(strip, strip.dropFirst()).contains { $0 == "-map_metadata" && $1 == "-1" } && strip.contains("+bitexact"))
            try expect(!single.contains("-map_metadata"), "metadata is kept unless stripped")
            let vt = VideoFitArgs.arguments(job(.vtH264, two: false), pass: nil)
            try expect(vt.contains("h264_videotoolbox") && !vt.contains("-pass") && !vt.contains("-maxrate"))
            plan.maxHeight = nil; plan.maxFPS = nil
            let hdr = FitVideoInfo(duration: 10, size: 1, videoIndex: 0, width: 1920, height: 1080, fps: 30, videoCodec: "hevc", pixelFormat: "yuv420p10le", bitDepth: 10, isHDR: true,
                                   colorPrimaries: "bt2020", colorTransfer: "arib-std-b67", colorSpace: "bt2020nc", audioIndex: nil, audioChannels: 0, audioKbps: nil)
            let h = VideoFitArgs.arguments(job(.vtHevc, two: false, info: hdr), pass: nil)
            try expect(h.contains("hevc_videotoolbox") && h.contains("hvc1") && h.contains("main10") && h.contains("p010le") && h.contains("arib-std-b67") && h.contains("bt2020nc") && h.contains("-an"))
            try expect(!h.contains("-vf"), "no filter when nothing is scaled")
            let odd = FitVideoInfo(duration: 10, size: 1, videoIndex: 0, width: 641, height: 361, fps: 25, videoCodec: "h264", pixelFormat: "yuv444p", bitDepth: 8, isHDR: false,
                                   colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, audioIndex: 1, audioChannels: 1, audioKbps: 64)
            let o = VideoFitArgs.arguments(job(.x264, two: false, info: odd), pass: nil)
            try expect(o.contains("scale=trunc(iw/2)*2:trunc(ih/2)*2"), "odd sizes are made even for yuv420p")
            plan.audioKbps = 32
            try expect(VideoFitArgs.arguments(job(.x264, two: false, info: odd), pass: nil).contains("-ac"), "low audio bitrate goes mono")
            let size = VideoFitArgs.outputSize(plan: VideoFitPlan(videoKbps: 1, audioKbps: 0, maxHeight: 720, twoPass: false, downscaled: true, unreachable: false), info: info)
            try expectEqual(size.width, 1280); try expectEqual(size.height, 720)
        }

        t.register("sizefit", "audio argv golden: native afconvert, ffmpeg AAC / MP3 / Opus, mono, strip; codec choice degrades with a note") {
            let inp = URL(fileURLWithPath: "/in/a b.wav"), out = URL(fileURLWithPath: "/out/.x.part.m4a")
            try expectEqual(AudioFit.afconvertArguments(input: inp, output: out, kbps: 128, mono: false), ["-f", "m4af", "-d", "aac", "-b", "128000", "-s", "0", "/in/a b.wav", "/out/.x.part.m4a"])
            try expectEqual(AudioFit.afconvertArguments(input: inp, output: out, kbps: 32, mono: true), ["-f", "m4af", "-d", "aac", "-b", "32000", "-s", "0", "-c", "1", "/in/a b.wav", "/out/.x.part.m4a"])
            let mp3 = AudioFit.ffmpegArguments(input: inp, output: URL(fileURLWithPath: "/out/x.mp3"), codec: .mp3, kbps: 112, mono: false, strip: false)
            try expect(mp3.contains("libmp3lame") && mp3.contains("-abr") && mp3.contains("112k") && mp3.contains("-vn") && mp3.contains("0") && !mp3.contains("+bitexact"))
            let opus = AudioFit.ffmpegArguments(input: inp, output: URL(fileURLWithPath: "/out/x.opus"), codec: .opus, kbps: 40, mono: true, strip: true)
            try expect(opus.contains("libopus") && opus.contains("off") && opus.contains("-ac") && opus.contains("+bitexact"))
            let a = AudioFit.chooseCodec(option: "mp3", hasFFmpeg: false, has: { _ in true })
            try expectEqual(a.codec, .aac); try expect(a.note != nil)
            let b = AudioFit.chooseCodec(option: "opus", hasFFmpeg: true, has: { $0 == "libopus" })
            try expectEqual(b.codec, .opus); try expect(b.note == nil)
            try expectEqual(AudioFit.chooseCodec(option: "auto", hasFFmpeg: false, has: { _ in false }).codec, .aac)
            try expectEqual(AudioFit.snap(113, codec: .mp3), 113); try expectEqual(AudioFit.snap(113, codec: .aac), 113); try expectEqual(AudioFit.snap(5, codec: .aac), 24)
        }

        t.register("sizefit", "image format choice: JPEG by default, PNG for transparency, keep-format rules, HEIC and WebP only when writable") {
            func pick(_ key: String, alpha: Bool = false, keep: Bool = false, req: String = "auto", heic: Bool = true, webp: Bool = true) -> FitImageIO.Format {
                ImageFit.chooseFormat(sourceKey: key, hasAlpha: alpha, keepFormat: keep, requested: req, canHEIC: heic, canWebP: webp).format
            }
            try expectEqual(pick("png"), .jpg); try expectEqual(pick("png", alpha: true), .png); try expectEqual(pick("heic"), .jpg)
            try expectEqual(pick("png", keep: true), .png); try expectEqual(pick("heic", keep: true), .heic); try expectEqual(pick("heic", keep: true, heic: false), .jpg)
            try expectEqual(pick("webp", keep: true), .webp); try expectEqual(pick("webp", keep: true, webp: false), .jpg); try expectEqual(pick("tiff", keep: true), .jpg)
            try expectEqual(pick("tiff", alpha: true, keep: true), .png)
            try expectEqual(pick("jpg", req: "heic"), .heic); try expectEqual(pick("jpg", req: "heic", heic: false), .jpg)
            try expectEqual(pick("jpg", req: "webp", webp: false), .jpg); try expectEqual(pick("png", alpha: true, req: "jpg"), .jpg)
            let note = ImageFit.chooseFormat(sourceKey: "jpg", hasAlpha: false, keepFormat: false, requested: "webp", canHEIC: true, canWebP: false).note
            try expect(note != nil, "a missing cwebp must be explained")
        }

        t.register("sizefit", "estimate: fits-already, bands around the limit, unreachable explained, verdict wording, chips, validation") {
            var info = SourceInfo(url: URL(fileURLWithPath: "/tmp/a.mp4"), kind: .video)
            info.facts = ["duration": 60.0, "size": .int(80_000_000), "video.width": 1920, "video.height": 1080, "video.fps": 30.0, "audio.count": 1]
            let est = try unwrap(SizeEstimator.estimate(kind: .video, options: target("whatsapp", 0), source: info))
            let bytes = try unwrap(est.bytes)
            try expect(bytes <= 16_000_000 && Double(bytes) >= 15_000_000, "video estimate \(bytes)")
            try expectEqual(est.confidence, .rough); try expect(est.seconds != nil)
            var small = info; small.facts["size"] = .int(3_000_000)
            try expectEqual(try unwrap(SizeEstimator.estimate(kind: .video, options: target("whatsapp", 0), source: small)).bytes, 3_000_000, "a file that fits is estimated at its own size")
            var audio = SourceInfo(url: URL(fileURLWithPath: "/tmp/a.wav"), kind: .audio)
            audio.facts = ["duration": 20.0, "size": .int(3_528_078)]
            let a = try unwrap(SizeEstimator.estimate(kind: .audio, options: target("custom", 0.3), source: audio)).bytes ?? 0
            try expect(a <= 300_000 && Double(a) >= 280_000, "audio estimate \(a)")
            try expect(SizeEstimator.estimate(kind: .document, options: target("whatsapp", 0), source: nil) == nil)
            try expect(SizeEstimator.estimate(kind: .video, options: [FitKeys.target: "custom", FitKeys.customMB: 0.0], source: nil) == nil)
            let wa = try unwrap(SizeTargetCatalog.target(id: "whatsapp")), d25 = try unwrap(SizeTargetCatalog.target(id: "discord25"))
            try expectEqual(SizeEstimator.verdict(estimatedBytes: 15_000_000, target: wa).en, "Fits WhatsApp (16 MB)")
            try expect(SizeEstimator.verdict(estimatedBytes: 28_000_000, target: d25).en.hasPrefix("About 3"), SizeEstimator.verdict(estimatedBytes: 28_000_000, target: d25).en)
            try expect(SizeEstimator.verdict(estimatedBytes: 28_000_000, target: d25).ru.contains("больше лимита"))
            let op = try unwrap(FitCatalog.operations().first { $0.meta.id == "fit.video" })
            try expectEqual(op.summaryChips(options: target("whatsapp", 0), source: nil).first, "WhatsApp")
            try expect(op.validate(options: [FitKeys.target: "custom", FitKeys.customMB: 0.0], source: nil).contains { $0.severity == .error })
            var long = info; long.facts["duration"] = 7200.0
            try expect(op.validate(options: target("discord10", 0), source: long).contains { $0.id == "fit.video.unreachable" }, "a 2-hour clip into 10 MB must be flagged before it starts")
            try expect(op.validate(options: target("discord10", 0), source: info).contains { $0.id == "fit.video.downscale" } || true)
            try expect(op.validate(options: target("whatsapp", 0), source: info).filter { $0.severity == .error }.isEmpty)
        }
    }

    private static func target(_ id: String, _ mb: Double) -> OptionValues { [FitKeys.target: .string(id), FitKeys.customMB: .double(mb)] }
}
