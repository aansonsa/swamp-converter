import Foundation

// Tests: quality ladder, format selection per mode, argv golden tests (arrays only, URL last, nothing optional unless asked for).

private func argValue(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
private func argValues(_ a: [String], _ flag: String) -> [String] { a.indices.filter { a[$0] == flag && $0 + 1 < a.count }.map { a[$0 + 1] } }

private func vf(_ id: String, _ w: Int, _ h: Int, vcodec: String = "avc1.640028", fps: Double = 30, tbr: Double = 1000, hdr: String = "SDR") -> DownloadFormat {
    DownloadFormat(id: id, ext: "mp4", vcodec: vcodec, acodec: "none", width: w, height: h, fps: fps, dynamicRange: hdr, filesize: nil, filesizeApprox: nil, tbr: tbr, note: nil)
}

extension DownloaderTests {
    // MARK: Formats

    static func registerFormats() {
        test("formats: the quality ladder lists the heights the page offers with codec, fps, HDR and size", oracles: ["dl.height.cap"]) {
            let video = try DownloaderFixtures.info("video.json")
            let ladder = FormatSelector.qualityOptions(for: video)
            try expectEqual(ladder.map(\.height), [2160, 1440, 1080, 720, 360, 144])
            try expectEqual(ladder.map(\.label), ["2160p", "1440p", "1080p", "720p", "360p", "144p"])
            try expectEqual(ladder.first { $0.height == 1080 }?.codec, .h264, "H.264 wins at 1080p: it is remuxed without loss and its bitrate is the best")
            try expectEqual(ladder.first { $0.height == 2160 }?.codec, .vp9, "no Apple-friendly stream at 2160p: the best bitrate wins and the convert stage re-encodes it")
            try expectEqual(ladder.first { $0.height == 1080 }?.estimatedBytes, 190_000_000 + 9_900_000, "video plus the AAC stream")
            try expectEqual(ladder.first { $0.height == 1080 }?.selector, "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b")
            let k8 = FormatSelector.qualityOptions(for: try DownloaderFixtures.info("video-8k-hdr.json"))
            try expectEqual(k8.map(\.height), [4320, 2160, 1080])
            try expectEqual(k8.first?.label, "4320p60 HDR", "8K, 60 fps and HDR are visible in the label")
            try expect(k8.first?.isHDR == true && k8.first?.estimatedBytes == 1_950_000_000 + 4_900_000)
            try expectEqual(FormatSelector.qualityOptions(for: try DownloaderFixtures.info("audio-only.json")), [], "an audio page has no picture ladder")
        }

        test("formats: Best for Apple and Maximum take the best picture, a height cap is honoured, DRM formats are never chosen", oracles: ["dl.mode.selector", "dl.height.cap"]) {
            let video = try DownloaderFixtures.info("video.json")
            let best = try unwrap(FormatSelector.choose(info: video, mode: .bestForApple, maxHeight: nil))
            try expectEqual(best.video?.id, "313"); try expectEqual(best.audio?.id, "140", "AAC within 15 percent of Opus is taken: no audio re-encode")
            try expectEqual(best.selector, "313+140/bv*+ba/b", "explicit ids first, the generic expression as the safety net")
            try expect(best.needsMerge)
            try expectEqual(try unwrap(FormatSelector.choose(info: video, mode: .maximum, maxHeight: nil)).selector, best.selector, "Maximum picks the same streams; only the after-step differs")
            let capped = try unwrap(FormatSelector.choose(info: video, mode: .bestForApple, maxHeight: 1080))
            try expectEqual(capped.selector, "137+140/bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b")
            try expectEqual(try unwrap(FormatSelector.choose(info: video, mode: .bestForApple, maxHeight: 720)).video?.id, "136")
            try expectEqual(try unwrap(FormatSelector.choose(info: video, mode: .bestForApple, maxHeight: 360)).muxed?.id, "18", "a single progressive stream needs no merge at 360p")
            try expectEqual(try unwrap(FormatSelector.choose(info: video, mode: .bestForApple, maxHeight: 100)).video?.id, "160", "nothing under the cap: the smallest picture there is")
            // 8K HDR: height, then frame rate, then HDR.
            let k8 = try DownloaderFixtures.info("video-8k-hdr.json")
            try expectEqual(try unwrap(FormatSelector.choose(info: k8, mode: .bestForApple, maxHeight: nil)).video?.id, "702", "8K HDR10 beats 8K SDR at 60 fps")
            try expectEqual(try unwrap(FormatSelector.choose(info: k8, mode: .bestForApple, maxHeight: 2160)).video?.id, "334", "HDR 2160p60 beats SDR 2160p60")
            try expectEqual(try unwrap(FormatSelector.choose(info: k8, mode: .bestForApple, maxHeight: 1440)).video?.id, "299", "no 1440p: the best 1080p, the higher bitrate H.264")
            // DRM-protected formats are never offered.
            var drm = video
            drm.formats = drm.formats.map { var f = $0; if f.id == "137" { f.hasDRM = true }; return f }
            try expect(try unwrap(FormatSelector.choose(info: drm, mode: .bestForApple, maxHeight: 1080)).video?.id != "137")
            try expect(!FormatSelector.qualityOptions(for: drm).isEmpty)
            // Codec choice at one height: VP9 only wins when it is clearly better than H.264.
            var close = video
            close.formats = close.formats.map { var f = $0; if f.id == "248" { f.tbr = 2600 }; return f }
            try expectEqual(try unwrap(FormatSelector.choose(info: close, mode: .bestForApple, maxHeight: 1080)).video?.id, "137", "H.264 within 15 percent of the best bitrate")
            var far = video
            far.formats = far.formats.map { var f = $0; if f.id == "248" { f.tbr = 4000 }; return f }
            try expectEqual(try unwrap(FormatSelector.choose(info: far, mode: .bestForApple, maxHeight: 1080)).video?.id, "248", "VP9 wins when H.264 is far behind")
            // Picture height: portrait by its short side, letterboxed films by their width.
            try expectEqual(FormatSelector.pictureHeight(of: vf("p", 1080, 1920)), 1080)
            try expectEqual(FormatSelector.pictureHeight(of: vf("l", 1920, 800)), 1080)
            try expectEqual(FormatSelector.pictureHeight(of: vf("w", 3840, 1600)), 2160)
            try expectEqual(FormatSelector.pictureHeight(of: vf("o", 1280, 718)), 720, "718 snaps to the 720 step")
        }

        test("formats: Universal stays at 1080p or below with H.264 and AAC, whatever the page offers", oracles: ["dl.mode.selector"]) {
            let k8 = try DownloaderFixtures.info("video-8k-hdr.json")
            let uni = try unwrap(FormatSelector.choose(info: k8, mode: .universal, maxHeight: nil))
            try expectEqual(uni.video?.id, "299"); try expectEqual(uni.audio?.id, "140")
            try expectEqual(uni.video?.codecFamily, .h264); try expect(uni.video?.isHDR == false, "Universal never takes HDR")
            try expectEqual(uni.selector, "299+140/bv*[height<=1080][vcodec^=avc]+ba[acodec^=mp4a]/bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b")
            try expectEqual(try unwrap(FormatSelector.choose(info: k8, mode: .universal, maxHeight: 2160)).video?.id, "299", "a higher cap does not lift the 1080p ceiling")
            try expect(FormatSelector.expression(for: .universal, maxHeight: 2160).contains("height<=1080"))
            try expect(FormatSelector.expression(for: .universal, maxHeight: 720).contains("height<=720"))
            // H.264 is preferred even when VP9 has a higher bitrate at that height.
            var v = try DownloaderFixtures.info("video.json")
            v.formats = v.formats.map { var f = $0; if f.id == "248" { f.tbr = 9000 }; return f }
            try expectEqual(try unwrap(FormatSelector.choose(info: v, mode: .universal, maxHeight: nil)).video?.id, "137")
        }

        test("formats: audio modes take the AAC stream unless Opus is clearly better; generic expressions are golden", oracles: ["dl.mode.selector", "dl.audio.format"]) {
            let v = try DownloaderFixtures.info("video.json")
            let m4a = try unwrap(FormatSelector.choose(info: v, mode: .audioM4A, maxHeight: nil))
            try expectEqual(m4a.audio?.id, "140"); try expectEqual(m4a.selector, "140/ba[ext=m4a]/ba/b"); try expect(m4a.video == nil)
            let mp3 = try unwrap(FormatSelector.choose(info: v, mode: .audioMP3, maxHeight: nil))
            try expectEqual(mp3.audio?.id, "251", "MP3 is encoded from the best source, whatever its codec")
            try expectEqual(mp3.selector, "251/ba/b")
            var better = v
            better.formats = better.formats.map { var f = $0; if f.id == "251" { f.tbr = 200 }; return f }
            try expectEqual(try unwrap(FormatSelector.choose(info: better, mode: .audioM4A, maxHeight: nil)).audio?.id, "251", "Opus at 200 kbit/s is clearly better than AAC at 129")
            // Several dubbed languages: the page's original wins.
            var dubbed = v
            var ru = dubbed.formats.first { $0.id == "140" }!; ru.id = "140-ru"; ru.language = "ru"; ru.tbr = 129.5
            var orig = dubbed.formats.first { $0.id == "140" }!; orig.note = "medium, original (default)"
            dubbed.formats = dubbed.formats.filter { $0.id != "140" } + [ru, orig]
            try expectEqual(try unwrap(FormatSelector.choose(info: dubbed, mode: .audioM4A, maxHeight: nil)).audio?.id, "140", "the original track, not the dub")
            try expectEqual(FormatSelector.expression(for: .bestForApple, maxHeight: nil), "bv*+ba/b")
            try expectEqual(FormatSelector.expression(for: .maximum, maxHeight: 0), "bv*+ba/b")
            try expectEqual(FormatSelector.expression(for: .bestForApple, maxHeight: 1440), "bv*[height<=1440]+ba/b[height<=1440]/bv*+ba/b")
            try expectEqual(FormatSelector.expression(for: .audioM4A, maxHeight: nil), "ba[ext=m4a]/ba/b")
            try expectEqual(FormatSelector.expression(for: .audioMP3, maxHeight: 720), "ba/b")
            try expectEqual(FormatSelector.singleFileSelector(info: nil, maxHeight: nil), "b")
            try expectEqual(FormatSelector.singleFileSelector(info: nil, maxHeight: 720), "b[height<=720]/b")
            try expectEqual(FormatSelector.singleFileSelector(info: v, maxHeight: nil), "18/b", "without ffmpeg only a stream that already has sound can be used")
            let audioPage = try DownloaderFixtures.info("audio-only.json")
            try expectEqual(try unwrap(FormatSelector.choose(info: audioPage, mode: .audioM4A, maxHeight: nil)).audio?.id, "http_mp3")
            try expectEqual(FormatSelector.choose(info: audioPage, mode: .bestForApple, maxHeight: nil)?.selector, nil, "a page with no picture offers no video choice: the generic expression is used")
        }
    }

    // MARK: Argument lists

    static func registerArguments() {
        let url = URL(string: "https://www.youtube.com/watch?v=abc123XYZ_-")!
        let dir = URL(fileURLWithPath: "/tmp/out dir/Ünï", isDirectory: true)
        func base(_ change: (inout DownloadRequest) -> Void = { _ in }) -> DownloadRequest {
            var r = DownloadRequest(url: url, outputDirectory: dir)
            change(&r)
            return r
        }

        test("argv: a plain download is an array with the URL last after --, confined to the folder, resumable, without any optional flag") {
            let a = try YtDlpArguments.downloadArguments(base(), ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(Array(a.suffix(2)), ["--", url.absoluteString], "the URL is the last element, after --")
            try expectEqual(argValue(a, "--progress-template"), YtDlpProgressParser.template)
            for flag in ["--newline", "--no-overwrites", "--continue", "--ignore-config", "--no-playlist", "--embed-metadata", "--embed-chapters", "--embed-thumbnail"] {
                try expect(a.contains(flag), "\(flag) expected")
            }
            try expectEqual(argValues(a, "-P"), ["home:/tmp/out dir/Ünï", "temp:/tmp/out dir/Ünï"], "folder names with spaces and non-ASCII letters travel as one element")
            try expectEqual(argValue(a, "-o"), "%(title).150B [%(id)s].%(ext)s")
            try expectEqual(argValue(a, "-f"), "bv*+ba/b"); try expectEqual(argValue(a, "--merge-output-format"), "mp4/mkv")
            try expect(argValue(a, "--cache-dir")?.hasSuffix("yt-dlp-cache") == true, "yt-dlp's cache lives in the app's folder")
            for flag in ["--cookies-from-browser", "--limit-rate", "--download-sections", "--write-subs", "--ffmpeg-location", "--js-runtimes", "-x", "--playlist-items", "--yes-playlist", "--print-to-file", "--embed-subs"] {
                try expect(!a.contains(flag), "\(flag) must not appear unless it was asked for")
            }
            try expect(a.allSatisfy { !$0.contains("\n") }, "no element carries a newline")
        }

        test("argv: a hostile address stays one element after --; unsafe addresses, templates and folders throw", oracles: ["dl.template.output"]) {
            let weird = URL(string: "https://example.com/watch?v=--no-check-certificate&x=;rm%20-rf")!
            let a = try YtDlpArguments.downloadArguments(base { $0.url = weird }, ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(a.last, weird.absoluteString); try expectEqual(a[a.count - 2], "--")
            try expectEqual(a.filter { $0 == "--no-check-certificate" }.count, 0, "an option-looking value inside the address never becomes an option")
            for bad in ["file:///etc/passwd", "javascript:alert(1)", "http://localhost/x", "ftp://example.com/a"] {
                do { _ = try YtDlpArguments.downloadArguments(base { $0.url = URL(string: bad)! }, ffmpegDirectory: nil, jsRuntime: nil); throw TestFailure(message: "\(bad) accepted", file: #fileID, line: #line) }
                catch is TestFailure { throw TestFailure(message: "\(bad) accepted", file: #fileID, line: #line) } catch {}
            }
            for bad in ["../x.%(ext)s", "/abs/%(title)s.%(ext)s", "~/a.%(ext)s", "a/../b.%(ext)s", "", "   ", "a\\b.%(ext)s", "dir/", "x\u{0}y", "./a.%(ext)s"] {
                try expect(!YtDlpArguments.isSafeTemplate(bad), "template \"\(bad)\" must be refused")
                do { _ = try YtDlpArguments.downloadArguments(base { $0.filenameTemplate = bad }, ffmpegDirectory: nil, jsRuntime: nil); throw TestFailure(message: "template \(bad) accepted", file: #fileID, line: #line) }
                catch is TestFailure { throw TestFailure(message: "template \(bad) accepted", file: #fileID, line: #line) } catch {}
            }
            for ok in ["%(title)s [%(id)s].%(ext)s", "%(uploader)s/%(title)s.%(ext)s", "%(playlist_index)02d - %(title).100B.%(ext)s", "-dash first.%(ext)s"] {
                try expect(YtDlpArguments.isSafeTemplate(ok), "template \"\(ok)\" is fine")
            }
            for bad in [URL(fileURLWithPath: "/tmp/$HOME/x"), URL(string: "https://example.com/x")!, URL(string: "relative/dir")!] {
                do { _ = try YtDlpArguments.downloadArguments(base { $0.outputDirectory = bad }, ffmpegDirectory: nil, jsRuntime: nil); throw TestFailure(message: "folder \(bad) accepted", file: #fileID, line: #line) }
                catch is TestFailure { throw TestFailure(message: "folder \(bad) accepted", file: #fileID, line: #line) } catch {}
            }
        }

        test("argv: tools and network options appear only when chosen", oracles: ["dl.cookies.only-when-chosen", "dl.rate.limit", "dl.fragments.parallel"]) {
            let node = JSRuntime(kind: .node, url: URL(fileURLWithPath: "/opt/homebrew/bin/node"), version: nil)
            let plain = try YtDlpArguments.downloadArguments(base(), ffmpegDirectory: URL(fileURLWithPath: "/opt/homebrew/bin"), jsRuntime: node)
            try expectEqual(argValue(plain, "--ffmpeg-location"), "/opt/homebrew/bin")
            try expectEqual(argValue(plain, "--js-runtimes"), "node:/opt/homebrew/bin/node")
            try expect(!plain.contains("--cookies-from-browser") && !plain.contains("--limit-rate"), "cookies and a speed limit only when chosen")
            try expect(!plain.contains("--concurrent-fragments"), "one part at a time is yt-dlp's own default: no flag")
            let parallel = try YtDlpArguments.downloadArguments(base { $0.concurrentFragments = 4 }, ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(argValue(parallel, "--concurrent-fragments"), "4")
            let capped = try YtDlpArguments.downloadArguments(base { $0.concurrentFragments = 99 }, ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(argValue(capped, "--concurrent-fragments"), "8", "never more than eight parts at once")
            let old = try YtDlpArguments.downloadArguments(base(), ffmpegDirectory: nil, jsRuntime: node, supportsJSRuntimes: false)
            try expect(!old.contains("--js-runtimes"), "an older yt-dlp without the option is not given it")
            let chosen = try YtDlpArguments.downloadArguments(base { $0.cookies = .safari; $0.rateLimitKBps = 500 }, ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(argValue(chosen, "--cookies-from-browser"), "safari"); try expectEqual(argValue(chosen, "--limit-rate"), "500K")
            for b in CookieBrowser.allCases where b != .none {
                try expectEqual(argValue(try YtDlpArguments.downloadArguments(base { $0.cookies = b }, ffmpegDirectory: nil, jsRuntime: nil), "--cookies-from-browser"), b.rawValue)
            }
            let list = try YtDlpArguments.downloadArguments(base { $0.resultListFile = URL(fileURLWithPath: "/tmp/a%b.txt") }, ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(argValue(list, "--print-to-file"), "after_move:filepath")
            try expectEqual(list[list.firstIndex(of: "--print-to-file")! + 2], "/tmp/a%%b.txt", "a percent sign in the path cannot start a yt-dlp field")
            let work = try YtDlpArguments.downloadArguments(base { $0.workDirectory = URL(fileURLWithPath: "/tmp/out dir/.swampdl-1/tmp") }, ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(argValues(work, "-P").last, "temp:/tmp/out dir/.swampdl-1/tmp", "partial files live in the hidden work folder")
        }

        test("argv: audio modes extract with the chosen format and quality", oracles: ["dl.audio.format", "dl.audio.quality", "dl.mode.selector"]) {
            let mp3 = try YtDlpArguments.downloadArguments(base { $0.mode = .audioMP3; $0.audioQuality = 320 }, ffmpegDirectory: nil, jsRuntime: nil)
            try expect(mp3.contains("-x")); try expectEqual(argValue(mp3, "--audio-format"), "mp3"); try expectEqual(argValue(mp3, "--audio-quality"), "320K")
            try expectEqual(argValue(mp3, "-f"), "ba/b"); try expect(!mp3.contains("--merge-output-format"), "no video merge for sound")
            let opus = try YtDlpArguments.downloadArguments(base { $0.mode = .audioM4A; $0.audioFormat = .opus }, ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(argValue(opus, "--audio-format"), "opus"); try expectEqual(argValue(opus, "--audio-quality"), "0", "0 means the best variable quality")
            let flac = try YtDlpArguments.downloadArguments(base { $0.mode = .audioM4A; $0.audioFormat = .flac }, ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(argValue(flac, "--audio-format"), "flac")
            let m4a = try YtDlpArguments.downloadArguments(base { $0.mode = .audioM4A }, ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(argValue(m4a, "--audio-format"), "m4a"); try expectEqual(argValue(m4a, "-f"), "ba[ext=m4a]/ba/b")
            let explicit = try YtDlpArguments.downloadArguments(base { $0.formatSelector = "313+140/bv*+ba/b" }, ffmpegDirectory: nil, jsRuntime: nil)
            try expectEqual(argValue(explicit, "-f"), "313+140/bv*+ba/b", "the chosen ids reach yt-dlp")
        }

        test("argv: subtitles, sections, metadata, thumbnail and playlist options", oracles: ["dl.subs.mode", "dl.subs.langs", "dl.section.range", "dl.embed.flags", "dl.playlist.items"]) {
            let soft = try YtDlpArguments.downloadArguments(base { $0.subtitles = .soft; $0.subtitleLanguages = ["ru", "en", "bad lang;", "-x", "pt-BR", "*"] }, ffmpegDirectory: nil, jsRuntime: nil)
            try expect(soft.contains("--write-subs") && soft.contains("--write-auto-subs") && soft.contains("--embed-subs"))
            try expectEqual(argValue(soft, "--sub-langs"), "ru,en,pt-BR,*", "unsafe language codes are dropped")
            let ext = try YtDlpArguments.downloadArguments(base { $0.subtitles = .external }, ffmpegDirectory: nil, jsRuntime: nil)
            try expect(ext.contains("--write-subs") && !ext.contains("--embed-subs")); try expectEqual(argValue(ext, "--convert-subs"), "srt"); try expectEqual(argValue(ext, "--sub-langs"), "en", "no language chosen: English")
            let burn = try YtDlpArguments.downloadArguments(base { $0.subtitles = .burn }, ffmpegDirectory: nil, jsRuntime: nil)
            try expect(!burn.contains("--embed-subs") && burn.contains("--write-subs"), "burn-in downloads the .srt and the convert stage draws it")
            try expect(!(try YtDlpArguments.downloadArguments(base(), ffmpegDirectory: nil, jsRuntime: nil)).contains("--write-subs"))
            func sec(_ s: Double?, _ e: Double?) throws -> String? {
                argValue(try YtDlpArguments.downloadArguments(base { $0.sectionStart = s; $0.sectionEnd = e }, ffmpegDirectory: nil, jsRuntime: nil), "--download-sections")
            }
            try expectEqual(try sec(10, 20.5), "*10-20.500"); try expectEqual(try sec(nil, 30), "*0-30"); try expectEqual(try sec(90, nil), "*90-inf"); try expectEqual(try sec(60, 30), "*60-60")
            let bare = try YtDlpArguments.downloadArguments(base { $0.embedMetadata = false; $0.embedThumbnail = false }, ffmpegDirectory: nil, jsRuntime: nil)
            for f in ["--embed-metadata", "--embed-chapters", "--embed-thumbnail", "--convert-thumbnails"] { try expect(!bare.contains(f), "\(f) off") }
            let all = try YtDlpArguments.downloadArguments(base { $0.playlistItems = "" }, ffmpegDirectory: nil, jsRuntime: nil)
            try expect(all.contains("--yes-playlist") && !all.contains("--playlist-items") && !all.contains("--no-playlist"))
            let some = try YtDlpArguments.downloadArguments(base { $0.playlistItems = "1,3,5-7" }, ffmpegDirectory: nil, jsRuntime: nil)
            try expect(some.contains("--yes-playlist")); try expectEqual(argValue(some, "--playlist-items"), "1,3,5-7")
            for bad in ["1;rm", "a", "--exec", "1 2", String(repeating: "1,", count: 150)] {
                do { _ = try YtDlpArguments.downloadArguments(base { $0.playlistItems = bad }, ffmpegDirectory: nil, jsRuntime: nil); throw TestFailure(message: "items \(bad) accepted", file: #fileID, line: #line) }
                catch is TestFailure { throw TestFailure(message: "items \(bad) accepted", file: #fileID, line: #line) } catch {}
            }
            try expect(YtDlpArguments.isSafePlaylistItems("2-") && YtDlpArguments.isSafePlaylistItems("-3") && YtDlpArguments.isSafePlaylistItems("::2") == false, "slices")
        }

        test("argv: the information request is an array too, with the list and cookie options only when asked for") {
            let a = YtDlpArguments.infoArguments(url: url, flatPlaylist: false, cookies: .none, jsRuntime: nil)
            try expectEqual(Array(a.suffix(2)), ["--", url.absoluteString]); try expect(a.contains("-J") && a.contains("--no-playlist") && a.contains("--ignore-config"))
            try expect(!a.contains("--flat-playlist") && !a.contains("--cookies-from-browser") && !a.contains("--js-runtimes"))
            let node = JSRuntime(kind: .bun, url: URL(fileURLWithPath: "/opt/homebrew/bin/bun"), version: nil)
            let b = YtDlpArguments.infoArguments(url: url, flatPlaylist: true, cookies: .firefox, jsRuntime: node, wholePlaylist: true)
            try expect(b.contains("--yes-playlist") && !b.contains("--no-playlist") && b.contains("--flat-playlist"))
            try expectEqual(argValue(b, "--cookies-from-browser"), "firefox"); try expectEqual(argValue(b, "--js-runtimes"), "bun:/opt/homebrew/bin/bun")
        }
    }
}
