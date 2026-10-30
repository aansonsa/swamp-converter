import Foundation

/// Stable option keys of the video schemas (spec/handbrake.md 2.2-2.11; the video schema uses the spec's FLAT key names).
/// Adding keys is free; renaming or removing one breaks stored presets and quick recipes (report it).
enum VideoKeys {
    // Format
    static let container = "container"          // same, mp4, mov, mkv, webm, avi, gif, mp3 (audio only)
    static let faststart = "faststart"
    static let appleTag = "appleTag"
    static let alignAV = "alignAV"
    // Video
    static let vcodec = "vcodec"                // copy, h264, hevc, av1, vp9, prores, vp8, mpeg4, ffv1, dnxhr
    static let venc = "venc"                    // auto, hardware, software
    static let bitdepth = "bitdepth"            // auto, 8, 10, 12
    static let chroma = "chroma"                // 4:2:0, 4:2:2, 4:4:4
    static let rateControl = "rc"               // cq, abr, size, lossless
    static let cq = "cq"                        // software scale: CRF (lower = better); also mpeg4 / vp8 through a documented mapping
    static let cqHardware = "cq.hw"             // VideoToolbox quality 0...100 (higher = better)
    static let vbitrate = "vbitrate"
    static let targetMB = "targetMB"
    static let sizeLadder = "sizeLadder"
    static let twoPass = "twopass"
    static let turbo1 = "turbo1"
    static let vbvMaxrate = "vbv.maxrate"
    static let vbvBuffer = "vbv.buf"
    static let speed = "speed"                  // ultrafast ... veryslow (mapped to SVT-AV1 presets / VP9 cpu-used)
    static let tune = "tune"
    static let profile = "profile"
    static let level = "level"
    static let keyint = "keyint"
    static let bframes = "bframes"
    static let refs = "refs"
    static let filmgrain = "filmgrain"
    static let extra = "extra"
    static let hdr = "hdr"                      // keep, sdr, ignore
    static let colorspace = "colorspace"
    static let colorRange = "range"
    // Picture
    static let rotate = "rotate"                // 0, 90, 180, 270 clockwise
    static let flipH = "flipH"
    static let flipV = "flipV"
    static let respectMeta = "respectMeta"
    static let cropMode = "crop.mode"           // none, auto, custom
    static let cropTop = "crop.t"
    static let cropBottom = "crop.b"
    static let cropLeft = "crop.l"
    static let cropRight = "crop.r"
    static let sizeMode = "size.mode"           // source, limit, exact, percent, fill, fit
    static let sizeLimit = "size.limit"         // "720p", "1080p" ...
    static let sizeW = "size.w"
    static let sizeH = "size.h"
    static let sizePercent = "size.percent"
    static let sizeUpscale = "size.upscale"
    static let sizeAnchor = "size.anchor"
    static let sizeModulus = "size.modulus"
    static let sizeScaler = "size.scaler"
    static let sizePar = "size.par"
    static let padMode = "pad.mode"             // none, bars, border, blur
    static let padColor = "pad.color"
    static let padTop = "pad.t"
    static let padBottom = "pad.b"
    static let padLeft = "pad.l"
    static let padRight = "pad.r"
    static let fpsMode = "fps.mode"             // source, peak, constant
    static let fps = "fps"
    static let fpsInterp = "fps.interp"
    // Filters
    static let deinterlace = "f.deint"          // off, auto, on
    static let deintMethod = "f.deint.method"
    static let deintRate = "f.deint.rate"
    static let ivtc = "f.ivtc"
    static let deblock = "f.deblock"
    static let denoise = "f.denoise"
    static let denoiseMethod = "f.denoise.method"
    static let chromaSmooth = "f.chroma"
    static let deband = "f.deband"
    static let sharpen = "f.sharpen"
    static let sharpenMethod = "f.sharpen.method"
    static let gray = "f.gray"
    static let eqBrightness = "f.eq.brightness"
    static let eqContrast = "f.eq.contrast"
    static let eqSaturation = "f.eq.saturation"
    static let eqGamma = "f.eq.gamma"
    static let colorTemp = "f.temp"
    static let filterSpeed = "f.speed"          // playback speed factor, audio keeps pitch
    static let reverse = "f.reverse"
    static let fadeIn = "f.fade.in"
    static let fadeOut = "f.fade.out"
    static let wmMode = "f.wm.mode"             // none, image, text
    static let wmFile = "f.wm.file"
    static let wmText = "f.wm.text"
    static let wmPos = "f.wm.pos"
    static let wmOpacity = "f.wm.opacity"
    static let wmScale = "f.wm.scale"
    static let wmMargin = "f.wm.margin"
    static let stabilize = "f.stab"
    // Audio
    static let audioMode = "a.mode"             // all, first, languages, none
    static let audioLangs = "a.langs"
    static let audioLangFallback = "a.langs.fallback"
    static let audioCodec = "a.codec"
    static let audioSecond = "a.second"
    static let audioPassMask = "a.passmask"
    static let audioFallback = "a.fallback"
    static let audioRC = "a.rc"
    static let audioBitrate = "a.bitrate"
    static let audioQuality = "a.quality"
    static let audioMixdown = "a.mixdown"
    static let audioRate = "a.rate"
    static let audioGain = "a.gain"
    static let audioDRC = "a.drc"
    static let audioComp = "a.comp"
    static let audioNorm = "a.norm"
    static let audioNormLUFS = "a.norm.lufs"
    static let audioName = "a.name"
    static let audioLang = "a.lang"
    static let audioTracks = "a.tracks"         // `tracks` field: per-track source / codec / bitrate / mixdown / rate / gain / name
    // Subtitles
    static let subMode = "s.mode"               // none, keep, burn, external
    static let subLangs = "s.langs"
    static let subForcedOnly = "s.forcedOnly"
    static let subDefault = "s.default"
    static let burnTrack = "s.burn.track"
    static let burnFont = "s.burn.font"
    static let burnSize = "s.burn.size"
    static let burnColor = "s.burn.color"
    static let burnOutlineColor = "s.burn.outline.color"
    static let burnOutline = "s.burn.outline"
    static let burnShadow = "s.burn.shadow"
    static let burnBox = "s.burn.box"
    static let burnBoxOpacity = "s.burn.box.opacity"
    static let burnPos = "s.burn.pos"
    static let burnMargin = "s.burn.margin"
    static let extFile = "s.ext.file"
    static let extOffset = "s.ext.offset"
    static let extCharset = "s.ext.charset"
    static let extLang = "s.ext.lang"
    // Chapters and tags
    static let chapterMode = "ch.mode"
    static let chapterInterval = "ch.auto.interval"
    static let chapterRows = "ch.rows"
    static let metadataMode = "md.mode"
    static let metadataNoGPS = "md.noGPS"
    static let mdTitle = "md.title"
    static let mdArtist = "md.artist"
    static let mdAlbum = "md.album"
    static let mdYear = "md.year"
    static let mdGenre = "md.genre"
    static let mdComment = "md.comment"
    static let mdDescription = "md.description"
    static let mdCopyright = "md.copyright"
    static let mdLanguage = "md.language"
    static let mdCover = "md.cover"
    static let mdKeepDates = "md.keepDates"
    // Range
    static let trimStart = "t.start"            // time field (seconds), asked on the quick path by video.trim
    static let trimEnd = "t.end"                // absolute end; empty = until the end
    static let trimAccurate = "t.accurate"
    // GIF
    static let gifFps = "gif.fps"
    static let gifWidth = "gif.width"
    static let gifColors = "gif.colors"
    static let gifDither = "gif.dither"
    static let gifLoop = "gif.loop"
    // video.frames (thumbnail)
    static let frameMode = "frame.mode"         // best, at, every, scene, sheet
    static let frameTime = "frame.time"
    static let frameEvery = "frame.every"
    static let frameCount = "frame.count"
    static let frameFormat = "frame.format"     // png, jpg
    static let frameWidth = "frame.width"
    static let frameSceneThreshold = "frame.scene"
}
