import Foundation
import AVFoundation
import CoreMedia

// AVFoundation back end of MediaProbe (no ffprobe needed): mp4, mov, m4a, mp3, wav, flac, aiff, caf, Ogg-Opus.
// It cannot open mkv / webm / avi / wmv / gif (spec/backends.md fact 4); those need ffprobe.

extension MediaProbe {
    static func probeWithAVFoundation(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let readable = try? await asset.load(.isReadable), readable else { return nil }
        guard let tracks = try? await asset.load(.tracks) else { return nil }
        let durationTime = (try? await asset.load(.duration)) ?? .invalid
        var info = MediaInfo(url: url, container: Formats.key(of: url))
        info.formatName = "avfoundation"
        info.viaFFprobe = false
        if durationTime.isNumeric, durationTime.seconds.isFinite, durationTime.seconds > 0 { info.duration = durationTime.seconds }
        info.size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        if let s = info.size, let d = info.duration, d > 0 { info.bitRate = Int(Double(s) * 8 / d) }

        for (i, track) in tracks.enumerated() {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let fourCC = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            let language = (try? await track.load(.languageCode)).flatMap { $0 == "und" ? nil : $0 }
            let rate = (try? await track.load(.estimatedDataRate)).flatMap { $0 > 0 ? Int($0) : nil }
            switch track.mediaType {
            case .video:
                var st = MediaStreamInfo(kind: .video, index: i, codec: codecName(video: fourCC))
                let size = (try? await track.load(.naturalSize)) ?? .zero
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                st.width = Int(abs(size.width)); st.height = Int(abs(size.height))
                // preferredTransform describes how to rotate the stored picture for display.
                let angle = atan2(Double(transform.b), Double(transform.a)) * 180 / .pi
                var rot = Int(angle.rounded()) % 360
                if rot < 0 { rot += 360 }
                st.rotation = [0, 90, 180, 270].min(by: { abs($0 - rot) < abs($1 - rot) }) ?? 0
                if let fps = try? await track.load(.nominalFrameRate), fps > 0 { st.fps = Double(fps); st.maxFps = Double(fps) }
                st.bitRate = rate
                st.language = language
                st.codecTag = fourCCString(fourCC)
                if let fd = formats.first {
                    let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any]
                    let depth = ext?["BitsPerComponent"] as? Int
                    st.bitDepth = depth ?? 8
                    let tf = ext?["CVImageBufferTransferFunction"] as? String
                    if let tf { st.colorTransfer = tf.contains("2084") ? "smpte2084" : (tf.contains("HLG") ? "arib-std-b67" : nil) }
                    st.isHDR = st.colorTransfer != nil
                    if let prim = ext?["CVImageBufferColorPrimaries"] as? String, prim.contains("2020") { st.colorPrimaries = "bt2020" }
                }
                info.streams.append(st)
            case .audio:
                var st = MediaStreamInfo(kind: .audio, index: i, codec: codecName(audio: fourCC))
                if let fd = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                    st.sampleRate = Int(asbd.mSampleRate)
                    st.channels = Int(asbd.mChannelsPerFrame)
                    if asbd.mBitsPerChannel > 0 { st.bitDepth = Int(asbd.mBitsPerChannel) }
                }
                st.bitRate = rate
                st.language = language
                st.codecTag = fourCCString(fourCC)
                info.streams.append(st)
            case .subtitle, .closedCaption, .text:
                var st = MediaStreamInfo(kind: .subtitle, index: i, codec: fourCC == 0x74783367 ? "mov_text" : fourCCString(fourCC))
                st.language = language
                info.streams.append(st)
            default:
                info.streams.append(MediaStreamInfo(kind: .data, index: i, codec: fourCCString(fourCC)))
            }
        }
        // Chapters (first chapter locale only).
        if let locales = try? await asset.load(.availableChapterLocales), let loc = locales.first,
           let groups = try? await asset.loadChapterMetadataGroups(withTitleLocale: loc, containingItemsWithCommonKeys: []) {
            for g in groups {
                let title = (try? await g.items.first?.load(.stringValue)) ?? ""
                let a = g.timeRange.start.seconds, b = g.timeRange.end.seconds
                if a.isFinite && b.isFinite { info.chapters.append(MediaChapterInfo(start: a, end: b, title: title)) }
            }
        }
        if info.streams.isEmpty && info.duration == nil { return nil }
        return info
    }

    static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let s = String(bytes: bytes, encoding: .macOSRoman) ?? "????"
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// FourCC of a video sample description -> the ffprobe-style codec name.
    static func codecName(video code: FourCharCode) -> String {
        switch fourCCString(code) {
        case "avc1", "avc3": return "h264"
        case "hvc1", "hev1": return "hevc"
        case "av01": return "av1"
        case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": return "prores"
        case "mp4v": return "mpeg4"
        case "jpeg", "mjpa": return "mjpeg"
        case "vp09": return "vp9"
        default: return fourCCString(code).lowercased()
        }
    }

    static func codecName(audio code: FourCharCode) -> String {
        switch fourCCString(code) {
        case "mp4a": return "aac"
        case "alac": return "alac"
        case "lpcm", "sowt", "twos", "in24", "in32", "fl32": return "pcm_s16le"
        case ".mp3", "mp3": return "mp3"
        case "ac-3": return "ac3"
        case "ec-3": return "eac3"
        case "fLaC", "flac": return "flac"
        case "Opus", "opus": return "opus"
        default: return fourCCString(code).lowercased()
        }
    }
}
