import SwiftUI

// The sticky capsule at the top of the inspector. Pure wording lives in `SummaryText` (unit-tested in both languages).

enum SummaryText {
    /// "About 412 MB (68% smaller) . about 6 min". nil when the operation can estimate neither.
    static func estimateLine(_ e: OperationEstimate?, sourceBytes: Int64?) -> String? {
        let p = estimateParts(e, sourceBytes: sourceBytes)
        let all = [p.size, p.time].compactMap { $0 }
        return all.isEmpty ? nil : all.joined(separator: " \u{00B7} ")
    }

    /// The size sentence and the time sentence separately (the capsule puts them on two lines so neither wraps in the middle).
    static func estimateParts(_ e: OperationEstimate?, sourceBytes: Int64?) -> (size: String?, time: String?) {
        guard let e else { return (nil, nil) }
        var sizeText: String?, time: String?
        if let bytes = e.bytes {
            let human = Util.formatBytes(bytes)
            var s = e.confidence == .measured ? L("Measured: \(human)", "Замер: \(human)") : L("About \(human)", "Около \(human)")
            if let src = sourceBytes, src > 0 {
                let pct = Int(((1 - Double(bytes) / Double(src)) * 100).rounded())
                if pct >= 1 { s += " " + L("(\(pct)% smaller)", "(на \(pct) % меньше)") }
                else if pct <= -1 { s += " " + L("(\(-pct)% larger)", "(на \(-pct) % больше)") }
                else { s += " " + L("(about the same size)", "(примерно как исходный)") }
            }
            sizeText = s
        }
        if let secs = e.seconds {
            time = L("about \(Util.formatDuration(secs))", "около \(Util.formatDuration(secs))")
        }
        return (sizeText, time)
    }

    static func confidenceNote(_ c: OperationEstimate.Confidence) -> L10n {
        switch c {
        case .rough:
            return L10n("Estimated from the settings and the length of the source. The real size can differ by about a fifth.",
                        "Оценка по настройкам и длине источника. Реальный размер может отличаться примерно на пятую часть.")
        case .sampled:
            return L10n("Estimated from a short sample of your file.", "Оценка по короткому образцу вашего файла.")
        case .measured:
            return L10n("Measured on a real result.", "Измерено на настоящем результате.")
        }
    }

    /// "3 warnings" / "1 error" / "1 error, 2 warnings" in the right plural form.
    static func problemsTitle(errors: Int, warnings: Int) -> String {
        let e = Loc.plural(errors, enOne: "\(errors) error", enOther: "\(errors) errors", ruOne: "\(errors) ошибка", ruFew: "\(errors) ошибки", ruMany: "\(errors) ошибок")
        let w = Loc.plural(warnings, enOne: "\(warnings) warning", enOther: "\(warnings) warnings", ruOne: "\(warnings) предупреждение", ruFew: "\(warnings) предупреждения", ruMany: "\(warnings) предупреждений")
        if errors > 0 && warnings > 0 { return e + ", " + w }
        return errors > 0 ? e : w
    }
}

/// The sticky capsule at the top of the inspector: chips (container, codec, resolution, fps, audio) as `InfoChip`s, "About 412 MB (68% smaller) - about 6 min" with the (i) popover
/// and a "Measure" button, a problems button listing messages with fix buttons. Glass over the scrolling form; opaque with a separator under Reduce Transparency / Increase Contrast
/// (the shared glass surface does that). Size changes are announced politely, at most every few seconds, and never animate as counters.
struct SummaryCapsule: View {
    @ObservedObject var session: StudioSession
    @State private var infoShown = false
    @State private var problemsShown = false
    @State private var lastAnnounced = Date.distantPast
    @Environment(\.a11y) private var a11y

    private var sourceBytes: Int64? {
        let sizes = session.activeFiles.compactMap(\.size)
        if sizes.count == session.activeFiles.count, !sizes.isEmpty { return sizes.reduce(0, +) }
        return session.activeSource?.info?.sizeBytes
    }

    var body: some View {
        GlassPanel(cornerRadius: DS.Radius.card, padding: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                if !session.summaryChips.isEmpty {
                    OptionFlow { ForEach(session.summaryChips, id: \.self) { InfoChip($0) } }
                }
                estimateRow
                problemsRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Summary", "Сводка")))
        .onChange(of: session.estimate?.bytes) { _, _ in announce() }
    }

    @ViewBuilder private var estimateRow: some View {
        let line = SummaryText.estimateLine(session.estimate, sourceBytes: sourceBytes)
        if line != nil || session.operation != nil {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                if let line {
                    let parts = SummaryText.estimateParts(session.estimate, sourceBytes: sourceBytes)
                    VStack(alignment: .leading, spacing: 0) {
                        if let size = parts.size { Text(size).font(DS.Typo.numeric(.callout)).fixedSize(horizontal: false, vertical: true) }
                        if let time = parts.time { Text(time).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    .contentTransition(a11y.reduceMotion ? .identity : .numericText())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(line))
                    Button { infoShown.toggle() } label: {
                        Image(systemName: "info.circle").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("About this estimate", "Об этой оценке")))
                    .popover(isPresented: $infoShown, arrowEdge: .bottom) { infoContent }
                } else {
                    Text(L("The size can’t be estimated for this setting.", "Размер для этих настроек оценить нельзя."))
                        .font(DS.Typo.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.sm)
                if session.isPreviewing { ProgressView().controlSize(.small).accessibilityLabel(Text(L("Measuring", "Измерение"))) }
                if line != nil, session.estimate?.confidence != .measured {
                    Button { session.measure() } label: { Text(L("Measure", "Измерить")).font(DS.Typo.callout.weight(.medium)).foregroundStyle(Brand.blueInk) }
                        .buttonStyle(.plain)
                        .disabled(session.activeFiles.isEmpty)
                }
            }
        }
    }

    private var infoContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(SummaryText.confidenceNote(session.estimate?.confidence ?? .rough).text)
            if let note = session.estimate?.note { Text(note.text).foregroundStyle(.secondary) }
            if let note = session.measureNote { Text(note.text).foregroundStyle(.secondary) }
        }
        .font(DS.Typo.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 280, alignment: .leading)
        .padding(DS.Space.lg)
    }

    @ViewBuilder private var problemsRow: some View {
        let probs = session.messages.filter { $0.severity >= .warning }
        if !probs.isEmpty {
            let errors = probs.filter { $0.severity == .error }.count
            Button { problemsShown.toggle() } label: {
                Label(SummaryText.problemsTitle(errors: errors, warnings: probs.count - errors), systemImage: errors > 0 ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(DS.Typo.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(errors > 0 ? OptionTone.error.ink : OptionTone.warning.ink)
            .popover(isPresented: $problemsShown, arrowEdge: .bottom) { problemsContent }
        }
    }

    private var problemsContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(session.messages.filter { $0.severity >= .info }) { m in
                OptionMessageRow(m, onFix: { session.applyFix($0); if session.messages.isEmpty { problemsShown = false } })
            }
        }
        .frame(width: 340)
        .padding(DS.Space.md)
    }

    /// Polite and rate-limited: at most one announcement per 4 seconds.
    private func announce() {
        let now = Date()
        guard now.timeIntervalSince(lastAnnounced) > 4, let line = SummaryText.estimateLine(session.estimate, sourceBytes: sourceBytes) else { return }
        lastAnnounced = now
        OptionAnnouncer.announce(line)
    }
}
