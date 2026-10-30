import Foundation

// Real runs: orientation, crop, size, borders, frame rate (spec/handbrake.md 2.4). Quadrant colours and dimensions are read back independently.

enum VideoRealPictureTests {
    typealias R = VideoRealTests

    static func register() {
        R.reg("rotate: 90, 180 and 270 degrees clockwise put the quadrants where they belong and swap the size", oracles: ["rotate.quadrants"]) {
            let card = try VTShared.card
            let expected: [(String, [String], Int, Int)] = [("90", ["blue", "red", "yellow", "green"], 240, 320), ("180", ["yellow", "blue", "green", "red"], 320, 240),
                                                            ("270", ["green", "yellow", "red", "blue"], 240, 320)]
            for (deg, quads, w, h) in expected {
                let o = try await VT.go("video.to.mp4", card, [VideoKeys.rotate: .string(deg)]).url
                let p = try VT.probe(o)
                try expect(p.width == w && p.height == h, "rotate \(deg): \(p.width)x\(p.height)")
                try expectEqual(try VT.quadrants(o), quads, "rotate \(deg)")
            }
        }

        R.reg("flip: horizontal and vertical mirror the quadrants (and both together equal a 180 degree turn)", oracles: ["flip.quadrants"]) {
            let card = try VTShared.card
            let h = try VT.quadrants(try await VT.go("video.to.mp4", card, [VideoKeys.flipH: true]).url)
            try expectEqual(h, ["green", "red", "yellow", "blue"])
            let v = try VT.quadrants(try await VT.go("video.to.mp4", card, [VideoKeys.flipV: true]).url)
            try expectEqual(v, ["blue", "yellow", "red", "green"])
            let both = try VT.quadrants(try await VT.go("video.to.mp4", card, [VideoKeys.flipH: true, VideoKeys.flipV: true]).url)
            try expectEqual(both, ["yellow", "blue", "green", "red"])
            let rf = try VT.quadrants(try await VT.go("video.to.mp4", card, [VideoKeys.rotate: "90", VideoKeys.flipH: true]).url)
            try expectEqual(rf, ["red", "blue", "green", "yellow"], "rotate first, then flip")
        }

        R.reg("phone footage: the stored rotation is applied by default and left alone when asked", oracles: ["respectMeta.noautorotate"]) {
            let card = try VTShared.card
            let phone = try VTShared.get("phone") { try VT.rotated($0, from: card, "phone.mp4") }
            let p0 = try VT.probe(phone)
            try expectEqual(p0.width, 320, "stored upright 320 wide")
            let upright = try await VT.go("video.to.mp4", phone).url
            let pu = try VT.probe(upright)
            try expect(pu.width == 240 && pu.height == 320, "applied: \(pu.width)x\(pu.height)")
            try expectEqual(try VT.quadrants(upright), ["green", "yellow", "red", "blue"], "turned counter-clockwise as the file says")
            let raw = try await VT.go("video.to.mp4", phone, [VideoKeys.respectMeta: false]).url
            let pr = try VT.probe(raw)
            try expect(pr.width == 320 && pr.height == 240, "kept as stored: \(pr.width)x\(pr.height)")
            try expectEqual(try VT.quadrants(raw, autorotate: false), ["red", "green", "blue", "yellow"], "stored pixels untouched")
        }

        R.reg("crop: custom edges remove exactly that many pixels, and automatic crop finds the black bars", oracles: ["crop.dimensions"]) {
            let card = try VTShared.card
            let c = try await VT.go("video.to.mp4", card, [VideoKeys.cropMode: "custom", VideoKeys.cropTop: 10, VideoKeys.cropBottom: 20, VideoKeys.cropLeft: 30, VideoKeys.cropRight: 40]).url
            let pc = try VT.probe(c)
            try expect(pc.width == 250 && pc.height == 210, "custom crop gave \(pc.width)x\(pc.height)")
            let br = try await VT.go("video.to.mp4", card, [VideoKeys.cropMode: "custom", VideoKeys.cropLeft: 160, VideoKeys.cropTop: 120]).url
            try expectEqual(try VT.quadrants(br), ["yellow", "yellow", "yellow", "yellow"], "the bottom-right quarter is what is left")
            let lb = try VTShared.get("letterbox") { try VT.letterbox($0) }
            let a = try VT.probe(try await VT.go("video.to.mp4", lb, [VideoKeys.cropMode: "auto"]).url)
            try expect(abs(a.height - 180) <= 2 && abs(a.width - 320) <= 2, "automatic crop gave \(a.width)x\(a.height), expected 320x180")
            let none = try VT.probe(try await VT.go("video.to.mp4", lb, [VideoKeys.cropMode: "none"]).url)
            try expectEqual(none.height, 240, "no crop keeps the bars")
        }

        R.reg("size: limit, exact, percent, fill and fit give the frame asked for and never enlarge unless allowed", oracles: ["size.dimensions", "size.limit", "size.exact", "size.percent", "size.upscale"]) {
            let big = try VTShared.big   // 640x480
            func dims(_ set: OptionValues) async throws -> (Int, Int) { let p = try VT.probe(try await VT.go("video.to.mp4", big, set).url); return (p.width, p.height) }
            var d = try await dims([VideoKeys.sizeMode: "limit", VideoKeys.sizeLimit: "360p"]); try expect(d == (480, 360), "limit 360p: \(d)")
            d = try await dims([VideoKeys.sizeMode: "limit", VideoKeys.sizeLimit: "720p"]); try expect(d == (640, 480), "limit 720p must not enlarge: \(d)")
            d = try await dims([VideoKeys.sizeMode: "limit", VideoKeys.sizeLimit: "720p", VideoKeys.sizeUpscale: true]); try expect(d == (960, 720), "upscale allowed: \(d)")
            d = try await dims([VideoKeys.sizeMode: "exact", VideoKeys.sizeW: 200, VideoKeys.sizeH: 100]); try expect(d == (200, 100), "exact: \(d)")
            d = try await dims([VideoKeys.sizeMode: "exact", VideoKeys.sizeW: 320, VideoKeys.sizeH: 0]); try expect(d == (320, 240), "one side keeps the aspect: \(d)")
            d = try await dims([VideoKeys.sizeMode: "percent", VideoKeys.sizePercent: 50]); try expect(d == (320, 240), "50%: \(d)")
            d = try await dims([VideoKeys.sizeMode: "fill", VideoKeys.sizeW: 300, VideoKeys.sizeH: 300]); try expect(d == (300, 300), "fill: \(d)")
            d = try await dims([VideoKeys.sizeMode: "fit", VideoKeys.sizeW: 800, VideoKeys.sizeH: 600]); try expect(d == (800, 600), "fit canvas: \(d)")
            // A portrait source with "limit 360p": the SHORT side is limited.
            let portrait = try VTShared.get("portrait") { try VT.clip($0, "portrait.mp4", size: "360x640") }
            let pp = try VT.probe(try await VT.go("video.to.mp4", portrait, [VideoKeys.sizeMode: "limit", VideoKeys.sizeLimit: "360p"]).url)
            try expect(pp.width == 360 && pp.height == 640, "a 360x640 portrait is already within 360p: \(pp.width)x\(pp.height)")
        }

        R.reg("size: modulus rounds, the scaler changes the pixels, square pixels are produced from stretched ones", oracles: ["size.modulus", "size.scaler", "size.par"]) {
            let big = try VTShared.big
            let m = try VT.probe(try await VT.go("video.to.mp4", big, [VideoKeys.sizeMode: "percent", VideoKeys.sizePercent: 47, VideoKeys.sizeModulus: "16"]).url)
            try expect(m.width % 16 == 0 && m.height % 16 == 0 && m.width > 0, "modulus 16: \(m.width)x\(m.height)")
            let lan = try await VT.go("video.to.mp4", big, [VideoKeys.sizeMode: "percent", VideoKeys.sizePercent: 50, VideoKeys.sizeScaler: "lanczos"]).url
            let nn = try await VT.go("video.to.mp4", big, [VideoKeys.sizeMode: "percent", VideoKeys.sizePercent: 50, VideoKeys.sizeScaler: "neighbor"]).url
            try expect(try VT.frameDifference(lan, nn, at: 0.5) > 0.4, "nearest neighbour and Lanczos give different pixels")
            let anam = try VTShared.get("anamorphic") { try VT.clip($0, "anam.mkv", vf: "setsar=4/3") }
            let sq = try VT.probe(try await VT.go("video.to.mp4", anam).url)
            try expect(sq.width >= 424 && sq.width <= 428 && sq.height == 240, "square pixels: \(sq.width)x\(sq.height)")
            try expect(sq.str(sq.video, "sample_aspect_ratio") == "1:1" || sq.str(sq.video, "sample_aspect_ratio").isEmpty, "SAR \(sq.str(sq.video, "sample_aspect_ratio"))")
            let keep = try VT.probe(try await VT.go("video.to.mp4", anam, [VideoKeys.sizePar: "keep"]).url)
            try expect(keep.width == 320 && keep.str(keep.video, "sample_aspect_ratio") == "4:3", "kept: \(keep.width) \(keep.str(keep.video, "sample_aspect_ratio"))")
        }

        R.reg("size: the crop focus decides which part a fill keeps", oracles: ["size.anchor"]) {
            let card = try VTShared.card
            func q(_ a: String) async throws -> [String] {
                try VT.quadrants(try await VT.go("video.to.mp4", card, [VideoKeys.sizeMode: "fill", VideoKeys.sizeW: 160, VideoKeys.sizeH: 240, VideoKeys.sizeAnchor: .string(a)]).url)
            }
            let left = try await q("left"), right = try await q("right")
            try expectEqual(left, ["red", "red", "blue", "blue"])
            try expectEqual(right, ["green", "green", "yellow", "yellow"])
            let c = try await q("center"); try expect(c.first == "red" && c[1] == "green", "centre shows both halves: \(c)")
        }

        R.reg("borders: solid bars, a coloured border and the blurred background fill the empty areas", oracles: ["pad.pixels", "pad.color"]) {
            let card = try VTShared.card
            let bars = try await VT.go("video.to.mp4", card, [VideoKeys.sizeMode: "fit", VideoKeys.sizeW: 400, VideoKeys.sizeH: 400, VideoKeys.padMode: "bars", VideoKeys.padColor: "#0000FF"]).url
            let pb = try VT.probe(bars); try expect(pb.width == 400 && pb.height == 400, "canvas \(pb.width)x\(pb.height)")
            let fb = try VT.frame(bars, at: 0.5)
            let corner = fb.pixel(4, 4); try expect(corner.2 > 200 && corner.0 < 60, "blue bar in the corner: \(corner)")
            let centre = fb.pixel(100, 120); try expectEqual(VT.quadrantColor(centre), "red", "the picture sits in the middle")
            let border = try await VT.go("video.to.mp4", card, [VideoKeys.padMode: "border", VideoKeys.padColor: "#FF0000", VideoKeys.padTop: 20, VideoKeys.padBottom: 40, VideoKeys.padLeft: 10, VideoKeys.padRight: 30]).url
            let pbd = try VT.probe(border); try expect(pbd.width == 360 && pbd.height == 300, "border grows the frame: \(pbd.width)x\(pbd.height)")
            let fbd = try VT.frame(border, at: 0.5)
            try expect(fbd.pixel(3, 3).0 > 200 && fbd.pixel(3, 3).1 < 60, "red border pixel \(fbd.pixel(3, 3))")
            let blur = try await VT.go("video.to.mp4", card, [VideoKeys.sizeMode: "fit", VideoKeys.sizeW: 400, VideoKeys.sizeH: 400, VideoKeys.padMode: "blur"]).url
            let fbl = try VT.frame(blur, at: 0.5)
            let b = fbl.pixel(4, 4); try expect(b.0 + b.1 + b.2 > 150, "a blurred copy of the picture, not black: \(b)")
        }

        R.reg("frame rate: peak, constant, NTSC fractions and variable source", oracles: ["fps.rate", "fps.interp"], timeout: 240) {
            let f60 = try VTShared.get("f60") { try VT.clip($0, "f60.mp4", seconds: 1, size: "320x240", fps: 60) }
            let peak60 = try VT.probe(try await VT.go("video.to.mp4", f60, [VideoKeys.fpsMode: "peak", VideoKeys.fps: "30"]).url)
            try expectClose(peak60.rate("r_frame_rate"), 30, tolerance: 0.1, "60 -> 30")
            let clip = try VTShared.clip   // 24 fps
            let peak24 = try VT.probe(try await VT.go("video.to.mp4", clip, [VideoKeys.fpsMode: "peak", VideoKeys.fps: "30"]).url)
            try expectClose(peak24.rate("r_frame_rate"), 24, tolerance: 0.1, "24 stays 24")
            let const15 = try VT.probe(try await VT.go("video.to.mp4", clip, [VideoKeys.fpsMode: "constant", VideoKeys.fps: "15"]).url)
            try expectClose(const15.rate("r_frame_rate"), 15, tolerance: 0.05); try expectClose(const15.rate("avg_frame_rate"), 15, tolerance: 0.1)
            let ntsc = try VT.probe(try await VT.go("video.to.mp4", clip, [VideoKeys.fpsMode: "constant", VideoKeys.fps: "29.97"]).url)
            try expectEqual(ntsc.str(ntsc.video, "r_frame_rate"), "30000/1001")
            let vfr = try VTShared.get("vfr") { try VT.vfr($0) }
            let kept = try VT.probe(try await VT.go("video.to.mp4", vfr).url)
            try expect(abs(kept.rate("r_frame_rate") - kept.rate("avg_frame_rate")) / max(kept.rate("r_frame_rate"), 1) > 0.05, "a variable source stays variable")
            let fixed = try VT.probe(try await VT.go("video.to.mp4", vfr, [VideoKeys.fpsMode: "constant", VideoKeys.fps: "25"]).url)
            try expectClose(fixed.rate("avg_frame_rate"), 25, tolerance: 0.2); try expectClose(fixed.rate("r_frame_rate"), 25, tolerance: 0.05)
            let blend = try VT.probe(try await VT.go("video.to.mp4", clip, [VideoKeys.fpsMode: "constant", VideoKeys.fps: "48", VideoKeys.fpsInterp: "blend"]).url)
            try expectClose(blend.rate("r_frame_rate"), 48, tolerance: 0.1)
            try expect(blend.frames >= 90, "frames doubled: \(blend.frames)")
            let motion = try VT.probe(try await VT.go("video.to.mp4", clip, [VideoKeys.fpsMode: "constant", VideoKeys.fps: "48", VideoKeys.fpsInterp: "motion"]).url)
            try expectClose(motion.rate("r_frame_rate"), 48, tolerance: 0.1)
            let a = try VTPlan.argv([VideoKeys.fpsMode: "constant", VideoKeys.fps: "48", VideoKeys.fpsInterp: "motion"]).joined(separator: " ")
            try expect(a.contains("minterpolate=fps=48:mi_mode=mci"), a)
        }

        R.reg("odd-sized sources (321x241) convert to an even frame without error", oracles: []) {
            let odd = try VTShared.get("odd") { try VT.oddSize($0) }
            for op in ["video.to.mp4", "video.to.mov", "video.to.mkv"] {
                let p = try VT.probe(try await VT.go(op, odd).url)
                try expect(p.width % 2 == 0 && p.height % 2 == 0 && p.width >= 320, "\(op): \(p.width)x\(p.height)")
            }
            let hevc = try VT.probe(try await VT.go("video.to.mp4", odd, [VideoKeys.vcodec: "hevc", VideoKeys.speed: "ultrafast"]).url)
            try expect(hevc.width % 2 == 0, "HEVC: \(hevc.width)x\(hevc.height)")
        }
    }
}
