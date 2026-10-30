import Foundation

// Pure logic behind the schema renderer. No SwiftUI in this file: everything here is unit-tested in `StudioCoreRendererTests`.
//
//  * which fields are shown for a density (Simple / Advanced / expert), how groups collapse, the "<= 6 fields per group in Simple" cap
//  * whether a field is enabled, and the plain-words reason when it is not (capability gap, condition, page requirement, preset lock)
//  * the search result sections (label, help, key, aliases in both languages; expert hits are flagged)

enum OptionFormLogic {
    /// Fields shown per group in Simple density before "Show N more".
    static let simpleFieldCap = 6
    /// Groups at or beyond this position (counting visible groups) start collapsed in Simple.
    static let simpleOpenGroups = 2

    /// Highest field / group level shown for a density; `showExpert` lifts the limit to `.expert`.
    static func maxLevel(density: DensitySetting, showExpert: Bool) -> OptionLevel {
        if showExpert { return .expert }
        return density == .simple ? .basic : .standard
    }

    // MARK: Field state

    struct FieldState: Equatable {
        /// False when a `visibleWhen` of the page, group or field does not hold: the field is not offered at all.
        var visible: Bool
        var enabled: Bool
        var reason: L10n?
        /// The reason is a capability gap (a tool or encoder is missing), not a condition.
        var isCapabilityGap = false
        var isLocked = false

        static func == (a: FieldState, b: FieldState) -> Bool {
            a.visible == b.visible && a.enabled == b.enabled && a.reason == b.reason && a.isCapabilityGap == b.isCapabilityGap && a.isLocked == b.isLocked
        }
    }

    static let conditionReason = L10n("Not available with the current settings.", "Недоступно при текущих настройках.")

    static func lockedReason(presetName: L10n?) -> L10n {
        guard let name = presetName else { return L10n("Locked by the preset.", "Заблокировано шаблоном.") }
        return L10n("Locked by the preset “\(name.en)”.", "Заблокировано шаблоном «\(name.ru)».")
    }

    static func state(of field: OptionField, group: OptionGroup?, page: OptionPage?, env: ExprEnvironment,
                      lockedKeys: Set<String> = [], lockedBy: L10n? = nil) -> FieldState {
        var visible = true
        if let p = page, let w = p.visibleWhen, !w.evaluate(env) { visible = false }
        if let g = group, let w = g.visibleWhen, !w.evaluate(env) { visible = false }
        if let w = field.visibleWhen, !w.evaluate(env) { visible = false }
        let caps = env.capabilities
        if let p = page, !caps.hasAll(p.requires) {
            return FieldState(visible: visible, enabled: false, reason: caps.missingReason(p.requires), isCapabilityGap: true)
        }
        if !caps.hasAll(field.requires) {
            return FieldState(visible: visible, enabled: false, reason: field.disabledReason ?? caps.missingReason(field.requires), isCapabilityGap: true)
        }
        if let w = field.enabledWhen, !w.evaluate(env) {
            return FieldState(visible: visible, enabled: false, reason: field.disabledReason ?? conditionReason)
        }
        if lockedKeys.contains(field.key) {
            return FieldState(visible: visible, enabled: false, reason: lockedReason(presetName: lockedBy), isLocked: true)
        }
        return FieldState(visible: visible, enabled: true, reason: nil)
    }

    /// Availability of one option of a picker / segmented control: `(enabled, hint)`. A capability gap shows the calm "Needs ..." reason.
    static func availability(of option: FieldOption, env: ExprEnvironment?) -> (enabled: Bool, hint: L10n?) {
        let caps = env?.capabilities ?? Capabilities.shared
        if !caps.hasAll(option.requires) { return (false, option.hint ?? caps.missingReason(option.requires)) }
        if let w = option.enabledWhen, let env, !w.evaluate(env) { return (false, option.hint) }
        return (true, option.hint)
    }

    // MARK: Page layout

