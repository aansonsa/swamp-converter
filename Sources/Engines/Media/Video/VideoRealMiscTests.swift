import Foundation

// Real runs: the GIF branch (spec/handbrake.md 2.10) and frame extraction (video.thumbnail, schema video.frames).

enum VideoRealMiscTests {
    typealias R = VideoRealTests

    /// Loop count stored in a GIF's NETSCAPE extension; nil when the extension is absent (play once).
    static func gifLoop(_ url: URL) -> Int? {
        guard let d = try? Data(contentsOf: url), let r = d.range(of: Data("NETSCAPE2.0".utf8)) else { return nil }
        let i = r.upperBound
        guard d.count > i + 4 else { return nil }
        return Int(d[i + 2]) | Int(d[i + 3]) << 8
    }

    static func uniqueColors(_ f: VT.Frame) -> Int {
        var s = Set<UInt32>()
        for i in 0..<(f.rgb.count / 3) { s.insert(UInt32(f.rgb[i * 3]) << 16 | UInt32(f.rgb[i * 3 + 1]) << 8 | UInt32(f.rgb[i * 3 + 2])) }
        return s.count
    }

    static func register() {
        R.reg("GIF: frame rate, width, colours, dithering and repeat are written into a real animated GIF", oracles: ["gif.frames", "gif.size", "gif.colors", "gif.dither", "gif.loop"], timeout: 240) {
            let src = try VTShared.clip   // 320x240, 2 s
            func gif(_ set: OptionValues) async throws -> URL { try await VT.go("video.to.gif", src, set).url }
            let g = try await gif([VideoKeys.gifFps: 10, VideoKeys.gifWidth: "240"])
            let p = try VT.probe(g)
            try expectEqual(p.vcodec, "gif"); try expect(p.formatName.contains("gif"), p.formatName)
            try expect(p.width == 240 && p.height == 180, "size \(p.width)x\(p.height)")
            try expect(p.frames >= 18 && p.frames <= 22, "10 fps for 2 s gives \(p.frames) frames")
            try expect(p.streams("audio").isEmpty, "no sound in a GIF")
            try expectEqual(Array(try Data(contentsOf: g).prefix(6)), Array("GIF89a".utf8), "magic bytes")
            let wide = try VT.probe(try await gif([VideoKeys.gifWidth: "640"])); try expectEqual(wide.width, 320, "never wider than the video")
            let few = try await gif([VideoKeys.gifColors: 32, VideoKeys.gifDither: "none"])
            let fewColors = uniqueColors(try VT.frame(few, at: 0.5))
            try expect(fewColors <= 32, "at most 32 colours: \(fewColors)")
            let many = try await gif([VideoKeys.gifColors: 256, VideoKeys.gifDither: "none"])
            try expect(uniqueColors(try VT.frame(many, at: 0.5)) > 40, "256 colours use more of them")
            let noisy = try VTShared.noisy
            let bayer = try await VT.go("video.to.gif", noisy, [VideoKeys.gifColors: 16, VideoKeys.gifDither: "bayer"]).url, plain = try await VT.go("video.to.gif", noisy, [VideoKeys.gifColors: 16, VideoKeys.gifDither: "none"]).url
            let dd = try VT.frameDifference(bayer, plain, at: 0.5); try expect(dd > 0.1, "dithering changes the pixels: \(dd)")
            let forever = gifLoop(try await gif([VideoKeys.gifLoop: "forever"])), once = gifLoop(try await gif([VideoKeys.gifLoop: "once"])), three = gifLoop(try await gif([VideoKeys.gifLoop: "3"]))
            try expectEqual(forever, 0); try expectEqual(once, nil, "once: no repeat extension"); try expectEqual(three, 2, "3 plays = 2 repeats")
        }

        R.reg("gif.to.mp4 and gif.to.webm turn an animation into real video with an even frame size", oracles: []) {
            let gifSrc = try await VT.go("video.to.gif", try VTShared.clip, [VideoKeys.gifWidth: "240"]).url
            let mp4 = try VT.probe(try await VT.go("gif.to.mp4", gifSrc).url)
            try expectEqual(mp4.vcodec, "h264"); try expect(mp4.width % 2 == 0 && mp4.height % 2 == 0, "\(mp4.width)x\(mp4.height)"); try expectClose(mp4.duration, 2, tolerance: 0.3)
            let webm = try VT.probe(try await VT.go("gif.to.webm", gifSrc).url); try expectEqual(webm.vcodec, "vp9"); try expect(webm.formatName.contains("webm"), webm.formatName)
        }

        R.reg("thumbnail: the best frame, a frame at a time, a frame every N seconds, scene changes and a contact sheet are real pictures", oracles: ["frame.mode.files", "frame.time.pick", "frame.every.count", "frame.scene.count", "frame.count.max", "frame.format.magic", "frame.width.size"], timeout: 240) {
            let src = try VTShared.clip
            let best = try await VT.go("video.thumbnail", src).url
            try expect(best.pathExtension == "png" && Array(try Data(contentsOf: best).prefix(4)) == [0x89, 0x50, 0x4E, 0x47], "PNG magic")
            let sz = VT.probeSize(best); try expect(sz == (320, 240), "full size \(sz)")
            let at = try await VT.go("video.thumbnail", src, [VideoKeys.frameMode: "at", VideoKeys.frameTime: 1.5]).url
            let ref = try VT.frame(src, at: 1.5), got = try VT.frame(at, at: 0)
            let diff = zip(ref.rgb, got.rgb).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(ref.rgb.count)
            try expect(diff < 3, "the frame at 1.5 s, difference \(diff)")
            let jpg = try await VT.go("video.thumbnail", src, [VideoKeys.frameFormat: "jpg", VideoKeys.frameWidth: 160]).url
            try expectEqual(Array(try Data(contentsOf: jpg).prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG magic"); try expect(VT.probeSize(jpg) == (160, 120), "width 160: \(VT.probeSize(jpg))")
            let every = try await VT.go("video.thumbnail", src, [VideoKeys.frameMode: "every", VideoKeys.frameEvery: 0.5]).url
            var isDir: ObjCBool = false
            try expect(FileManager.default.fileExists(atPath: every.path, isDirectory: &isDir) && isDir.boolValue, "a folder of pictures")
            let files = try FileManager.default.contentsOfDirectory(atPath: every.path).filter { $0.hasSuffix(".png") }
            try expectEqual(files.count, 4, "2 s every 0.5 s")
            let capped = try await VT.go("video.thumbnail", src, [VideoKeys.frameMode: "every", VideoKeys.frameEvery: 0.5, VideoKeys.frameCount: 2]).url
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: capped.path).count, 2, "at most 2")
            let cuts = try VTShared.get("cuts") { fx in
                try VT.make(fx, "cuts.mp4", ["-f", "lavfi", "-i", "color=c=white:s=160x120:r=24:d=1", "-f", "lavfi", "-i", "color=c=black:s=160x120:r=24:d=1", "-f", "lavfi", "-i", "color=c=gray:s=160x120:r=24:d=1",
                                              "-filter_complex", "[0][1][2]concat=n=3:v=1:a=0", "-c:v", "libx264", "-pix_fmt", "yuv420p"])
            }
            let scenes = try await VT.go("video.thumbnail", cuts, [VideoKeys.frameMode: "scene", VideoKeys.frameSceneThreshold: 0.4]).url
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: scenes.path).count, 3, "the first frame and two cuts")
            let names = try FileManager.default.contentsOfDirectory(atPath: scenes.path).sorted()
            let lumas = try names.map { try VT.frame(scenes.appendingPathComponent($0), at: 0).meanLuma }
            try expect(lumas[0] > 200 && lumas[1] < 40 && lumas[2] > 90 && lumas[2] < 170, "white, black, gray: \(lumas)")
            let sheet = try await VT.go("video.thumbnail", src, [VideoKeys.frameMode: "sheet", VideoKeys.frameCount: 9]).url
            let ss = VT.probeSize(sheet); try expect(ss.0 > 320 * 2 && ss.1 > 240 * 2, "a 3x3 sheet is larger than two pictures: \(ss)")
        }
    }
}
