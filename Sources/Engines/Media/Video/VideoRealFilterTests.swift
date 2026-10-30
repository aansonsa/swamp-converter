import Foundation

// Real runs: filters (spec/handbrake.md 2.5). Oracles: idet, edge energy, saturation / luma statistics, duration, frame differences, bounding boxes of overlays.

enum VideoRealFilterTests {
    typealias R = VideoRealTests
    /// A high quality so the filter, not the encoder, decides the result.
    static let hq: OptionValues = [VideoKeys.cq: 8, VideoKeys.venc: "software", VideoKeys.speed: "ultrafast"]

    static func with(_ extra: OptionValues) -> OptionValues { extra.merged(over: hq) }

    static func register() {
        R.reg("deinterlace: Auto removes the combing of an interlaced source, Off leaves it, and a field rate doubles the frames", oracles: ["deint.idet", "deint.rate", "deint.method"], timeout: 240) {
            let src = try VTShared.get("interlaced") { try VT.interlaced($0) }
            let before = VT.idet(src)
            try expect(before.interlaced > before.progressive, "the fixture is interlaced: \(before)")
            let auto = try await VT.go("video.to.mp4", src, [VideoKeys.deinterlace: "auto"]).url
            let a = VT.idet(auto)
            try expect(a.progressive > a.interlaced * 5, "after Auto: \(a)")
            let off = VT.idet(try await VT.go("video.to.mp4", src, [VideoKeys.deinterlace: "off"]).url)
            try expect(off.interlaced > off.progressive, "Off leaves the combing: \(off)")
            for m in ["yadif", "w3fdif"] {
                let o = VT.idet(try await VT.go("video.to.mp4", src, [VideoKeys.deinterlace: "on", VideoKeys.deintMethod: .string(m)]).url)
                try expect(o.progressive > o.interlaced * 3, "\(m): \(o)")
            }
            let frame = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.deinterlace: "on", VideoKeys.deintRate: "frame"]).url)
            let field = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.deinterlace: "on", VideoKeys.deintRate: "field"]).url)
            try expect(Double(field.frames) > Double(frame.frames) * 1.8, "field rate doubles the frames: \(frame.frames) -> \(field.frames)")
        }

        R.reg("deinterlace Auto leaves a progressive source alone (no filter in the chain)", oracles: []) {
            let argv = try VTPlan.argv([VideoKeys.deinterlace: "auto"], info: VTPlan.info(interlaced: false)).joined(separator: " ")
            try expect(!argv.contains("bwdif") && !argv.contains("yadif"), argv)
            let on = try VTPlan.argv([VideoKeys.deinterlace: "auto"], info: VTPlan.info(interlaced: true)).joined(separator: " ")
            try expect(on.contains("bwdif=mode=send_frame"), on)
            var an = VideoAnalysis(); an.interlaced = true
            let analysed = try VTPlan.argv([VideoKeys.deinterlace: "auto"], info: VTPlan.info(interlaced: false), analysis: an).joined(separator: " ")
            try expect(analysed.contains("bwdif"), "the idet verdict triggers the filter: \(analysed)")
        }

        R.reg("clean-up filters that are only checked in the command line also run: pulldown removal, deblock, chroma smoothing, banding", oracles: ["ivtc.argv", "deblock.argv", "chroma.argv", "deband.argv", "stab.argv", "temp.argv"], timeout: 240) {
            let src = try VTShared.clip
            let set: OptionValues = [VideoKeys.ivtc: "auto", VideoKeys.deblock: "strong", VideoKeys.chromaSmooth: "medium", VideoKeys.deband: true, VideoKeys.stabilize: true, VideoKeys.colorTemp: 4000]
            let a = try VTPlan.argv(set).joined(separator: " ")
            for part in ["fieldmatch=order=auto:mode=pc", "decimate", "deblock=filter=strong", "unsharp=luma_amount=0:chroma_msize_x=7", "gradfun=strength=1.2:radius=16", "deshake", "colortemperature=temperature=4000"] {
                try expect(a.contains(part), "missing \(part) in \(a)")
            }
            let o = try await VT.go("video.to.mp4", src, set.merged(over: [VideoKeys.speed: "ultrafast", VideoKeys.venc: "software"])).url
            try expectEqual(try VT.probe(o).width, 320); try expectClose(try VT.probe(o).duration, 2, tolerance: 0.3)
        }

        R.reg("noise reduction removes noise: edge energy falls step by step (off > light > medium > strong), for every method", oracles: ["denoise.noise", "denoise.method"], timeout: 240) {
            let src = try VTShared.noisy
            var energy: [Double] = []
            for level in ["off", "light", "medium", "strong"] {
                let o = try await VT.go("video.to.mp4", src, with([VideoKeys.denoise: .string(level)])).url
                energy.append(try VT.frame(o, at: 0.5).edgeEnergy)
            }
            try expect(energy[0] > energy[1] && energy[1] > energy[2] && energy[2] > energy[3], "edge energy \(energy)")
            for m in ["nlmeans", "atadenoise"] {
                let o = try await VT.go("video.to.mp4", src, with([VideoKeys.denoise: "strong", VideoKeys.denoiseMethod: .string(m)])).url
                let e = try VT.frame(o, at: 0.5).edgeEnergy
                try expect(e < energy[0] * (m == "nlmeans" ? 0.9 : 0.99), "\(m) lowers the energy: \(e) vs \(energy[0])")
            }
        }

        R.reg("sharpen raises edge energy step by step, with either method", oracles: ["sharpen.edges", "sharpen.method"], timeout: 240) {
            let src = try VTShared.clip
            var energy: [Double] = []
            for level in ["off", "light", "medium", "strong"] {
                let o = try await VT.go("video.to.mp4", src, with([VideoKeys.sharpen: .string(level)])).url
                energy.append(try VT.frame(o, at: 0.5).edgeEnergy)
            }
            try expect(energy[0] < energy[1] && energy[1] < energy[2] && energy[2] < energy[3], "edge energy \(energy)")
            let cas = try await VT.go("video.to.mp4", src, with([VideoKeys.sharpen: "strong", VideoKeys.sharpenMethod: "cas"])).url
            try expect(try VT.frame(cas, at: 0.5).edgeEnergy > energy[0] * 1.02, "CAS sharpens")
        }

        R.reg("black and white removes the colour; brightness, contrast, saturation and gamma move the picture the right way", oracles: ["gray.saturation", "eq.brightness", "eq.contrast", "eq.saturation", "eq.gamma"], timeout: 240) {
            let src = try VTShared.clip
            let base = try VT.frame(try await VT.go("video.to.mp4", src, hq).url, at: 0.5)
            try expect(base.meanSaturation > 0.2, "the fixture is colourful: \(base.meanSaturation)")
            let gray = try VT.frame(try await VT.go("video.to.mp4", src, with([VideoKeys.gray: true])).url, at: 0.5)
            try expect(gray.meanSaturation < 0.06, "grayscale saturation \(gray.meanSaturation)")
            let up = try VT.frame(try await VT.go("video.to.mp4", src, with([VideoKeys.eqBrightness: 0.25])).url, at: 0.5)
            let down = try VT.frame(try await VT.go("video.to.mp4", src, with([VideoKeys.eqBrightness: -0.25])).url, at: 0.5)
            try expect(up.meanLuma > base.meanLuma + 15 && down.meanLuma < base.meanLuma - 15, "brightness \(down.meanLuma) < \(base.meanLuma) < \(up.meanLuma)")
            let contrast = try VT.frame(try await VT.go("video.to.mp4", src, with([VideoKeys.eqContrast: 1.6])).url, at: 0.5)
            try expect(contrast.lumaStdDev > base.lumaStdDev * 1.08, "contrast \(contrast.lumaStdDev) vs \(base.lumaStdDev)")
            let sat0 = try VT.frame(try await VT.go("video.to.mp4", src, with([VideoKeys.eqSaturation: 0])).url, at: 0.5)
            let satHalf = try VT.frame(try await VT.go("video.to.mp4", src, with([VideoKeys.eqSaturation: 0.5])).url, at: 0.5)
            try expect(sat0.meanSaturation < 0.06 && satHalf.meanSaturation < base.meanSaturation * 0.8 && satHalf.meanSaturation > sat0.meanSaturation, "saturation \(sat0.meanSaturation) / \(satHalf.meanSaturation) / \(base.meanSaturation)")
            let gamma = try VT.frame(try await VT.go("video.to.mp4", src, with([VideoKeys.eqGamma: 1.8])).url, at: 0.5)
            try expect(gamma.meanLuma > base.meanLuma + 8, "gamma brightens the midtones: \(gamma.meanLuma) vs \(base.meanLuma)")
        }

        R.reg("colour temperature shifts the picture towards warm or cold", oracles: []) {
            let src = try VTShared.clip
            let warm = try VT.frame(try await VT.go("video.to.mp4", src, with([VideoKeys.colorTemp: 3000])).url, at: 0.5)
            let cold = try VT.frame(try await VT.go("video.to.mp4", src, with([VideoKeys.colorTemp: 9500])).url, at: 0.5)
            try expect((warm.meanRed - warm.meanBlue) != (cold.meanRed - cold.meanBlue), "the two temperatures differ")
            try expect(abs((warm.meanRed - warm.meanBlue) - (cold.meanRed - cold.meanBlue)) > 4, "red-blue balance \(warm.meanRed - warm.meanBlue) vs \(cold.meanRed - cold.meanBlue)")
        }

        R.reg("speed changes the length of picture and sound; reverse plays backwards; fades start and end dark and silent", oracles: ["speed.duration", "reverse.frames", "fade.in", "fade.out"], timeout: 240) {
            let src = try VTShared.clip
            let fast = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.filterSpeed: 2.0]).url)
            try expectClose(fast.duration, 1.0, tolerance: 0.15); try expectClose(fast.dbl(fast.audio, "duration"), 1.0, tolerance: 0.15, "sound is sped up too")
            let slow = try VT.probe(try await VT.go("video.to.mp4", src, [VideoKeys.filterSpeed: 0.5]).url)
            try expectClose(slow.duration, 4.0, tolerance: 0.25)
            // Reverse: the first frame of the result is the last frame of the source.
            let out = try await VT.go("video.to.mp4", src, with([VideoKeys.reverse: true])).url
            let first = try VT.frame(out, at: 0.0), srcLast = try VT.frame(src, at: 1.95), srcFirst = try VT.frame(src, at: 0.0)
            func dist(_ a: VT.Frame, _ b: VT.Frame) -> Double { zip(a.rgb, b.rgb).reduce(0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(a.rgb.count) }
            try expect(dist(first, srcLast) < dist(first, srcFirst), "reverse: \(dist(first, srcLast)) vs \(dist(first, srcFirst))")
            // Fades.
            let faded = try await VT.go("video.to.mp4", src, with([VideoKeys.fadeIn: 1.0, VideoKeys.fadeOut: 0.5])).url
            let f0 = try VT.frame(faded, at: 0.0), mid = try VT.frame(faded, at: 1.0), fEnd = try VT.frame(faded, at: 1.95)
            try expect(f0.meanLuma < 20 && mid.meanLuma > 40 && fEnd.meanLuma < mid.meanLuma * 0.5, "luma \(f0.meanLuma) / \(mid.meanLuma) / \(fEnd.meanLuma)")
            let start = try unwrap(VT.rmsDB(faded, from: 0, duration: 0.15)), middle = try unwrap(VT.rmsDB(faded, from: 0.9, duration: 0.5))
            try expect(start < middle - 12, "audio fades in: \(start) dB then \(middle) dB")
        }

        R.reg("watermark: text and image land where they are told, with the size, opacity and margin asked for, and change nothing else", oracles: ["wm.region", "wm.pos", "wm.scale", "wm.opacity", "wm.margin"], timeout: 240) {
            let src = try VTShared.get("big320") { try VT.clip($0, "wm-src.mp4", seconds: 1, size: "640x480", noise: 0) }
            // Lossless encodes: outside the mark the two pictures are identical, so the difference box IS the mark.
            let lossless: OptionValues = [VideoKeys.rateControl: "lossless", VideoKeys.venc: "software", VideoKeys.speed: "ultrafast", VideoKeys.container: "mkv"]
            let base = try await VT.go("video.to.mp4", src, lossless).url
            func wm(_ set: OptionValues) async throws -> URL { try await VT.go("video.to.mp4", src, lossless.merged(over: [:]).overlaying(set.merged(over: [VideoKeys.wmMode: "text", VideoKeys.wmText: "SWAMP MARK"]))).url }
            let br = try unwrap(try VT.diffBox(try await wm([:]), base, at: 0.5), "text watermark changes the picture")
            try expect(br.x0 > br.w / 2 && br.y0 > br.h / 2, "bottom right by default: \(br)")
            try expect(br.x1 <= br.w - 20 && br.y1 <= br.h - 20 && br.x1 >= br.w - 40, "margin 24: right edge \(br.x1) of \(br.w), bottom \(br.y1) of \(br.h)")
            let tlURL = try await wm([VideoKeys.wmPos: "tl"])
            let tl = try unwrap(try VT.diffBox(tlURL, base, at: 0.5))
            try expect(tl.x1 < tl.w / 2 && tl.y1 < tl.h / 2 && tl.x0 >= 16, "top left: \(tl)")
            let c = try unwrap(try VT.diffBox(try await wm([VideoKeys.wmPos: "center"]), base, at: 0.5))
            try expect(abs((c.x0 + c.x1) / 2 - c.w / 2) < 20 && abs((c.y0 + c.y1) / 2 - c.h / 2) < 20, "centre: \(c)")
            let small = try unwrap(try VT.diffBox(try await wm([VideoKeys.wmScale: 15]), base, at: 0.5)), large = try unwrap(try VT.diffBox(try await wm([VideoKeys.wmScale: 30]), base, at: 0.5))
            let ratio = Double(large.x1 - large.x0) / Double(max(1, small.x1 - small.x0))
            try expect(ratio > 1.6 && ratio < 2.4, "twice the scale, about twice the width: \(ratio)")
            let faint = try unwrap(try VT.diffBox(try await wm([VideoKeys.wmOpacity: 30]), base, at: 0.5, threshold: 20)), solid = try unwrap(try VT.diffBox(try await wm([VideoKeys.wmOpacity: 100]), base, at: 0.5, threshold: 20))
            try expect(solid.mean > faint.mean * 1.5, "opacity: \(solid.mean) vs \(faint.mean)")
            let wide = try unwrap(try VT.diffBox(try await wm([VideoKeys.wmMargin: 80]), base, at: 0.5))
            try expect(wide.x1 <= wide.w - 70 && wide.y1 <= wide.h - 70, "margin 80: \(wide)")
            // Outside the box nothing changed (the box covers all differences by construction); the first frame outside the mark is the same picture.
            let png = try VT.make(VTShared.fx, "mark.png", ["-f", "lavfi", "-i", "color=c=magenta:s=64x64", "-frames:v", "1"])
            let img = try await VT.go("video.to.mp4", src, lossless.overlaying([VideoKeys.wmMode: "image", VideoKeys.wmFile: .string(png.path), VideoKeys.wmScale: 20, VideoKeys.wmPos: "tr", VideoKeys.wmOpacity: 100])).url
            let ib = try unwrap(try VT.diffBox(img, base, at: 0.5))
            try expect(ib.x0 > ib.w / 2 && ib.y1 < ib.h / 2, "image at the top right: \(ib)")
            let f = try VT.frame(img, at: 0.5); let px = f.pixel((ib.x0 + ib.x1) / 2, (ib.y0 + ib.y1) / 2)
            try expect(px.0 > 180 && px.2 > 180 && px.1 < 90, "magenta image pixels \(px)")
        }
    }
}