    struct GroupLayout: Identifiable {
        var group: OptionGroup
        /// Fields to draw now.
        var fields: [OptionField]
        /// Visible fields hidden only by the Simple cap (a "Show N more" row offers them).
        var overflow: Int
        /// Starts collapsed (the user's own toggling overrides this).
        var collapsedByDefault: Bool
        var id: String { group.id }
    }

    struct PageLayout {
        var groups: [GroupLayout]
        /// Visible expert fields that are not shown (drives the "Show N expert options" row).
        var expertHidden: Int
        /// Visible standard fields hidden by Simple density.
        var advancedHidden: Int
    }

    static func layout(page: OptionPage, density: DensitySetting, showExpert: Bool, env: ExprEnvironment,
                       expandedOverflow: Set<String> = []) -> PageLayout {
        let limit = maxLevel(density: density, showExpert: showExpert)
        var out: [GroupLayout] = []
        var expertHidden = 0, advancedHidden = 0
        var visibleIndex = 0
        for group in page.groups {
            if let w = group.visibleWhen, !w.evaluate(env) { continue }
            let applicable = group.fields.filter { f in
                guard let w = f.visibleWhen else { return true }
                return w.evaluate(env)
            }
            // A group of a higher level than the density shows nothing: all of its fields count as hidden at the group's level.
            if group.level > limit {
                if group.level == .expert { expertHidden += applicable.count } else { advancedHidden += applicable.count }
                continue
            }
            for f in applicable where f.level > limit {
                if f.level == .expert { expertHidden += 1 } else { advancedHidden += 1 }
            }
            var shown = applicable.filter { $0.level <= limit }
            if shown.isEmpty { continue }
            var overflow = 0
            if density == .simple && !showExpert && shown.count > simpleFieldCap && !expandedOverflow.contains(group.id) {
                overflow = shown.count - simpleFieldCap
                shown = Array(shown.prefix(simpleFieldCap))
            }
            let collapsible = group.title != nil
            let collapsed = collapsible && (group.collapsed || (density == .simple && visibleIndex >= simpleOpenGroups))
            out.append(GroupLayout(group: group, fields: shown, overflow: overflow, collapsedByDefault: collapsed))
            visibleIndex += 1
        }
        return PageLayout(groups: out, expertHidden: expertHidden, advancedHidden: advancedHidden)
    }

    /// Pages offered for the current values (a page whose `visibleWhen` is false disappears; a page missing a capability stays, disabled).
    static func visiblePages(_ schema: OptionSchema, env: ExprEnvironment) -> [OptionPage] {
        schema.pages.filter { $0.visibleWhen?.evaluate(env) ?? true }
    }

    // MARK: Search

    struct SearchSection: Identifiable {
        var page: OptionPage
        var group: OptionGroup
        var fields: [OptionField]
        var id: String { page.id + "/" + group.id }
        var title: String {
            let g = group.title?.text
            return g.map { "\(page.title.text) \u{203A} \($0)" } ?? page.title.text
        }
    }

    struct SearchResult {
        var sections: [SearchSection]
        /// At least one hit is an expert field that the density would hide: the list says "Searching also in expert options".
        var includesExpert: Bool
        var hitCount: Int { sections.reduce(0) { $0 + $1.fields.count } }
    }

    /// Search across label, help, key and aliases in BOTH languages (`OptionSchema.search`). Fields that do not apply right now (a `visibleWhen` that
    /// is false) are skipped; disabled fields stay and show their reason. Expert fields are always included.
    static func search(_ schema: OptionSchema, query: String, env: ExprEnvironment, density: DensitySetting, showExpert: Bool) -> SearchResult {
        let hits = schema.search(query)
        var sections: [SearchSection] = []
        var includesExpert = false
        let limit = maxLevel(density: density, showExpert: showExpert)
        for hit in hits {
            let st = state(of: hit.field, group: hit.group, page: hit.page, env: env)
            if !st.visible { continue }
            if hit.field.level > limit || hit.group.level > limit { includesExpert = includesExpert || hit.field.level == .expert || hit.group.level == .expert }
            if let i = sections.firstIndex(where: { $0.page.id == hit.page.id && $0.group.id == hit.group.id }) {
                sections[i].fields.append(hit.field)
            } else {
                sections.append(SearchSection(page: hit.page, group: hit.group, fields: [hit.field]))
            }
        }
        return SearchResult(sections: sections, includesExpert: includesExpert)
    }

