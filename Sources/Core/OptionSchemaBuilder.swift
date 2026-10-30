import Foundation
import UniformTypeIdentifiers

// Compact, fluent factories for schemas. Example:
//
//   OptionField.toggle("faststart", L10n("Optimise for streaming", "Оптимизировать для потоковой передачи"), def: true)
//       .basic()
//       .help(L10n("Puts the index at the start of the file.", "Индекс переносится в начало файла."))
//       .visible(.in("container", ["mp4", "mov"]))
//       .oracle("faststart.moov")
//
// Every modifier returns a modified copy. Defaults: level .standard, affects [.estimate, .plan].

extension OptionField {
    static func toggle(_ key: String, _ label: L10n, def: Bool = false) -> OptionField {
        OptionField(key: key, kind: .toggle, label: label, defaultValue: .value(.bool(def)))
    }
    static func picker(_ key: String, _ label: L10n, _ options: [FieldOption], def: String? = nil) -> OptionField {
        OptionField(key: key, kind: .picker(options), label: label, defaultValue: .value(.string(def ?? options.first?.value ?? "")))
    }
    static func segmented(_ key: String, _ label: L10n, _ options: [FieldOption], def: String? = nil) -> OptionField {
        OptionField(key: key, kind: .segmented(options), label: label, defaultValue: .value(.string(def ?? options.first?.value ?? "")))
    }
    static func slider(_ key: String, _ label: L10n, min: Double, max: Double, step: Double = 1, def: Double, unit: String? = nil,
                       minLabel: L10n? = nil, maxLabel: L10n? = nil, decimals: Int = 0, logarithmic: Bool = false) -> OptionField {
        OptionField(key: key,
                    kind: .slider(SliderSpec(min: min, max: max, step: step, unit: unit, logarithmic: logarithmic, minLabel: minLabel, maxLabel: maxLabel, decimals: decimals)),
                    label: label, unit: unit, defaultValue: .value(decimals == 0 && step == step.rounded() ? .int(Int(def)) : .double(def)))
    }
    static func stepper(_ key: String, _ label: L10n, min: Int, max: Int, step: Int = 1, def: Int, unit: String? = nil) -> OptionField {
        OptionField(key: key, kind: .stepper(StepperSpec(min: min, max: max, step: step, unit: unit)), label: label, unit: unit, defaultValue: .value(.int(def)))
    }
    static func text(_ key: String, _ label: L10n, def: String = "", placeholder: L10n? = nil, validation: TextValidation = .none,
                     multiline: Bool = false, secure: Bool = false) -> OptionField {
        var f = OptionField(key: key, kind: .text(TextSpec(placeholder: placeholder, multiline: multiline, validation: validation, secure: secure)),
                            label: label, defaultValue: .value(.string(def)))
        f.persist = !secure
        return f
    }
    /// Seconds; empty string means "not set".
    static func time(_ key: String, _ label: L10n, def: Double? = nil, allowEmpty: Bool = true, placeholder: L10n? = nil) -> OptionField {
        OptionField(key: key, kind: .time(TimeSpec(allowEmpty: allowEmpty, placeholder: placeholder)), label: label,
                    defaultValue: .value(def.map { .double($0) } ?? .string("")))
    }
    static func number(_ key: String, _ label: L10n, min: Double? = nil, max: Double? = nil, step: Double = 1, def: Double, unit: String? = nil, decimals: Int = 0) -> OptionField {
        OptionField(key: key, kind: .number(NumberSpec(min: min, max: max, step: step, unit: unit, decimals: decimals)), label: label, unit: unit,
                    defaultValue: .value(decimals == 0 && step == step.rounded() ? .int(Int(def)) : .double(def)))
    }
    static func folder(_ key: String, _ label: L10n, def: String = "") -> OptionField {
        OptionField(key: key, kind: .folder, label: label, defaultValue: .value(.string(def)))
    }
    static func file(_ key: String, _ label: L10n, types: [UTType] = [.item], def: String = "") -> OptionField {
        OptionField(key: key, kind: .file(FileSpec(types: types)), label: label, defaultValue: .value(.string(def)))
    }
    /// `#RRGGBB` text with a colour well.
    static func color(_ key: String, _ label: L10n, def: String = "#FFFFFF") -> OptionField {
        OptionField(key: key, kind: .color, label: label, defaultValue: .value(.string(def)))
    }
    /// Repeatable rows. `defaultRows` may be computed from the source (one row per audio track, ...).
    static func tracks(_ key: String, _ label: L10n, _ spec: TrackSpec, defaultRows: @escaping @Sendable (SourceInfo?) -> [[String: OptionValue]] = { _ in [] }) -> OptionField {
        OptionField(key: key, kind: .tracks(spec), label: label,
                    defaultValue: .computed({ .rows(defaultRows($0)) }, fallback: .list([])))
    }

