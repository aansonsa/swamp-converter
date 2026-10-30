import Foundation

enum AudioTests {
    static func register() {
        let t = SelfTestRegistry.shared
        // Structural acceptance (spec/wheel.md 11.6): single MP3 -> Convert [M4A, WAV, FLAC, OGG, OPUS, AIFF]; Tools Compress, Normalize, Trim (+ Join for 2+).
        t.register("audio", "wheel contents for MP3 files follow the catalogue order") {
            let reg = OperationRegistry()
            reg.register(AudioCatalog.operations())
            let one = [FileItem(url: URL(fileURLWithPath: "/tmp/a.mp3"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: one).map(\.id), ["audio.to.m4a", "audio.to.wav", "audio.to.flac", "audio.to.ogg", "audio.to.opus", "audio.to.aiff"])
            try expectEqual(reg.entries(wheel: .tools, items: one).map(\.id), ["audio.compress", "audio.normalize", "audio.trim"])
            let two = one + [FileItem(url: URL(fileURLWithPath: "/tmp/b.wav"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .tools, items: two).map(\.id).last, "audio.concat")
            let trim = try unwrap(reg.operation(id: "audio.trim"))
            try expectEqual(trim.meta.quickPromptKeys, [AudioKeys.trimStart, AudioKeys.trimEnd])
        }
        // AUDIO OWNER: per-option oracle tests (spec/backends.md 8.2 "Video/audio", 11 join target) and cancellation tests go here.
    }
}