    /// The page and group a field lives in (for "show in page" from a search hit).
    static func location(of key: String, in schema: OptionSchema) -> (page: OptionPage, group: OptionGroup)? {
        for p in schema.pages { for g in p.groups where g.fields.contains(where: { $0.key == key }) { return (p, g) } }
        return nil
    }
}

// MARK: - Number, time and colour formatting

enum OptionFormat {
    /// "22", "0.5", "1,5" in the active language, at most `decimals` fraction digits and no trailing zeros.
    static func number(_ v: Double, decimals: Int = 0) -> String {
        let f = NumberFormatter()
        f.locale = Loc.shared.locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = max(decimals, 0)
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// Parses a number a person typed: both "1.5" and "1,5" work in both languages.
    static func parseNumber(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "\u{00A0}", with: "")
        guard !t.isEmpty, let d = Double(t), d.isFinite else { return nil }
        return d
    }

    /// `H:MM:SS.mmm` ("0:01:30.500"): what the time field shows and accepts.
    static func timeString(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let totalMs = Int((s * 1000).rounded())
        let h = totalMs / 3_600_000, m = (totalMs / 60_000) % 60, sec = (totalMs / 1000) % 60, ms = totalMs % 1000
        return String(format: "%d:%02d:%02d.%03d", h, m, sec, ms)
    }

    /// The stored value of a time field -> field text; "" for "not set".
    static func timeText(_ value: OptionValue) -> String {
        if case .string(let s) = value { return s.trimmingCharacters(in: .whitespaces).isEmpty ? "" : (Util.parseTime(s).map(timeString) ?? s) }
        return value.asDouble.map(timeString) ?? ""
    }

    static let timeProblem = L10n("Use a time like 1:30 or 0:01:30.500.", "Введите время в виде 1:30 или 0:01:30.500.")

    /// `#RRGGBB` -> 0...255 triple.
    static func rgb(fromHex hex: String) -> (r: Int, g: Int, b: Int)? {
        let t = hex.trimmingCharacters(in: .whitespaces)
        guard t.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil, let v = Int(t.dropFirst(), radix: 16) else { return nil }
        return ((v >> 16) & 255, (v >> 8) & 255, v & 255)
    }

    static func hex(r: Int, g: Int, b: Int) -> String {
        String(format: "#%02X%02X%02X", min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))
    }

    /// Text for the value of a field as people read it: the option's label, "on / off", number + unit, time, "3 rows". Used by the "Default: ..." chip and the Show changes list.
    static func display(_ value: OptionValue?, for field: OptionField) -> String {
        guard let value else { return L("not set", "не задано") }
        switch field.kind {
        case .toggle: return value.displayText
        case .picker(let opts), .segmented(let opts):
            let s = value.asString ?? ""
            return opts.first(where: { $0.value == s })?.label.text ?? s
        case .slider(let spec):
            let n = number(value.asDouble ?? 0, decimals: spec.decimals)
            return [n, spec.unit ?? field.unit].compactMap { $0 }.joined(separator: " ")
        case .stepper(let spec):
            return [String(value.asInt ?? 0), spec.unit ?? field.unit].compactMap { $0 }.joined(separator: " ")
        case .number(let spec):
            return [number(value.asDouble ?? 0, decimals: spec.decimals), spec.unit ?? field.unit].compactMap { $0 }.joined(separator: " ")
        case .time:
            let t = timeText(value)
            return t.isEmpty ? L("not set", "не задано") : t
        case .text(let spec):
            if spec.secure { return value.asString?.isEmpty == false ? "\u{2022}\u{2022}\u{2022}\u{2022}" : L("not set", "не задано") }
            let s = value.asString ?? ""
            return s.isEmpty ? L("empty", "пусто") : s
        case .folder, .file, .color:
            let s = value.asString ?? ""
            return s.isEmpty ? L("not set", "не задано") : s
        case .tracks(let spec):
            guard let rows = value.asRows, !rows.isEmpty else { return L("none", "нет") }
            return rows.enumerated().map { TrackRows.summary(of: $1, spec: spec, index: $0).title }.joined(separator: ", ")
        }
    }
}

