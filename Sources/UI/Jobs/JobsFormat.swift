import Foundation

/// Pure text of the jobs UI: ETA with Russian plurals, percent, throughput, durations. Every function reads the active language through `L` / `Loc`, so the tests switch the
/// language and compare whole sentences.
enum JobsFormat {
    enum Unit { case second, minute, hour }

    /// "About 20 seconds left" / "Осталось около 20 секунд". Rounded so the text does not jitter (5 s steps below 45 s, whole minutes, 5-minute steps from an hour).
    /// After "около" Russian takes the GENITIVE: 1 -> "секунды / минуты / часа", every other count -> "секунд / минут / часов".
    static func etaText(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 3 { return L("Almost done", "Почти готово") }
        if seconds >= 86_400 { return L("More than a day left", "Осталось больше суток") }
        if seconds < 45 { return left(max(5, Int((seconds / 5).rounded()) * 5), .second) }
        if seconds < 90 { return left(1, .minute) }
        if seconds < 3_300 { return left(Int((seconds / 60).rounded()), .minute) }
        let minutes = Int((seconds / 300).rounded()) * 5
        let h = minutes / 60, m = minutes % 60
        if m == 0 { return left(h, .hour) }
        return L("About \(h) h \(m) min left", "Осталось около \(h) ч \(m) мин")
    }

    private static func left(_ n: Int, _ unit: Unit) -> String {
        let en: String
        let ruOne: String, ruMany: String
        switch unit {
        case .second: en = n == 1 ? "1 second" : "\(n) seconds"; ruOne = "секунды"; ruMany = "секунд"
        case .minute: en = n == 1 ? "1 minute" : "\(n) minutes"; ruOne = "минуты"; ruMany = "минут"
        case .hour: en = n == 1 ? "1 hour" : "\(n) hours"; ruOne = "часа"; ruMany = "часов"
        }
        let word = Loc.ruCategory(n) == .one ? ruOne : ruMany
        return L("About \(en) left", "Осталось около \(n) \(word)")
    }

    /// "42%" (rounded down, so the text never says 100% before the job is done). nil for an indeterminate job.
    static func percentText(_ progress: Double?) -> String? {
        guard let progress, progress.isFinite else { return nil }
        let p = Int((min(max(progress, 0), 1) * 100).rounded(.down))
        return Loc.percent(p)
    }

    /// Input throughput "12 MB/s" for jobs that read at least 5 MB, after two seconds and 3 percent (before that the number is noise). nil otherwise.
    static func speedText(progress: Double?, inputBytes: Int64, elapsed: TimeInterval) -> String? {
        guard let progress, progress >= 0.03, inputBytes >= 5_000_000, elapsed >= 2 else { return nil }
        let perSecond = Double(inputBytes) * min(progress, 1) / elapsed
        guard perSecond.isFinite, perSecond > 0 else { return nil }
        return Util.formatBytes(Int64(perSecond)) + L("/s", "/с")
    }

    /// "42 s" for the "Done in ..." suffix; nil under one second.
    static func tookText(_ elapsed: TimeInterval) -> String? {
        elapsed >= 1 ? Util.formatDuration(elapsed) : nil
    }

    /// "5 files" / "5 файлов".
    static func files(_ n: Int) -> String { Loc.files(n) }
}
