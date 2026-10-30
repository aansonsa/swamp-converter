import Foundation

/// Stable option keys of the `subs.convert` schema (spec/handbrake.md 3.5). Adding keys is free; renaming or removing breaks presets.
enum SubsKeys {
    static let format = "subs.format"            // srt, vtt, ass, ssa, sbv, txt
    static let encodingIn = "subs.enc.in"        // auto, utf-8, utf-16, windows-1251, windows-1257, windows-1250, windows-1252, koi8-r, cp866
    static let encodingOut = "subs.enc.out"      // utf-8, utf-16, windows-1251, ...
    static let bom = "subs.bom"                  // byte order mark for UTF-8 results (UTF-16 always has one)
    static let offset = "subs.offset"            // seconds, may be negative
    static let fpsFrom = "subs.fps.from"         // off, 23.976, 24, 25, 29.97, 30, ...
    static let fpsTo = "subs.fps.to"
    static let removeTags = "subs.tags"
    static let removeSDH = "subs.sdh"            // [music], (laughs) ...
    static let mergeShort = "subs.merge"
    static let txtJoin = "subs.txt.join"         // cue (one line per cue), paragraphs

    // Added after the first release of the keys.
    static let eol = "subs.eol"                  // auto (CRLF for SRT, LF otherwise), lf, crlf
    static let overlap = "subs.overlap"          // trim cues that overlap the next one
    static let mergeMin = "subs.merge.min"       // seconds: cues shorter than this are merge candidates
}
