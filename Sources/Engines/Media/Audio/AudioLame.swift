import Foundation

// MP3 through the `lame` command-line encoder, for Macs that have lame but an ffmpeg without libmp3lame (or no ffmpeg at all).
// The native route does the signal work and writes a float32 WAV; lame encodes it.

enum AudLameArgs {
    /// lame accepts text frames in UTF-16 with `--id3v2-utf16`, which keeps Cyrillic titles intact (ID3v2.3).
    static func arguments(plan: AudPlan, tags: AudTags, cover: URL?, input: URL, output: URL) -> [String] {
        var a: [String] = ["--noreplaygain"]
        if plan.useQuality { a += ["-V", String(AudQuality.mp3V(plan.quality))] }
        else if plan.fitBytes != nil { a += ["--abr", String(plan.kbps)] }
        else { a += ["-b", String(plan.kbps), "--cbr"] }
        a += ["-m", plan.mp3Joint ? "j" : "s"]
        if !tags.isEmpty || cover != nil {
            a += ["--add-id3v2", "--id3v2-utf16"]
            if !tags.title.isEmpty { a += ["--tt", tags.title] }
            if !tags.artist.isEmpty { a += ["--ta", tags.artist] }
            if !tags.album.isEmpty { a += ["--tl", tags.album] }
            if !tags.year.isEmpty { a += ["--ty", tags.year] }
            if !tags.comment.isEmpty { a += ["--tc", tags.comment] }
            if !tags.track.isEmpty { a += ["--tn", tags.trackText] }
            if !tags.genre.isEmpty { a += ["--tg", tags.genre] }
            if !tags.albumArtist.isEmpty { a += ["--tv", "TPE2=\(tags.albumArtist)"] }
            if !tags.composer.isEmpty { a += ["--tv", "TCOM=\(tags.composer)"] }
            if !tags.disc.isEmpty { a += ["--tv", "TPOS=\(tags.disc)"] }
            if let cover { a += ["--ti", cover.path] }
        }
        a += [input.path, output.path]
        return a
    }

    /// `( 62%)` in lame's progress lines.
    static func parsePercent(_ line: String) -> Double? {
        guard let close = line.firstIndex(of: "%"), let open = line[..<close].lastIndex(where: { $0 == "(" || $0 == " " }) else { return nil }
        return Double(line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)).map { $0 / 100 }
    }
}
