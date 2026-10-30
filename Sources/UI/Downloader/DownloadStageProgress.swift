import SwiftUI

// Two-stage progress for a download that is followed by a conversion ("Downloading" 0.6, then "Converting" 0.4). The job model of Core already tracks the stages
// (`Job.stages`, `StageProgress`); this file only PRESENTS them, so the sheet and any other row can show the same thing without touching each other's code.
// Updates arrive from the Job at <= 10 Hz; the view runs no timer and no animation of its own (the bar animates in Core Animation).

/// The pure part: what each stage line says. Tested without a view.
struct DownloadStageLine: Equatable, Identifiable {
    var id: String
    var title: String
    var symbol: String
    var fraction: Double?
    var state: StageState
    /// "42%", "waiting", "done", "failed".
    var detail: String
    var isSecondary: Bool

    static func lines(from stages: [StageProgress]) -> [DownloadStageLine] {
        stages.enumerated().map { index, stage in
            DownloadStageLine(id: stage.id, title: stage.spec.title.text, symbol: stage.spec.symbol ?? "circle", fraction: fraction(of: stage), state: stage.state,
                              detail: detail(of: stage), isSecondary: index > 0)
        }
    }

    static func fraction(of s: StageProgress) -> Double? {
        switch s.state {
        case .done: return 1
        case .pending, .skipped: return 0
        case .running, .failed: return s.fraction
        }
    }

    static func detail(of s: StageProgress) -> String {
        switch s.state {
        case .pending: return L("waiting", "ожидает")
        case .skipped: return L("not needed", "не нужно")
        case .done: return L("done", "готово")
        case .failed: return L("failed", "ошибка")
        case .running:
            guard let f = s.fraction else { return L("working…", "выполняется…") }
            return Loc.percent(Int((Util.clamp(f, 0, 1) * 100).rounded()))
        }
    }

    /// One line for VoiceOver / the toast: "Downloading 42%, then Converting".
    static func summary(_ lines: [DownloadStageLine]) -> String {
        guard let current = lines.first(where: { $0.state == .running }) ?? lines.first(where: { $0.state == .pending }) else { return lines.last?.title ?? "" }
        let rest = lines.drop(while: { $0.id != current.id }).dropFirst().map(\.title)
        let head = current.state == .running ? "\(current.title) \(current.detail)" : current.title
        return rest.isEmpty ? head : head + L(", then ", ", затем ") + rest.joined(separator: ", ")
    }
}

struct DownloadStageProgressView: View {
    @ObservedObject var job: Job

    var body: some View {
        let lines = DownloadStageLine.lines(from: job.stages)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if lines.count > 1 {
                ForEach(lines) { line in
                    DownloadStageRow(line: line)
                }
            } else {
                DownloadStageRow(line: DownloadStageLine(id: "single", title: job.currentStageTitle ?? L("Downloading", "Загрузка"), symbol: "arrow.down.circle",
                                                         fraction: job.state == .done ? 1 : job.progress, state: job.state == .done ? .done : .running,
                                                         detail: job.progress.map { Loc.percent(Int((Util.clamp($0, 0, 1) * 100).rounded())) } ?? L("working…", "выполняется…"),
                                                         isSecondary: false))
            }
            if job.state == .running, let eta = job.eta, eta > 1 {
                Text(L("About \(Util.formatDuration(eta)) left", "Осталось около \(Util.formatDuration(eta))")).font(DS.Typo.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(DownloadStageLine.summary(lines)))
    }
}

/// A stage row: symbol, title, the percentage, and the slanted bar (pink for the first stage, Swamp Blue for the second).
struct DownloadStageRow: View {
    var line: DownloadStageLine

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: line.state == .done ? "checkmark.circle" : line.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(line.title).font(DS.Typo.callout.weight(.medium))
                Spacer()
                Text(line.detail).font(DS.Typo.numeric(.callout)).foregroundStyle(.secondary)
            }
            SlantedProgressBar(value: line.fraction, secondary: line.isSecondary)
        }
        .opacity(line.state == .pending ? 0.6 : 1)
    }
}
