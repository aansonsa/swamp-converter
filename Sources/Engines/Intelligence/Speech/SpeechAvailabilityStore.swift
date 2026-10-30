import Foundation
import Speech

// Which languages can this Mac recognise fully on device right now? Answered from Apple's own listings (no network, nothing is downloaded):
//   * SpeechTranscriber  (macOS 26): `supportedLocales` / `installedLocales`
//   * DictationTranscriber (same engine as keyboard dictation): used when the person installed the dictation language in System Settings
// Verified on this Mac (macOS 26.5): en-US is installed and transcribes; ru-RU is dictation-supported but its model is not installed (SpeechTranscriber does not
// list Russian at all); lv-LV is supported by neither. The snapshot is cached for a short time because the listing needs two async calls.

enum SpeechBackend: String, Sendable { case speechTranscriber, dictation }

struct SpeechSnapshot: Sendable {
    struct Entry: Sendable {
        var locale: Locale
        var backend: SpeechBackend
        var installed: Bool
    }

    var frameworkAvailable: Bool
    /// Normalised BCP-47 key ("ru-ru") -> best entry (SpeechTranscriber wins over dictation when both are installed).
    var entries: [String: Entry]
    var loadedAt: Date

    static func key(_ locale: Locale) -> String { locale.identifier(.bcp47).lowercased() }

    /// "ru-RU", "ru_RU" or plain "ru" -> the entry that serves it (a bare language picks the region of the person's Mac, then en-US, then the first installed).
    func entry(for id: String) -> Entry? {
        let wanted = Locale(identifier: id.replacingOccurrences(of: "_", with: "-"))
        let k = Self.key(wanted)
        if let e = entries[k] { return e }
        guard let lang = wanted.language.languageCode?.identifier else { return nil }
        let same = entries.values.filter { $0.locale.language.languageCode?.identifier == lang }
        guard !same.isEmpty else { return nil }
        let region = Locale.current.region?.identifier
        func rank(_ e: Entry) -> (Int, Int, String) {
            let r = e.locale.region?.identifier
            let regionScore = r == region ? 0 : (r == "US" ? 1 : 2)
            return (e.installed ? 0 : 1, regionScore, Self.key(e.locale))
        }
        return same.min { rank($0) < rank($1) }
    }

    func availability(for id: String) -> SpeechAvailability {
        guard frameworkAvailable else {
            return .unavailable(reason: L10n("Speech recognition is not available on this Mac.", "Распознавание речи недоступно на этом Mac."))
        }
        guard let e = entry(for: id) else { return .languageUnsupported(language: id) }
        return e.installed ? .available : .modelMissing(language: e.locale.identifier(.bcp47))
    }

    /// Installed entries, sorted by the name in the UI language.
    var usable: [Entry] {
        entries.values.filter(\.installed).sorted { SpeechLanguageName.text($0.locale.identifier(.bcp47)) < SpeechLanguageName.text($1.locale.identifier(.bcp47)) }
    }

    /// What "auto" means: the first language of the person's list that this Mac can recognise, else English, else the first installed one.
    func autoEntry() -> Entry? {
        for pref in Locale.preferredLanguages {
            if let e = entry(for: pref), e.installed { return e }
        }
        if let en = entry(for: "en-US"), en.installed { return en }
        return usable.first
    }

    static func load() async -> SpeechSnapshot {
        guard SpeechTranscriber.isAvailable else { return SpeechSnapshot(frameworkAvailable: false, entries: [:], loadedAt: Date()) }
        async let stSupported = SpeechTranscriber.supportedLocales
        async let stInstalled = SpeechTranscriber.installedLocales
        async let dSupported = DictationTranscriber.supportedLocales
        async let dInstalled = DictationTranscriber.installedLocales
        let (ss, si, ds, di) = await (stSupported, stInstalled, dSupported, dInstalled)
        let stInstalledKeys = Set(si.map(key)), dInstalledKeys = Set(di.map(key))
        var entries: [String: Entry] = [:]
        for l in ss { entries[key(l)] = Entry(locale: l, backend: .speechTranscriber, installed: stInstalledKeys.contains(key(l))) }
        for l in ds {
            let k = key(l)
            let candidate = Entry(locale: l, backend: .dictation, installed: dInstalledKeys.contains(k))
            if let existing = entries[k] {
                if !existing.installed && candidate.installed { entries[k] = candidate }
            } else {
                entries[k] = candidate
            }
        }
        return SpeechSnapshot(frameworkAvailable: true, entries: entries, loadedAt: Date())
    }
}

