import Foundation
import UniformTypeIdentifiers

// The declarative description of every setting of an operation: pages > groups > fields.
// ONE schema drives (a) the Quick sheet, (b) the Studio inspector, (c) preset validation, (d) the self-test
// harness. Engines build schemas in code (see OptionSchemaBuilder.swift for compact factories).
//
// Level: basic fields show in Simple density, standard in Advanced, expert behind "More..." or search only.
// Conditions: `visibleWhen` hides, `enabledWhen` disables (with `disabledReason`), `requires` lists capability ids
// (Capabilities.swift); a missing capability disables the control and shows "Needs ffmpeg ..." -- never hides it.

enum OptionLevel: Int, Codable, Comparable, Sendable {
    case basic = 0, standard = 1, expert = 2
    static func < (a: OptionLevel, b: OptionLevel) -> Bool { a.rawValue < b.rawValue }
}

enum OptionSeverity: Int, Codable, Comparable, Sendable {
    case info = 0, warning = 1, error = 2
    static func < (a: OptionSeverity, b: OptionSeverity) -> Bool { a.rawValue < b.rawValue }
    var symbol: String {
        switch self { case .info: return "info.circle"; case .warning: return "exclamationmark.triangle"; case .error: return "xmark.octagon" }
    }
}

/// What to refresh when a field changes (Studio: size estimate, preview, plan).
struct OptionAffects: OptionSet, Sendable {
    let rawValue: Int
    static let estimate = OptionAffects(rawValue: 1)
    static let preview = OptionAffects(rawValue: 2)
    static let plan = OptionAffects(rawValue: 4)
}

struct FieldOption: Sendable {
    var value: String
    var label: L10n
    var symbol: String? = nil
    var enabledWhen: OptionExpr? = nil
    var requires: [String] = []
    var hint: L10n? = nil
    init(_ value: String, _ label: L10n, symbol: String? = nil, enabledWhen: OptionExpr? = nil, requires: [String] = [], hint: L10n? = nil) {
        self.value = value; self.label = label; self.symbol = symbol; self.enabledWhen = enabledWhen; self.requires = requires; self.hint = hint
    }
    /// A label that is the same in both languages ("MP4", "H.264").
    init(_ value: String, _ label: String, symbol: String? = nil, enabledWhen: OptionExpr? = nil, requires: [String] = [], hint: L10n? = nil) {
        self.init(value, L10n(label), symbol: symbol, enabledWhen: enabledWhen, requires: requires, hint: hint)
    }
}

struct SliderSpec: Sendable {
    var min: Double
    var max: Double
    var step: Double = 1
    var unit: String? = nil
    var logarithmic = false
    /// Direction words under the slider ends: "Smaller file" ... "Better quality".
    var minLabel: L10n? = nil
    var maxLabel: L10n? = nil
    var decimals = 0
}

struct StepperSpec: Sendable {
    var min: Int
    var max: Int
    var step: Int = 1
    var unit: String? = nil
}

struct NumberSpec: Sendable {
    var min: Double? = nil
    var max: Double? = nil
    var step: Double = 1
    var unit: String? = nil
    var decimals = 0
    var placeholder: L10n? = nil
}

enum TextValidation: Sendable { case none, pageRange, timeList, hexColor, integerList, regex(String) }

struct TextSpec: Sendable {
    var placeholder: L10n? = nil
    var multiline = false
    var validation: TextValidation = .none
    /// Passwords: shown masked, held in memory only, never written to presets, queue files or logs.
    var secure = false
}

struct TimeSpec: Sendable {
    /// Empty value means "not set" (e.g. trim end = until the end).
    var allowEmpty = true
    var placeholder: L10n? = nil
}

struct FileSpec: Sendable {
    var types: [UTType] = [.item]
    var prompt: L10n = L10n("Choose File…", "Выбрать файл…")
}

struct TrackSpec: Sendable {
    /// Columns of one row; each column is a normal field (no nested `tracks`).
    var columns: [OptionField]
    var maxRows: Int? = nil
    /// Key of the column used as the row title.
    var rowTitleKey: String? = nil
    var addTitle: L10n = L10n("Add Track", "Добавить дорожку")
    var allowReorder = true
}

