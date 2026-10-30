import Foundation

/// Stable option keys of the audio schemas (spec/handbrake.md 3.2). Adding keys is free; renaming/removing breaks presets.
enum AudioKeys {
    // Format
    static let target = "aud.target"            // auto, same, mp3, aac, alac, flac, wav, aiff, caf, opus, ogg, ac3, eac3, m4b, m4r
    static let rateControl = "aud.rc"           // bitrate, quality
    static let bitrate = "aud.bitrate"          // kbit/s, 0 = automatic
    static let quality = "aud.quality"          // 0...100 (mapped onto each encoder's own VBR scale)
    static let aacProfile = "aud.aac.profile"   // lc, he, hev2
    static let sampleRate = "aud.rate"          // keep or Hz
    static let bitDepth = "aud.bits"            // keep, 16, 24, 32f
    static let channels = "aud.channels"        // keep, mono, stereo
    static let dither = "aud.dither"            // none, rectangular, triangular (applied when the depth is reduced to 16 bits)
    static let flacLevel = "aud.flac.level"     // 0...12
    static let opusApp = "aud.opus.app"         // audio, voip, lowdelay
    static let opusVBR = "aud.opus.vbr"         // on, constrained, off
    static let mp3Joint = "aud.mp3.joint"
    static let mp3ID3 = "aud.mp3.id3"           // v2.3, v2.4
    static let fitMB = "aud.fit.mb"             // fit the result under N MB (0 = off)
    // Sound
    static let gain = "aud.gain"                // dB
    static let normalize = "aud.norm"           // off, peak, ebu, podcast, streaming, custom
    static let normLUFS = "aud.norm.lufs"
    static let normTP = "aud.norm.tp"
    static let normLRA = "aud.norm.lra"
    static let normTwoPass = "aud.norm.twopass"
    static let limiter = "aud.limiter"
    static let silence = "aud.silence"
    static let silenceDB = "aud.silence.db"
    static let highpass = "aud.hp"              // Hz, 0 = off
    static let eq = "aud.eq"                    // flat, bass, treble, voice
    static let fadeIn = "aud.fade.in"
    static let fadeOut = "aud.fade.out"
    static let speed = "aud.speed"
    // Range
    static let trimStart = "aud.t.start"        // time field, seconds; asked on the quick path by audio.trim
    static let trimEnd = "aud.t.end"            // time field, absolute end, empty = until the end
    static let trimMode = "aud.t.mode"          // accurate, copy
    // Tags and artwork
    static let tagsMode = "aud.tags.mode"       // keep, strip, custom
    static let tagTitle = "aud.tags.title"
    static let tagArtist = "aud.tags.artist"
    static let tagAlbum = "aud.tags.album"
    static let tagAlbumArtist = "aud.tags.albumArtist"
    static let tagYear = "aud.tags.year"
    static let tagTrack = "aud.tags.track"
    static let tagTrackTotal = "aud.tags.trackTotal"
    static let tagDisc = "aud.tags.disc"
    static let tagGenre = "aud.tags.genre"
    static let tagComposer = "aud.tags.composer"
    static let tagComment = "aud.tags.comment"
    static let coverMode = "aud.cover.mode"     // keep, remove, replace, extract
    static let coverFile = "aud.cover.file"
    static let coverMax = "aud.cover.max"       // 0 = original, else longest side in px
    // audio.join
    static let joinRate = "audjoin.rate"        // auto (best input) or Hz
    static let joinChannels = "audjoin.channels" // auto (best input), mono, stereo
    static let joinOrder = "audjoin.order"      // natural, selection
    static let joinGap = "audjoin.gap"          // seconds of silence between files
    static let joinCrossfade = "audjoin.crossfade" // seconds

    /// All text-tag keys with the canonical tag name they edit.
    static let tagFields: [(key: String, name: String)] = [
        (tagTitle, "title"), (tagArtist, "artist"), (tagAlbum, "album"), (tagAlbumArtist, "albumArtist"), (tagYear, "year"),
        (tagTrack, "track"), (tagTrackTotal, "trackTotal"), (tagDisc, "disc"), (tagGenre, "genre"), (tagComposer, "composer"), (tagComment, "comment")
    ]
}
