import Foundation

/// Stable option keys of the archive schemas (spec/handbrake.md 3.7). Adding keys is free; renaming or removing breaks presets.
enum ArchiveKeys {
    static let format = "arc.format"             // zip, tar, tar.gz, tar.bz2, tar.xz, tar.zst, 7z
    static let level = "arc.level"               // 0 (store) ... 9
    static let excludeHidden = "arc.exclude.hidden"   // pack: leave out Mac system files (.DS_Store, ._*, __MACOSX ...); extract: skip them
    static let excludePatterns = "arc.exclude.patterns"
    static let rootFolder = "arc.root"           // keep / add / strip the top folder
    static let keepDates = "arc.dates"           // pack: keep modification dates (off = fixed 1980 date); extract: restore them
    static let nameEncoding = "arc.names"        // auto, utf-8, cp866, cp1251, cp437 (zip extract)
    static let extractTo = "arc.extract.to"      // smart (one entry out as is, several in a folder), folder (always a folder), here (entries next to the archive)
    static let flatten = "arc.flatten"
    static let overwrite = "arc.overwrite"       // number, skip, replace: names that exist when entries are extracted "here"
    static let deleteAfter = "arc.trashAfter"    // move the archive to the Trash after a successful extract

    // Added after the first release of the keys.
    static let includeHidden = "arc.hidden"      // pack: include files whose name starts with a dot
    static let permissions = "arc.perms"         // extract: restore the permission bits (executable files stay executable)
    static let normalise = "arc.nfc"             // pack: Unicode-normalise names (NFC) so Windows shows accents and umlauts correctly
    static let verify = "arc.verify"             // pack: read the archive back and check it before it is saved
}
