import Foundation

enum IntelligenceTests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("intelligence", "operations appear for the right kinds and nothing in this module needs the network") {
            let reg = OperationRegistry()
            reg.register(IntelligenceCatalog.operations())
            let img = [FileItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .tools, items: img).map(\.id), ["image.removebg", "scrub.image"])
            let vid = [FileItem(url: URL(fileURLWithPath: "/tmp/a.mp4"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .tools, items: vid).map(\.id), ["speech.transcribe", "scrub.video"])
            let aud = [FileItem(url: URL(fileURLWithPath: "/tmp/a.m4a"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .tools, items: aud).map(\.id), ["speech.transcribe", "scrub.audio"])
            let pdf = [FileItem(url: URL(fileURLWithPath: "/tmp/a.pdf"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .tools, items: pdf).map(\.id), ["scrub.pdf"])
            try expect(reg.allOperations().allSatisfy { !$0.meta.usesNetwork }, "no operation of this module may use the network")
            try expect(reg.allOperations().allSatisfy { $0.meta.wheel == .tools }, "all of them live on the Tools wheel")
        }
        t.register("intelligence", "registering the Speech and Vision features runs none of their checks: no framework call, no model or language lookup happens before the first use") {
            let ids = ["native.speech.available", "native.vision.foreground"] + SpeechCapabilities.candidateLanguages.map { "native.speech.lang.\($0)" }
            Capabilities.shared.invalidate()
            SpeechCapabilities.register(); VisionCapabilities.register()
            for id in ids { try expect(!Capabilities.shared.isEvaluated(id), "\(id) was evaluated while registering") }
            // Listing the Tools wheel for a video, an audio file and a picture never touches Speech (the language assets are looked up when a transcript is asked for).
            // Only the picture wheel reads Vision's revision list, a plain class property that decides whether "Remove background" is offered.
            let reg = OperationRegistry()
            reg.register(IntelligenceCatalog.operations())
            for name in ["a.mp4", "a.m4a"] { _ = reg.entries(wheel: .tools, items: [FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), isDirectory: false)]) }
            for id in ids { try expect(!Capabilities.shared.isEvaluated(id), "\(id) was evaluated while the audio and video wheels were being listed") }
            _ = reg.entries(wheel: .tools, items: [FileItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false)])
            for id in ids where id.hasPrefix("native.speech") { try expect(!Capabilities.shared.isEvaluated(id), "\(id) was evaluated while the picture wheel was being listed") }
        }
        IntelligenceScrubTests.register()
        IntelligenceScrubMediaTests.register()
        IntelligenceSpeechTests.register()
        IntelligenceVisionTests.register()
        IntelligenceClipboardTests.register()
        IntelligenceConformance.register()
    }
}
