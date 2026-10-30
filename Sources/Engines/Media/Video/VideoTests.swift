import Foundation

enum VideoTests {
    static func register() {
        let t = SelfTestRegistry.shared
        // Structural acceptance (spec/wheel.md 11.6): single MP4 -> Convert [MOV, MKV, WEBM, GIF, MP3]; Tools Compress, 720p, Mute, Trim, Rotate, Speed up, Thumbnail.
        t.register("video", "wheel contents for MP4 files follow the catalogue order") {
            let reg = OperationRegistry()
            reg.register(VideoCatalog.operations())
            let one = [FileItem(url: URL(fileURLWithPath: "/tmp/a.mp4"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: one).map(\.id), ["video.to.mov", "video.to.mkv", "video.to.webm", "video.to.gif", "video.to.mp3"])
            try expectEqual(reg.entries(wheel: .tools, items: one).map(\.id), ["video.compress", "video.720p", "video.mute", "video.trim", "video.rotate", "video.speed2", "video.thumbnail"])
            let gif = [FileItem(url: URL(fileURLWithPath: "/tmp/a.gif"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: gif).map(\.id), ["gif.to.mp4", "gif.to.webm"])
            let trim = try unwrap(reg.operation(id: "video.trim"))
            try expectEqual(trim.meta.quickPromptKeys, [VideoKeys.trimStart, VideoKeys.trimEnd])
        }
        VideoRealTests.register()
        VideoSchemaTests.register()
        VideoGoldenTests.register()
        VideoJoinTests.register()
        VideoMuteTests.register()
    }
}