enum FieldKind: Sendable {
    case toggle
    case picker([FieldOption])
    case segmented([FieldOption])
    case slider(SliderSpec)
    case stepper(StepperSpec)
    case text(TextSpec)
    case time(TimeSpec)
    case number(NumberSpec)
    case folder
    case file(FileSpec)
    case color
    case tracks(TrackSpec)
}

/// Default value of a field: literal or computed from the source ("nearest standard height not above the source").
enum FieldDefault: Sendable {
    case value(OptionValue)
    case computed(@Sendable (SourceInfo?) -> OptionValue?, fallback: OptionValue)

    func resolve(_ source: SourceInfo?) -> OptionValue {
        switch self {
        case .value(let v): return v
        case .computed(let f, let fallback): return f(source) ?? fallback
        }
    }
}

struct OptionFix: Sendable {
    var title: L10n
    var set: [String: OptionValue]
}

/// A cross-field rule. `message` may contain `{placeholders}` replaced from `OptionMessage.args`.
struct ValidationRule: Sendable {
    var id: String
    var severity: OptionSeverity
    var when: OptionExpr
    var message: L10n
    var fieldKey: String? = nil
    var fix: OptionFix? = nil
}

struct OptionMessage: Identifiable, Sendable {
    var id: String
    var severity: OptionSeverity
    var text: L10n
    var fieldKey: String? = nil
    var fix: OptionFix? = nil
}

struct OptionField: Sendable {
    /// Stable dotted key, unique inside one schema; also the JSON key in presets (e.g. "video.crf").
    var key: String
    var kind: FieldKind
    var label: L10n
    var help: L10n? = nil
    /// Unit shown next to the value ("kbit/s", "px"). Sliders/steppers/numbers may also carry it in their spec.
    var unit: String? = nil
    var defaultValue: FieldDefault
    var level: OptionLevel = .standard
    var visibleWhen: OptionExpr? = nil
    var enabledWhen: OptionExpr? = nil
    /// Capability ids that must all be present, else the control is disabled with `disabledReason` (or the generic hint).
    var requires: [String] = []
    var disabledReason: L10n? = nil
    var rules: [ValidationRule] = []
    var affects: OptionAffects = [.estimate, .plan]
    /// Id of the output probe that proves this option has a real effect (spec/handbrake.md section 5.4).
    /// The self-test harness refuses a field without one.
    var oracle: String = ""
    /// Extra search words in both languages ("crf", "битрейт").
    var aliases: [String] = []
    /// False for secrets: excluded from presets, queue persistence and logs.
    var persist = true

    var defaultOptionValue: OptionValue { defaultValue.resolve(nil) }
}

struct OptionGroup: Sendable {
    var id: String
    var title: L10n? = nil
    var footer: L10n? = nil
    var level: OptionLevel = .basic
    var collapsed = false
    var fields: [OptionField]
    var visibleWhen: OptionExpr? = nil
}

struct OptionPage: Sendable {
    var id: String
    /// SF Symbol shown on the page switcher.
    var symbol: String
    var title: L10n
    var groups: [OptionGroup]
    var visibleWhen: OptionExpr? = nil
    var requires: [String] = []
}

struct OptionSchema: Sendable {
    /// Studio target id, e.g. "video.convert", "image.convert", "pdf.optimize". All operations sharing an id share this schema.
    var id: String
    var version: Int = 1
    var title: L10n
    var symbol: String = "slider.horizontal.3"
    var pages: [OptionPage]
    /// Cross-field rules not tied to one field.
    var rules: [ValidationRule] = []

    static func empty(id: String, title: L10n = L10n("Options", "Параметры")) -> OptionSchema {
        OptionSchema(id: id, title: title, pages: [])
    }

    var allFields: [OptionField] {
        pages.flatMap { $0.groups.flatMap { $0.fields } }
    }

    func field(_ key: String) -> OptionField? {
        for p in pages { for g in p.groups { if let f = g.fields.first(where: { $0.key == key }) { return f } } }
        return nil
    }
}
