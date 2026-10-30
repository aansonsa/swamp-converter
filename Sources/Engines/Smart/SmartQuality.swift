import Foundation

/// The documented, measured quality targets. "Visually transparent" here means: the transcode is indistinguishable from its (already lossy)
/// source at normal viewing (SSIM above 0.99 and PSNR above 44 dB against the source, frame by frame) and about as large as that source.
///
/// MEASURED with ffmpeg 9.0.1 on Apple silicon (the numbers are also re-measured by SmartTests "quality targets"; both streams are aligned frame by
/// frame with `setpts=N/FRAME_RATE/TB` and compared as 10-bit 4:2:0). Source A: 1280x720, 30 fps, 4 s, testsrc2 with strong temporal noise,
/// VP9 CRF 32 (2063 kB, 4.1 Mbit/s: a hard clip, grain costs bits). Source B: 3840x2160, 30 fps, 2 s, testsrc2 with mild noise, x264 CRF 20 (6759 kB).
///
///     A  hevc_videotoolbox 8-bit  -q:v 40 ->  423 kB  SSIM 0.9748  PSNR 37.3 dB
///                                 -q:v 50 ->  849 kB  SSIM 0.9841  PSNR 39.6 dB
///                                 -q:v 60 -> 1759 kB  SSIM 0.9931  PSNR 44.0 dB
///                                 -q:v 65 -> 2133 kB  SSIM 0.9945  PSNR 45.5 dB   <- target up to 1080p (about the size of the VP9 source)
///                                 -q:v 70 -> 2751 kB  SSIM 0.9961  PSNR 47.9 dB
///                                 -q:v 75 -> 3217 kB  SSIM 0.9968  PSNR 49.4 dB
///     A  hevc_videotoolbox 10-bit -q:v 65 -> 3440 kB  SSIM 0.9973  PSNR 50.1 dB   (the same q costs 1.6x the bits in 10-bit: not used)
///                                 -q:v 59 -> about 2650 kB  SSIM 0.9958           <- 10-bit target (8-bit target minus 6 points)
///                                 -q:v 55 -> 2348 kB  SSIM 0.9950  PSNR 46.2 dB
///     A  libx265 medium           CRF 24 -> 1713 kB  SSIM 0.9935  PSNR 44.2 dB
///                                 CRF 22 -> 2046 kB  SSIM 0.9948  PSNR 45.7 dB
///                                 CRF 20 -> 2469 kB  SSIM 0.9960  PSNR 47.2 dB   <- software target (10-bit: same CRF, 2493 kB)
///                                 CRF 18 -> 2992 kB  SSIM 0.9972  PSNR 48.9 dB
///     A  libx265 slow CRF 18      -> 3049 kB  SSIM 0.9977  PSNR 50.5 dB           <- "maximum quality (slow)"
///     A  h264_videotoolbox        -q:v 60 -> 1819 kB  SSIM 0.9937   -q:v 70 -> 2885 kB  SSIM 0.9964  PSNR 48.3 dB   <- hardware universal target
///                                 -q:v 80 -> 4232 kB  SSIM 0.9982
///     A  libx264 medium           CRF 20 -> 2519 kB  SSIM 0.9954   CRF 18 -> 3026 kB  SSIM 0.9965  PSNR 48.0 dB   <- universal target
///                                 CRF 16 -> 3576 kB  SSIM 0.9974
///     B  hevc_videotoolbox 8-bit  -q:v 50 -> 2285 kB  SSIM 0.9890   -q:v 55 -> 4679 kB  SSIM 0.9946  PSNR 44.3 dB
///                                 -q:v 60 -> 5791 kB  SSIM 0.9964  PSNR 45.9 dB   <- 4K target (86% of the x264 source)
///                                 -q:v 65 -> 7100 kB  SSIM 0.9974
///     B  hevc_videotoolbox 10-bit -q:v 50 -> 5146 kB  SSIM 0.9954  (= 4K 8-bit target minus 6 points = 54)
///
/// Larger pictures need fewer bits per pixel for the same look, so the targets relax slightly with height. `minimumSSIM` is the floor the
/// self-tests assert on freshly generated clips; the real targets sit far above it.
enum SmartQuality {
    /// hevc_videotoolbox `-q:v` (0...100, higher is better): 65 up to 1080p, 62 for 1440p, 60 for 4K, 56 for 8K. 10-bit is six points lower: the same
    /// value costs about 1.6 times the bits in 10-bit, six points give the same size and (slightly better) SSIM as the 8-bit target.
    static func hevcHardwareQuality(height: Int, tenBit: Bool) -> Double {
        let base: Double
        switch height {
        case ...1100: base = 65
        case ...1500: base = 62
        case ...2200: base = 60
        default: base = 56
        }
        return tenBit ? base - 6 : base
    }

    /// libx265 CRF (lower is better): 20 up to 1080p, 21 for 1440p / 4K, 22 above. `slow` is the "maximum quality (slow)" preset: two steps lower.
    static func hevcSoftwareCRF(height: Int, tenBit: Bool, slow: Bool = false) -> Double {
        let base: Double
        switch height {
        case ...1100: base = 20
        case ...2200: base = 21
        default: base = 22
        }
        return slow ? base - 2 : base
    }

    /// libx264 CRF for the universal mode (always at most 1080p): 18.
    static func h264CRF(height: Int) -> Double { height <= 1100 ? 18 : 19 }

    /// h264_videotoolbox `-q:v` for the universal mode when the hardware encoder is preferred: 70.
    static func h264HardwareQuality(height: Int) -> Double { 70 }

    /// Minimum acceptable SSIM of a transcode against its source (asserted by the self-test on a generated clip).
    static let minimumSSIM = 0.97

    /// `smart.q.offset` steps applied to a target: one step is 2 points on the 0...100 hardware scale and 1 CRF step on x264 / x265.
    static func hardware(_ base: Double, offset: Int) -> Double { Util.clamp(base + Double(offset) * 2, 1, 100) }
    static func software(_ base: Double, offset: Int) -> Double { Util.clamp(base - Double(offset), 0, 51) }

    /// Rough size of a transcode relative to the source video bitrate, by source codec (HEVC at the targets above vs the source):
    /// VP9 about equal, AV1 needs a little more, MPEG-2 / MPEG-4 / VC-1 / H.264 need much less.
    static func sizeFactor(sourceCodec: String) -> Double {
        switch sourceCodec {
        case "vp9", "vp8": return 1.0
        case "av1": return 1.25
        case "h264": return 0.75
        case "mpeg2", "mpeg1": return 0.45
        case "mpeg4", "vc1", "theora": return 0.6
        case "prores", "dnxhd", "mjpeg", "ffv1", "rawvideo": return 0.12
        default: return 0.8
        }
    }
}
