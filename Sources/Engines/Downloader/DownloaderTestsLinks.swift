import Foundation

// Tests: link validation (LinkParsing is what the downloader trusts), info JSON parsing, friendly messages.

extension DownloaderTests {
    // MARK: Links

    static func registerLinks() {
        test("links: trailing punctuation and brackets, several links, short links, tracking parameters") {
            let text = "Watch https://youtu.be/abc123XYZ_-?si=track, then (https://www.youtube.com/watch?v=abc123XYZ_-&utm_source=x&t=30s) and "
                + "https://en.wikipedia.org/wiki/Swamp_(film). Also www.example.com/v!"
            let found = LinkParsing.downloadableLinks(in: text)
            try expectEqual(found.count, 3, "the two spellings of one video count once")
            try expectEqual(found[0].url.absoluteString, "https://youtu.be/abc123XYZ_-", "tracking parameter si removed, comma trimmed")
            try expectEqual(found[1].url.absoluteString, "https://en.wikipedia.org/wiki/Swamp_(film)", "a balanced bracket stays, the full stop goes")
            try expectEqual(found[2].url.absoluteString, "https://www.example.com/v", "a bare www address gets https, the exclamation mark goes")
            try expectEqual(LinkParsing.canonicalKey(of: URL(string: "https://youtu.be/abc123XYZ_-")!),
                            LinkParsing.canonicalKey(of: URL(string: "https://www.youtube.com/watch?v=abc123XYZ_-&feature=share")!), "same video, same key")
            try expectEqual(LinkParsing.canonicalKey(of: URL(string: "https://m.youtube.com/shorts/abc123XYZ_-")!), "youtube:abc123XYZ_-")
            guard case .success(let kept) = LinkParsing.validate("https://www.youtube.com/watch?v=abc&t=30s&utm_source=x&fbclid=1") else { throw TestFailure(message: "valid link rejected", file: #fileID, line: #line) }
            try expectEqual(kept.absoluteString, "https://www.youtube.com/watch?v=abc&t=30s", "the start time is part of the link, tracking is not")
        }

        test("links: javascript, file, data, ftp, credentials, private hosts and junk are rejected") {
            let bad = ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "ftp://example.com/a", "ssh://host.example.com", "http://localhost/x",
                       "http://127.0.0.1:8080/x", "http://192.168.1.5/a", "http://10.0.0.2/a", "http://user:pw@example.com/a", "https://intranet/a", "", "   ", "not a url",
                       "http://[::1]/x", "swampconverter://download?url=x"]
            for s in bad {
                if case .success(let u) = LinkParsing.validate(s) { throw TestFailure(message: "\"\(s)\" must be rejected but gave \(u)", file: #fileID, line: #line) }
            }
            if case .failure(let r) = LinkParsing.validate("javascript:alert(1)") { try expectEqual(r, .unsupportedScheme("javascript")) }
            if case .failure(let r) = LinkParsing.validate("file:///etc/passwd") { try expectEqual(r, .unsupportedScheme("file")) }
            if case .failure(let r) = LinkParsing.validate("http://user:pw@example.com/a") { try expectEqual(r, .credentialsInURL) }
            // Free text with one bad and one good link: the good one is found, the bad one never reaches the list.
            let mixed = LinkParsing.downloadableLinks(in: "javascript:alert(1) http://localhost/a https://example.com/ok")
            try expectEqual(mixed.map(\.url.absoluteString), ["https://example.com/ok"])
            guard case .success(let long) = LinkParsing.validate("https://example.com/" + String(repeating: "a", count: 100)) else { throw TestFailure(message: "long link", file: #fileID, line: #line) }
            try expect(long.absoluteString.count < LinkParsing.maxLength)
            if case .success = LinkParsing.validate("https://example.com/" + String(repeating: "a", count: 2100)) { throw TestFailure(message: "over-long link accepted", file: #fileID, line: #line) }
        }

        test("links: the swampconverter:// scheme carries a link and a mode, and rejects what the downloader would") {
            let url = try unwrap(DownloadURLScheme.make(link: URL(string: "https://www.youtube.com/watch?v=abc&t=3")!, mode: .audioMP3))
            guard case .success(let req) = DownloadURLScheme.parse(url) else { throw TestFailure(message: "own URL not parsed", file: #fileID, line: #line) }
            try expectEqual(req.mode, .audioMP3)
            try expectEqual(req.link.url.absoluteString, "https://www.youtube.com/watch?v=abc&t=3", "the nested link survives encoding")
            let evil = URL(string: "swampconverter://download?url=file%3A%2F%2F%2Fetc%2Fpasswd&mode=best")!
            if case .success = DownloadURLScheme.parse(evil) { throw TestFailure(message: "file: link accepted through the scheme", file: #fileID, line: #line) }
            try expectEqual(DownloadMode(parameter: "nonsense"), nil)
        }
    }

    // MARK: Info JSON

    static func registerInfo() {
        test("info JSON: a normal video (formats, chapters, subtitles, thumbnail, unicode title)") {
            let info = try DownloaderFixtures.info("video.json")
            try expectEqual(info.title, "Болото / Swamp: Part 1")
            try expectEqual(info.id, "abc123XYZ_-")
            try expectEqual(info.channel, "Swamp Films")
            try expectEqual(info.duration, 612)
            try expectEqual(info.extractor, "Youtube")
            try expect(!info.isLive && !info.isPlaylist)
            try expectEqual(info.thumbnail?.lastPathComponent, "maxresdefault.jpg", "the best thumbnail (last of the list) is used")
            try expectEqual(info.formats.count, 15, "the storyboard is not a downloadable format")
            try expect(!info.formats.contains { $0.id == "sb0" })
            try expectEqual(info.chapters.map(\.title), ["Intro", "The marsh"])
            try expectClose(info.chapters[0].end, 120.5)
            try expectEqual(info.subtitles.filter { !$0.isAutomatic }.map(\.language), ["en", "ru"], "live chat is not a subtitle track")
            try expectEqual(info.subtitles.filter(\.isAutomatic).map(\.language), ["en-orig", "lv"])
            func f(_ id: String) throws -> DownloadFormat { try unwrap(info.formats.first { $0.id == id }, "format \(id)") }
            try expectEqual(try f("137").codecFamily, .h264); try expect(try f("137").isVideoOnly)
            try expectEqual(try f("248").codecFamily, .vp9); try expectEqual(try f("399").codecFamily, .av1)
            try expect(try f("140").isAudioOnly); try expect(try f("18").vcodec != "none" && f("18").acodec != "none")
            try expectEqual(try f("137").bytes, 190_000_000); try expectEqual(try f("18").bytes, 36_000_000, "the approximate size is used when the exact one is missing")
            try expectEqual(try f("140").language, "en")
        }

        test("info JSON: 8K HDR, a live stream, an audio-only page") {
            let k8 = try DownloaderFixtures.info("video-8k-hdr.json")
            try expectEqual(k8.formats.compactMap(\.height).max(), 4320)
            try expectEqual(Set(k8.formats.filter(\.isHDR).map(\.id)), ["334", "702"])
            try expect(!k8.isLive)
            let live = try DownloaderFixtures.info("live.json")
            try expect(live.isLive, "a running live stream is flagged")
            try expectEqual(live.duration, nil)
            let audio = try DownloaderFixtures.info("audio-only.json")
            try expectEqual(audio.formats.count, 2)
            try expect(audio.formats.allSatisfy(\.isAudioOnly))
            try expectEqual(audio.webpageURL.host, "soundcloud.com")
        }

        test("info JSON: a playlist keeps numbering around an unavailable entry; an empty one is still a list") {
            let list = try DownloaderFixtures.info("playlist.json")
            try expect(list.isPlaylist && list.formats.isEmpty)
            try expectEqual(list.entries.map(\.id), ["pl_one", "pl_two", "pl_three"], "the null entry is skipped")
            try expectEqual(list.entries.map(\.index), [1, 3, 4], "numbering counts the unavailable video")
            try expectEqual(list.entries.map(\.title), ["First swamp", "Second swamp", "pl_three"], "a missing title falls back to the id")
            try expectEqual(list.entries[0].url?.absoluteString, "https://www.youtube.com/watch?v=pl_one")
            try expectEqual(list.entries.map(\.channel), ["Swamp Films", "Swamp Films", "Swamp Films"], "the list's uploader is the fallback channel")
            try expectEqual(list.entries[1].duration, 125.5)
            let empty = try DownloaderFixtures.info("playlist-empty.json")
            try expect(empty.isPlaylist && empty.entries.isEmpty, "an empty list is a list, not a video")
        }

        test("info JSON: garbage fails calmly, leading warnings are tolerated, direct files and numeric ids work") {
            for junk in ["", "ERROR: Unsupported URL: https://example.com", "<html>nope</html>", "[1,2,3]"] {
                do { _ = try YtDlpInfoParser.parse(json: Data(junk.utf8)); throw TestFailure(message: "\"\(junk)\" parsed", file: #fileID, line: #line) }
                catch is TestFailure { throw TestFailure(message: "\"\(junk)\" parsed", file: #fileID, line: #line) }
                catch { try expect(!ConversionError.describe(error).isEmpty, "a calm message") }
            }
            let ok = String(data: try DownloaderFixtures.data("audio-only.json"), encoding: .utf8)!
            let withWarning = try YtDlpInfoParser.parse(json: Data(("WARNING: [generic] something\n" + ok).utf8))
            try expectEqual(withWarning.id, "snd_one")
            let direct = try YtDlpInfoParser.parse(json: Data(#"{"id": 12345, "title": "clip", "webpage_url": "https://example.com/a.mp4", "url": "https://cdn.example.com/a.mp4", "ext": "mp4", "height": 720, "width": 1280}"#.utf8))
            try expectEqual(direct.id, "12345", "a numeric id becomes text")
            try expectEqual(direct.formats.count, 1, "a page that is one direct file still has one format")
            try expectEqual(direct.formats[0].height, 720)
            // A hostile page cannot smuggle a non-web thumbnail or page address through.
            let hostile = try YtDlpInfoParser.parse(json: Data(#"{"id": "x", "title": "t", "webpage_url": "https://example.com/a", "thumbnail": "file:///etc/passwd", "formats": []}"#.utf8))
            try expectEqual(hostile.thumbnail, nil)
        }
    }

    // MARK: Messages

    static func registerMessages() {
        test("friendly messages: every failure of yt-dlp becomes a calm sentence with the right advice") {
            func msg(_ stderr: String) -> String { YtDlpInfoParser.friendlyMessage(forStderr: stderr).en }
            func has(_ stderr: String, _ needles: String...) throws {
                let m = msg(stderr)
                for n in needles { try expect(m.localizedCaseInsensitiveContains(n), "\"\(m)\" should mention \"\(n)\" for: \(stderr.prefix(70))") }
            }
            try has("ERROR: [youtube] abc: Private video. Sign in if you've been granted access to this video", "private", "Cookies")
            try has("ERROR: Unsupported URL: https://example.com/page", "no video on this page")
            try has("ERROR: [youtube] abc: Sign in to confirm you're not a bot. Use --cookies-from-browser or --cookies for the authentication.", "sign in", "Cookies")
            try has("ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.", "age-restricted", "Cookies")
            try has("ERROR: [youtube] abc: The uploader has not made this video available in your country", "not available in your country")
            try has("ERROR: [generic] This video is DRM protected", "DRM", "can’t be downloaded")
            try has("ERROR: [youtube] abc: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided, or not known>", "Could not reach the site", "internet")
            try has("ERROR: [generic] Unable to download webpage: HTTP Error 404: Not Found", "not available any more")
            try has("ERROR: [youtube] abc: Premieres in 2 hours", "not started yet")
            try has("ERROR: HTTP Error 429: Too Many Requests", "limiting requests")
            try has("ERROR: unable to download video data: HTTP Error 403: Forbidden", "403", "Cookies")
            try has("ERROR: ffmpeg not found. Please install or provide the path using --ffmpeg-location", "ffmpeg", "brew install ffmpeg")
            try has("ERROR: [Errno 28] No space left on device", "disk is full")
            try has("yt-dlp: error: no such option: --js-runtimes", "too old")
            try has("WARNING: [youtube] abc: n challenge solving failed: no supported JavaScript runtime could be found\nERROR: [youtube] abc: Requested format is not available. Use --list-formats", "JavaScript", "deno")
            try has("ERROR: [youtube] abc: Requested format is not available. Use --list-formats for a list of available formats", "chosen quality is not available")
            try has("ERROR: [foo] 123: Something odd happened", "The site reported: Something odd happened")
            try expectEqual(msg(""), "The link could not be downloaded.")
            // DRM: the app says it cannot be done and offers nothing that gets around it.
            let drm = YtDlpInfoParser.friendlyMessage(forStderr: "ERROR: [generic] This video is DRM protected")
            for word in ["bypass", "circumvent", "crack", "workaround", "remove the protection"] {
                try expect(!drm.en.localizedCaseInsensitiveContains(word), "the DRM message must not suggest \(word)")
            }
            // Both languages exist for every message.
            for s in ["ERROR: Unsupported URL: x", "ERROR: Private video", "ERROR: HTTP Error 429", "ERROR: [x] y: odd", "ERROR: This video is DRM protected"] {
                let m = YtDlpInfoParser.friendlyMessage(forStderr: s)
                try expect(!m.ru.isEmpty && m.ru != m.en, "a Russian text for: \(s)")
            }
            let long = YtDlpInfoParser.friendlyMessage(forStderr: "ERROR: [foo] 1: " + String(repeating: "x", count: 600)).en
            try expect(long.count < 300, "unknown messages are shortened")
        }
    }
}