    // MARK: Modifiers

    func basic() -> OptionField { var f = self; f.level = .basic; return f }
    func standard() -> OptionField { var f = self; f.level = .standard; return f }
    func expert() -> OptionField { var f = self; f.level = .expert; return f }
    func help(_ h: L10n) -> OptionField { var f = self; f.help = h; return f }
    func unit(_ u: String) -> OptionField { var f = self; f.unit = u; return f }
    func visible(_ e: OptionExpr) -> OptionField { var f = self; f.visibleWhen = e; return f }
    func enabled(_ e: OptionExpr, reason: L10n? = nil) -> OptionField { var f = self; f.enabledWhen = e; if let reason { f.disabledReason = reason }; return f }
    func needs(_ caps: [String], reason: L10n? = nil) -> OptionField { var f = self; f.requires = caps; if let reason { f.disabledReason = reason }; return f }
    func rule(_ r: ValidationRule) -> OptionField { var f = self; f.rules.append(r); return f }
    func affects(_ a: OptionAffects) -> OptionField { var f = self; f.affects = a; return f }
    func oracle(_ id: String) -> OptionField { var f = self; f.oracle = id; return f }
    func aliases(_ words: [String]) -> OptionField { var f = self; f.aliases = words; return f }
    /// Default computed from the probed source; `fallback` is used when the source is unknown.
    func defaultFromSource(_ fallback: OptionValue, _ f: @escaping @Sendable (SourceInfo?) -> OptionValue?) -> OptionField {
        var c = self; c.defaultValue = .computed(f, fallback: fallback); return c
    }
}

extension ValidationRule {
    static func error(_ id: String, when: OptionExpr, _ message: L10n, field: String? = nil, fix: OptionFix? = nil) -> ValidationRule {
        ValidationRule(id: id, severity: .error, when: when, message: message, fieldKey: field, fix: fix)
    }
    static func warning(_ id: String, when: OptionExpr, _ message: L10n, field: String? = nil, fix: OptionFix? = nil) -> ValidationRule {
        ValidationRule(id: id, severity: .warning, when: when, message: message, fieldKey: field, fix: fix)
    }
    static func info(_ id: String, when: OptionExpr, _ message: L10n, field: String? = nil, fix: OptionFix? = nil) -> ValidationRule {
        ValidationRule(id: id, severity: .info, when: when, message: message, fieldKey: field, fix: fix)
    }
}

extension OptionGroup {
    /// Convenience with the most common arguments.
    static func make(_ id: String, _ title: L10n? = nil, level: OptionLevel = .basic, collapsed: Bool = false, footer: L10n? = nil,
                     visible: OptionExpr? = nil, _ fields: [OptionField]) -> OptionGroup {
        OptionGroup(id: id, title: title, footer: footer, level: level, collapsed: collapsed, fields: fields, visibleWhen: visible)
    }
}

extension OptionGroup {
    /// Untitled group of fields: `.make("main", [ ...fields ])`.
    static func make(_ id: String, _ fields: [OptionField]) -> OptionGroup { OptionGroup(id: id, fields: fields) }
}

extension OptionPage {
    static func make(_ id: String, symbol: String, _ title: L10n, visible: OptionExpr? = nil, requires: [String] = [], _ groups: [OptionGroup]) -> OptionPage {
        OptionPage(id: id, symbol: symbol, title: title, groups: groups, visibleWhen: visible, requires: requires)
    }
}