// MARK: - Slider mapping

enum OptionSlider {
    /// 0...1 position of `value` on the track (log scale when the spec asks for it and the range is positive).
    static func position(of value: Double, spec: SliderSpec) -> Double {
        let lo = spec.min, hi = spec.max
        guard hi > lo else { return 0 }
        let v = Util.clamp(value, lo, hi)
        if spec.logarithmic && lo > 0 { return (log(v) - log(lo)) / (log(hi) - log(lo)) }
        return (v - lo) / (hi - lo)
    }

    /// The (snapped, clamped) value at a track position.
    static func value(atPosition p: Double, spec: SliderSpec) -> Double {
        let lo = spec.min, hi = spec.max
        let q = Util.clamp(p, 0, 1)
        let raw: Double
        if spec.logarithmic && lo > 0 { raw = exp(log(lo) + q * (log(hi) - log(lo))) } else { raw = lo + q * (hi - lo) }
        return snap(raw, spec: spec)
    }

    static func snap(_ v: Double, spec: SliderSpec) -> Double {
        var out = v
        if spec.step > 0 { out = spec.min + ((v - spec.min) / spec.step).rounded() * spec.step }
        out = Util.clamp(out, spec.min, spec.max)
        let scale = pow(10.0, Double(max(spec.decimals, 0)))
        return (out * scale).rounded() / scale
    }

    /// One keyboard / VoiceOver step: the schema's step, or 1% of the range when there is none.
    static func stepSize(spec: SliderSpec) -> Double { spec.step > 0 ? spec.step : (spec.max - spec.min) / 100 }

    /// A key press smaller than half a step snaps back to where it was; turn it into one step in the pressed direction. A drag keeps plain snapping.
    static func nudged(snapped: Double, raw: Double, current: Double, dragging: Bool, spec: SliderSpec) -> Double {
        guard !dragging, abs(snapped - current) < 1e-9, abs(raw - current) > 1e-9 else { return snapped }
        return snap(current + (raw > current ? stepSize(spec: spec) : -stepSize(spec: spec)), spec: spec)
    }

    /// The value in the form the schema stores it (`.int` when the slider is whole-numbered, as `OptionSchema.resolve` does).
    static func stored(_ v: Double, spec: SliderSpec) -> OptionValue {
        spec.decimals == 0 && spec.step == spec.step.rounded() ? .int(Int(v.rounded())) : .double(v)
    }

    /// What VoiceOver reads for the value: "22 CRF" plus the direction ("left: Smaller file, right: Better quality").
    static func spoken(value: Double, spec: SliderSpec, fallbackUnit: String?) -> String {
        [OptionFormat.number(value, decimals: spec.decimals), spec.unit ?? fallbackUnit].compactMap { $0 }.joined(separator: " ")
    }

    static func direction(spec: SliderSpec) -> String? {
        guard let lo = spec.minLabel?.text, let hi = spec.maxLabel?.text else { return nil }
        return L("Left: \(lo). Right: \(hi).", "Влево: \(lo). Вправо: \(hi).")
    }
}

// MARK: - Track rows

/// Pure operations of the track-list editor.
enum TrackRows {
    typealias Row = [String: OptionValue]

