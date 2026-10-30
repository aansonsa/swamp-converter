import Foundation

// Typed ffmpeg command line. Arguments are ALWAYS an array (never a shell string). Every module that needs ffmpeg builds a
// command with this type and runs it with `FFmpegRunner` (FFmpegRunner.swift), so progress, cancellation, pause and
// partial-output cleanup behave identically. Golden-argv tests (spec/handbrake.md 5.4 "two kinds of test") assert on `arguments()`.

struct FFmpegInput: Sendable {
    var url: URL
    /// Options placed BEFORE this `-i` (`-ss`, `-t`, `-f lavfi`, `-framerate` ...).
    var options: [String] = []
}

struct FFmpegOutput: Sendable {
    /// The hidden `.part` path handed out by `ctx.produceFile` (real extension last).
    var url: URL
    /// Options placed before the output path (`-map`, `-c:v`, `-b:v`, `-movflags` ...).
    var options: [String] = []
}

struct FFmpegCommand: Sendable {
    var inputs: [FFmpegInput] = []
    var outputs: [FFmpegOutput] = []
    /// Global options after the fixed prefix `-hide_banner -nostdin -y -nostats -progress pipe:1`.
    var global: [String] = []
    var videoFilters: [String] = []
    var audioFilters: [String] = []
    var filterComplex: String? = nil

    /// The fixed prefix of every command.
    static let prefix = ["-hide_banner", "-nostdin", "-y", "-nostats", "-progress", "pipe:1"]

    /// The complete argv (without the executable): prefix, global options, per input its options and `-i`, then
    /// `-filter_complex` or `-vf`, `-af` (joined with commas; they apply to the first output), then each output's options and path.
    /// Frame-rate handling must be explicit through `-fps_mode` in the options (`-vsync` no longer exists in this ffmpeg).
    func arguments() -> [String] {
        var a = Self.prefix + global
        for i in inputs {
            a += i.options
            a += ["-i", Self.safePath(i.url)]
        }
        if let fc = filterComplex, !fc.isEmpty {
            a += ["-filter_complex", fc]
        } else if !videoFilters.isEmpty {
            a += ["-vf", videoFilters.joined(separator: ",")]
        }
        if !audioFilters.isEmpty { a += ["-af", audioFilters.joined(separator: ",")] }
        for o in outputs {
            a += o.options
            a.append(Self.safePath(o.url))
        }
        return a
    }

    /// A path that can never be mistaken for an option: relative names starting with "-" get a "./" prefix.
    static func safePath(_ url: URL) -> String {
        let p = url.path
        return p.hasPrefix("-") ? "./" + p : p
    }

    /// Display form for the job log ("Copy Command" in the Studio): quotes arguments with spaces. Never executed.
    func displayString(executable: String = "ffmpeg") -> String {
        ([executable] + arguments()).map { $0.contains(" ") || $0.contains("[") || $0.contains("'") ? "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" : $0 }.joined(separator: " ")
    }
}
