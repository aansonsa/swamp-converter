import Foundation
import CryptoKit

// The explicit install / update of yt-dlp and the pure helpers around it (checksums, SHA-256, version comparison).
//
//   install():  NetworkGate.authorize(.installYtDlp) -> latest tag (optional) -> SHA2-256SUMS -> yt-dlp_macos -> SHA-256 check ->
//               copy next to the destination as a hidden .part -> clear com.apple.quarantine -> chmod 755 -> atomic rename -> refresh().
//   A checksum mismatch, a failed download or any other error leaves NO file in the tools folder (the old copy, if any, stays untouched).

extension YtDlpToolManager {
    // MARK: Install and update

    /// THE explicit install (the "Install yt-dlp" button). Progress 0...1 for the sheet. Throws calm `ConversionError.message` texts.
    func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try NetworkGate.authorize(.installYtDlp, host: "github.com")
        let tag = try? await latestTag()
        try await installVerified(tag: tag, progress: progress)
    }

    /// The "Update" button: asks for the latest version (the redirect of `releases/latest`), installs it the same verified way when newer.
    /// Only for a yt-dlp that lives in `installURL`; a Homebrew or PATH copy is updated by its owner (say so).
    func update(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> YtDlpUpdateOutcome {
        guard let current = status.url else {
            throw ConversionError.message(L10n("yt-dlp is not installed yet. Use Install first.", "yt-dlp ещё не установлен. Сначала нажмите «Установить»."))
        }
        guard current.resolvingSymlinksInPath().standardizedFileURL.path == Self.installURL.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ConversionError.message(L10n("This copy of yt-dlp is managed outside the app. Update it where you installed it, for example: brew upgrade yt-dlp.",
                                               "Эта копия yt-dlp управляется вне приложения. Обновите её там, где устанавливали, например: brew upgrade yt-dlp."))
        }
        try NetworkGate.authorize(.updateCheckYtDlp, host: "github.com")
        let latest = try await latestTag()
        let installed = await installedVersion()
        if let installed, !Self.isNewer(latest, than: installed) { return .alreadyLatest(version: installed) }
        try await installVerified(tag: latest, progress: progress)
        return .updated(from: installed, to: latest)
    }

    /// The optional check on use (setting `downloader.checkForUpdates`, OFF by default, at most once a day, never user-initiated).
    /// Returns the newer version string, or nil (nothing newer, switched off, checked today, offline, no consent).
    func checkForUpdateIfDue(now: Date = Date()) async -> String? {
        let s = NetworkGate.settingsProvider().downloader
        guard s.checkForUpdates, status.isInstalled, now.timeIntervalSince1970 - s.lastUpdateCheck >= 86_400 else { return nil }
        do { try NetworkGate.authorize(.updateCheckYtDlp, host: "github.com", userInitiated: false) } catch { return nil }
        AppSettings.shared.update { $0.downloader.lastUpdateCheck = now.timeIntervalSince1970 }
        guard let latest = try? await latestTag(), let installed = await installedVersion() else { return nil }
        return Self.isNewer(latest, than: installed) ? latest : nil
    }

    /// "2026.10.20" from the redirect of `releases/latest`.
    func latestTag() async throws -> String {
        let final = try await http.finalURL(of: Self.latestReleaseURL)
        let comps = final.pathComponents
        if let i = comps.lastIndex(of: "tag"), i + 1 < comps.count, Self.isValidTag(comps[i + 1]) { return comps[i + 1] }
        throw ConversionError.message(L10n("Could not find out the latest yt-dlp version. Try again later.", "Не удалось узнать последнюю версию yt-dlp. Повторите позже."))
    }

    private func installVerified(tag: String?, progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = tag.map { "https://github.com/yt-dlp/yt-dlp/releases/download/\($0)/" }
        let assetURL = base.flatMap { URL(string: $0 + Self.assetName) } ?? Self.assetURL
        let sumsURL = base.flatMap { URL(string: $0 + "SHA2-256SUMS") } ?? Self.checksumsURL

        let work = AppPaths.makeTempDirectory(purpose: "ytdlp-install")
        defer { AppPaths.removeTemp(work) }
        progress(0.02)
        let sumsData = try await http.data(from: sumsURL)
        let checksums = Self.parseChecksums(String(decoding: sumsData, as: UTF8.self))
        guard checksums[Self.assetName] != nil else {
            throw ConversionError.message(L10n("The release has no checksum for yt-dlp, so nothing was installed.", "В релизе нет контрольной суммы для yt-dlp, поэтому ничего не установлено."))
        }
        let downloaded = work.appendingPathComponent(Self.assetName)
        try await http.download(from: assetURL, to: downloaded) { progress(0.05 + 0.85 * $0) }
        try Task.checkCancellation()
        guard try Self.verify(file: downloaded, name: Self.assetName, checksums: checksums) else {
            throw ConversionError.message(L10n("The file did not match its checksum and was not installed.", "Файл не совпал с контрольной суммой и не был установлен."))
        }
        progress(0.92)
        try Self.place(verified: downloaded, at: Self.installURL)
        progress(1)
        refresh()
        // Remember what was checked (only reached when the checksum matched), so Settings can say so at any time.
        var verifiedVersion = tag ?? ""
        if verifiedVersion.isEmpty { verifiedVersion = await installedVersion() ?? "" }
        let verifiedHash = checksums[Self.assetName] ?? ""
        AppSettings.shared.update { $0.downloader.verifiedInstall = DownloaderSettings.VerifiedInstall(version: verifiedVersion, sha256: verifiedHash, date: Date().timeIntervalSince1970) }
    }

    /// Is the yt-dlp inside the app's own folder still byte for byte the file whose checksum was verified at install time? nil when there is nothing to compare (no record, or the
    /// copy in use is managed elsewhere). The hash is streamed off the main thread.
    func installedMatchesVerifiedRecord() async -> Bool? {
        guard let record = AppSettings.shared.data.downloader.verifiedInstall, status.source == .userFolder else { return nil }
        let url = Self.installURL
        return await Task.detached(priority: .utility) { (try? Self.sha256(of: url)) == record.sha256 }.value
    }

    /// Copies a verified file next to its destination as a hidden `.part`, clears quarantine, sets 755 and renames it into place.
    /// An existing destination is replaced atomically (the old file is never removed first). Any error leaves no `.part` behind.
    nonisolated static func place(verified file: URL, at destination: URL) throws {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent(".\(destination.lastPathComponent).\(Util.hex8()).part")
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: file, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        clearQuarantine(staged)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        clearQuarantine(destination)
    }

    /// `xattr -d com.apple.quarantine` (a missing attribute is fine).
    nonisolated static func clearQuarantine(_ url: URL) {
        _ = url.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
    }

    // MARK: Pure helpers (unit-tested)

    /// Parses a `SHA2-256SUMS` file ("<64 hex>  <name>" per line, `*` binary marker allowed) into name -> lower-case hex.
    nonisolated static func parseChecksums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let hash = String(line[line.startIndex..<space])
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            var name = line[space...].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard !name.isEmpty else { continue }
            out[name] = hash.lowercased()
        }
        return out
    }

    /// SHA-256 of a file, streamed (never loads a large file whole).
    nonisolated static func sha256(of file: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw ConversionError.fileUnreadable(file) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True when the file's SHA-256 equals the entry for `name` in `checksums`.
    nonisolated static func verify(file: URL, name: String, checksums: [String: String]) throws -> Bool {
        guard let expected = checksums[name] else { return false }
        return try sha256(of: file) == expected.lowercased()
    }

    /// A release tag looks like 2026.10.20 or 2026.10.20.123456 (nightly). Anything else is refused before it reaches a URL.
    nonisolated static func isValidTag(_ s: String) -> Bool {
        s.range(of: "^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}(\\.[0-9]{1,8})?$", options: .regularExpression) != nil
    }

    /// Numeric comparison of dotted versions: "2026.10.21" is newer than "2026.10.9"; a nightly suffix makes it newer than the plain release.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// yt-dlp understands `--js-runtimes` since the 2025.11 releases. Unknown versions are assumed new (installs are recent by design).
    nonisolated static func supportsJSRuntimesOption(version: String?) -> Bool {
        guard let v = version, !v.isEmpty else { return true }
        return !isNewer("2025.11.12", than: v)
    }
}