    /// Which kind of probed stream a tracks field lists, from its key ("audio.tracks" -> audio, "sub.tracks" / "subtitles" -> subtitle, "chapters" -> chapter).
    static func streamKind(forFieldKey key: String) -> SourceStreamKind? {
        let k = key.lowercased()
        if k.contains("audio") { return .audio }
        if k.contains("sub") { return .subtitle }
        if k.contains("chapter") { return .chapter }
        return nil
    }

    private static let indexNames: Set<String> = ["source", "stream", "index", "track"]
    private static let languageNames: Set<String> = ["lang", "language"]
    private static let titleNames: Set<String> = ["title", "name", "label"]

    private static func suffix(_ key: String) -> String { key.split(separator: ".").last.map { String($0).lowercased() } ?? key.lowercased() }

    /// Key of the column that points at a source stream, if the spec has one.
    static func indexColumn(_ spec: TrackSpec) -> OptionField? { spec.columns.first { indexNames.contains(suffix($0.key)) } }

    /// A new row with every column at its default.
    static func emptyRow(_ spec: TrackSpec, source: SourceInfo?) -> Row {
        var row: Row = [:]
        for c in spec.columns { row[c.key] = c.defaultValue.resolve(source) }
        return row
    }

    /// A row for a probed stream: the index column gets the stream index (as text for a picker column, as a number otherwise), language and title columns are filled,
    /// the rest keeps its defaults.
    static func row(from stream: SourceStream, spec: TrackSpec, source: SourceInfo?) -> Row {
        var row = emptyRow(spec, source: source)
        for c in spec.columns {
            let s = suffix(c.key)
            if indexNames.contains(s) {
                switch c.kind {
                case .picker, .segmented, .text: row[c.key] = .string(String(stream.index))
                default: row[c.key] = .int(stream.index)
                }
            } else if languageNames.contains(s), let l = stream.language { row[c.key] = .string(l) }
            else if titleNames.contains(s), !stream.title.isEmpty { row[c.key] = .string(stream.title) }
        }
        return row
    }

    /// Probed streams of the field's kind that no row points at yet.
    static func addableStreams(field: OptionField, spec: TrackSpec, rows: [Row], source: SourceInfo?) -> [SourceStream] {
        guard let source else { return [] }
        let kind = streamKind(forFieldKey: field.key)
        let streams = source.streams.filter { s in kind.map { s.kind == $0 } ?? (s.kind == .audio || s.kind == .subtitle || s.kind == .chapter) }
        guard let col = indexColumn(spec) else { return streams }
        let used = Set(rows.compactMap { $0[col.key]?.asInt })
        return streams.filter { !used.contains($0.index) }
    }

    static func moved(_ rows: [Row], from: Int, to: Int) -> [Row] {
        guard rows.indices.contains(from), to >= 0, to < rows.count, from != to else { return rows }
        var out = rows
        let item = out.remove(at: from)
        out.insert(item, at: to)
        return out
    }

    static func removed(_ rows: [Row], at i: Int) -> [Row] {
        guard rows.indices.contains(i) else { return rows }
        var out = rows
        out.remove(at: i)
        return out
    }

    static func canAdd(_ rows: [Row], spec: TrackSpec) -> Bool { spec.maxRows.map { rows.count < $0 } ?? true }

    /// One-line summary of a collapsed row ("Track 1 - English - AAC - 160").
    static func summary(of row: Row, spec: TrackSpec, index: Int) -> (title: String, detail: String) {
        var title = L("Track \(index + 1)", "Дорожка \(index + 1)")
        if let tk = spec.rowTitleKey, let v = row[tk], let col = spec.columns.first(where: { $0.key == tk }) {
            let t = OptionFormat.display(v, for: col)
            if !t.isEmpty { title = t }
        }
        let detail = spec.columns.filter { $0.key != spec.rowTitleKey }.prefix(3).compactMap { c -> String? in
            guard let v = row[c.key] else { return nil }
            let t = OptionFormat.display(v, for: c)
            return t.isEmpty ? nil : t
        }.joined(separator: " \u{00B7} ")
        return (title, detail)
    }
}