/// Language names in the UI language ("Russian (Russia)" / "русский (Россия)").
enum SpeechLanguageName {
    static func english(_ id: String) -> String { Locale(identifier: "en_US").localizedString(forIdentifier: id) ?? id }
    static func russian(_ id: String) -> String {
        let n = Locale(identifier: "ru_RU").localizedString(forIdentifier: id) ?? id
        return n.prefix(1).uppercased() + n.dropFirst()
    }
    static func text(_ id: String) -> String { Loc.shared.pick(english(id), russian(id)) }
    static func l10n(_ id: String) -> L10n { L10n(english(id), russian(id)) }
}

/// Cached snapshot with a synchronous accessor for the places that cannot await (operation availability, capability closures).
final class SpeechAvailabilityStore: @unchecked Sendable {
    static let shared = SpeechAvailabilityStore()
    /// A person who adds a language in System Settings and comes back should see it within half a minute.
    static let timeToLive: TimeInterval = 30

    private let lock = NSLock()
    private var cached: SpeechSnapshot?
    private var refreshing = false

    func snapshot() async -> SpeechSnapshot {
        if let s = fresh() { return s }
        let s = await SpeechSnapshot.load()
        store(s)
        return s
    }

    /// Whatever is cached (possibly stale), never blocks; starts a refresh in the background when it is missing or old.
    func peek() -> SpeechSnapshot? {
        lock.lock(); let s = cached; let stale = s.map { Date().timeIntervalSince($0.loadedAt) > Self.timeToLive } ?? true; let busy = refreshing
        if stale && !busy { refreshing = true }
        lock.unlock()
        if stale && !busy {
            Task.detached(priority: .utility) { let s = await SpeechSnapshot.load(); SpeechAvailabilityStore.shared.store(s) }
        }
        return s
    }

    /// For synchronous callers on user-triggered paths (opening the wheel or a Studio page): waits briefly for the first load.
    func snapshotBlocking(timeout: TimeInterval = 1.5) -> SpeechSnapshot? {
        if let s = fresh() { return s }
        let sem = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) { let s = await SpeechSnapshot.load(); SpeechAvailabilityStore.shared.store(s); sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    func invalidate() { lock.lock(); cached = nil; lock.unlock() }

    private func fresh() -> SpeechSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let s = cached, Date().timeIntervalSince(s.loadedAt) <= Self.timeToLive else { return nil }
        return s
    }

    fileprivate func store(_ s: SpeechSnapshot) {
        lock.lock(); cached = s; refreshing = false; lock.unlock()
    }
}

enum SpeechCapabilities {
    /// Languages worth a capability id (the wheel / Studio ask `native.speech.lang.<id>` cheaply). Any other language is answered by `SpeechEngine.availability`.
    static let candidateLanguages = ["en-US", "ru-RU", "lv-LV", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "uk-UA", "pl-PL", "ja-JP", "zh-CN", "ko-KR"]

    /// Registers `native.speech.available` and `native.speech.lang.<code>` as cheap closures; the real check (framework load) happens on first call.
    static func register() {
        Capabilities.shared.register("native.speech.available") {
            SpeechAvailabilityStore.shared.snapshotBlocking().map { $0.frameworkAvailable && !$0.usable.isEmpty } ?? false
        }
        for id in candidateLanguages {
            Capabilities.shared.register("native.speech.lang.\(id)") {
                SpeechAvailabilityStore.shared.snapshotBlocking()?.availability(for: id) == .available
            }
        }
    }
}
