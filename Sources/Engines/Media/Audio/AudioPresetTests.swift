import Foundation

// Every built-in preset is a recipe someone will press: it must run and produce the file it names, with the sound it claims.

enum AudioPresetTests {
    static func register() {
        SelfTestRegistry.shared.register("audio.presets", "every built-in preset runs end to end and writes what its name says", timeout: 240) {
            let fx = TestFixtures(label: "aud-presets"); defer { fx.cleanup() }
            let (src, ref) = try AudioNativeTests.source(fx, "voice.wav", seconds: 4, rate: 44_100, channels: 2)
            let env = AudEnvironment.current()
            let op = try AudTestKit.operation("audio.to.m4a")
            var ran = 0, skipped: [String] = []
            for preset in AudioPresets.builtins {
                let target = AudTarget(rawValue: preset.values.string(AudioKeys.target, "aac")) ?? .aac
                if target.isConcrete, !env.canEncode(target) { skipped.append(preset.id); continue }
                let tag = preset.id.replacingOccurrences(of: "builtin.", with: "")
                let input = fx.url("\(tag).wav")
                try FileManager.default.copyItem(at: src, to: input)
                let result = try await AudTestKit.run(op, [input], preset.values)
                let out = try unwrap(result.outputs.first, preset.id)
                let sniffed = try unwrap(FormatSniffer.sniff(out), preset.id)
                let wanted: Set<String>
                switch target {
                case .same, .auto: wanted = ["wav"]
                case .m4r, .m4b: wanted = ["m4a", "mp4"]      // ringtones and audiobooks are M4A files under another extension
                default: wanted = FormatSniffer.acceptableSniffs(forExtension: target.fileExtension)
                }
                try expect(wanted.contains(sniffed.key), "\(preset.id): wrote \(sniffed) for target \(target.rawValue)")
                if target.fileExtension.isEmpty == false { try expectEqual(out.pathExtension, target.fileExtension, preset.id) }
                // Decodable, and the right length unless the preset trims or speeds up.
                let back = try unwrap(AudTestKit.decode(out, in: fx.root), "\(preset.id) does not decode")
                let trims = preset.values.has(AudioKeys.trimEnd) || preset.values.has(AudioKeys.trimStart) || preset.values.has(AudioKeys.speed)
                if !trims { try expectClose(back.seconds, ref.seconds, tolerance: 0.08, "\(preset.id) length") }
                if let rate = Int(preset.values.string(AudioKeys.sampleRate, "")), target != .opus { try expectEqual(back.rate, rate, "\(preset.id) sample rate") }
                switch preset.values.string(AudioKeys.channels, "keep") { case "mono": try expectEqual(back.channels, 1, preset.id); case "stereo": try expectEqual(back.channels, 2, preset.id); default: break }
                if target == .wav || target == .flac {
                    let bits = preset.values.string(AudioKeys.bitDepth, "keep")
                    if let fp = AudTestKit.probe(out), bits == "24" { try expect(fp.codec.contains("24") || fp.bitsPerSample == 24, "\(preset.id): \(fp.codec) \(fp.bitsPerSample)") }
                }
                ran += 1
            }
            try expect(ran >= AudioPresets.builtins.count - 4, "only \(ran) of \(AudioPresets.builtins.count) presets could run; skipped \(skipped)")
            AudTestKit.debug("\(ran) presets ran, skipped for missing encoders: \(skipped)")
        }
    }
}