/// The output-rules page every Studio schema ends with (spec/handbrake.md 2.11). Keys are prefixed "out." and are
/// stored with the job, not with the preset. Engines append it with `OptionSchema.withOutputPage()`.
extension OptionSchema {
    func withOutputPage() -> OptionSchema {
        var s = self
        guard !s.pages.contains(where: { $0.id == "output" }) else { return s }
        let page = OptionPage.make("output", symbol: "folder", L10n("Output", "Вывод"), [
            OptionGroup.make("out.where", L10n("Destination", "Назначение"), [
                .picker("out.dirMode", L10n("Save to", "Куда сохранять"), [
                    FieldOption("sameAsSource", L10n("Next to the original", "Рядом с исходником")),
                    FieldOption("subfolder", L10n("Subfolder", "Подпапка")),
                    FieldOption("custom", L10n("Chosen folder", "Выбранная папка"))
                ], def: "sameAsSource").basic().affects([]),
                .text("out.subfolder", L10n("Subfolder name", "Имя подпапки"), def: "Converted").visible(.eq("out.dirMode", "subfolder")).affects([]),
                .folder("out.dir", L10n("Folder", "Папка")).visible(.eq("out.dirMode", "custom")).affects([]),
                .text("out.name", L10n("File name", "Имя файла"), def: "{name}",
                      placeholder: L10n("{name} ({preset})", "{name} ({preset})"))
                    .help(L10n("Tokens: {name} {suffix} {preset} {date} {time}; for video also {codec} {res} {width} {height} {fps} {quality} {container}",
                               "Метки: {name} {suffix} {preset} {date} {time}; для видео ещё {codec} {res} {width} {height} {fps} {quality} {container}"))
                    .affects([]),
                .picker("out.collision", L10n("If the file exists", "Если файл уже есть"), [
                    FieldOption("number", L10n("Add a number", "Добавить номер")),
                    FieldOption("replace", L10n("Replace (old one goes to the Trash)", "Заменить (старый уйдёт в Корзину)")),
                    FieldOption("skip", L10n("Skip", "Пропустить"))
                ], def: "number").affects([])
            ]),
            OptionGroup.make("out.after", L10n("After conversion", "После конвертации"), level: .standard, [
                .toggle("out.keepDates", L10n("Keep original dates", "Сохранить исходные даты"), def: true).affects([]),
                .toggle("out.trashSource", L10n("Move original to Trash after success", "После успеха переместить оригинал в Корзину")).affects([]),
                .toggle("out.verify", L10n("Check the result", "Проверять результат"), def: true).affects([]),
                .picker("out.after", L10n("When finished", "По завершении"), [
                    FieldOption("nothing", L10n("Do nothing", "Ничего")),
                    FieldOption("reveal", L10n("Show in Finder", "Показать в Finder")),
                    FieldOption("open", L10n("Open", "Открыть")),
                    FieldOption("notify", L10n("Notify", "Уведомить"))
                ], def: "nothing").affects([])
            ])
        ])
        s.pages.append(page)
        return s
    }
}

extension OutputRules {
    /// Builds rules from `out.*` option keys (missing keys keep `base`'s values).
    init(options v: OptionValues, base: OutputRules = .default) {
        self = base
        if let m = v["out.dirMode"]?.asString, let mode = OutputDirMode(rawValue: m) { dirMode = mode }
        if v.has("out.subfolder") { subfolderName = v.string("out.subfolder", subfolderName) }
        if let d = v["out.dir"]?.asString, !d.isEmpty { customDir = d }
        if v.has("out.name"), !v.string("out.name").isEmpty { nameTemplate = v.string("out.name") }
        if let c = v["out.collision"]?.asString, let col = OutputCollision(rawValue: c) { collision = col }
        if v.has("out.keepDates") { keepDates = v.bool("out.keepDates", keepDates) }
        if v.has("out.trashSource") { trashSource = v.bool("out.trashSource", trashSource) }
        if v.has("out.verify") { verify = v.bool("out.verify", verify) }
        if let a = v["out.after"]?.asString, let af = AfterFinish(rawValue: a) { after = af }
    }

    /// Inverse of `init(options:)`, for showing rules in the Output page.
    var optionValues: OptionValues {
        var v = OptionValues()
        v["out.dirMode"] = .string(dirMode.rawValue)
        v["out.subfolder"] = .string(subfolderName)
        v["out.dir"] = .string(customDir ?? "")
        v["out.name"] = .string(nameTemplate)
        v["out.collision"] = .string(collision.rawValue)
        v["out.keepDates"] = .bool(keepDates)
        v["out.trashSource"] = .bool(trashSource)
        v["out.verify"] = .bool(verify)
        v["out.after"] = .string(after.rawValue)
        return v
    }
}
