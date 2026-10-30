import Foundation

// Fake operations for the Settings self-tests and snapshots: a private registry with a few predictable operations, so the layout editor, the quick-recipe editor and the
// parameter sheet are exercised without depending on which engines are installed.

final class SettingsFakeOperation: PerFileOperation, @unchecked Sendable {
    private let fields: [OptionField]
    private let overrides: OptionValues

    init(id: String, label: String, wheel: WheelKind = .convert, family: OperationFamily = .image, inputs: Set<String> = ["jpg", "png"], target: String? = nil,
         symbol: String = "photo", fields: [OptionField] = [], prompt: [String] = [], overrides: OptionValues = OptionValues(), studioOnly: Bool = false) {
        self.fields = fields
        self.overrides = overrides
        var m = OperationMeta(id: id, wheel: wheel, family: family, label: L10n(label), symbol: symbol, schemaID: id)
        m.inputs = inputs
        m.targetFormat = target
        m.quickPromptKeys = prompt
        m.studioOnly = studioOnly
        super.init(meta: m)
    }

    override func quickOverrides(settings: SettingsData) -> OptionValues { overrides }

    override func optionSchema(for items: [FileItem]) -> OptionSchema {
        OptionSchema(id: meta.schemaID, title: meta.label, pages: fields.isEmpty ? [] : [OptionPage.make("main", symbol: "slider.horizontal.3", meta.label, [OptionGroup.make("g", fields)])])
    }

    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] { [] }
}

enum SettingsFixtures {
    /// `count` convert operations for images ("fake.0" ... ) in a private registry.
    static func registry(convertCount count: Int) -> OperationRegistry {
        let r = OperationRegistry()
        for i in 0..<count {
            r.register(SettingsFakeOperation(id: "fake.\(i)", label: "Fake \(i)", inputs: ["jpg", "png", "heic"]))
        }
        return r
    }

    /// An operation that asks for a trim and a password, as `QuickRun` would.
    static var trimOperation: SettingsFakeOperation {
        SettingsFakeOperation(id: "fake.trim", label: "Trim", wheel: .tools, family: .video, inputs: ["mp4"], symbol: "scissors",
                              fields: [.time("trim.start", L10n("Start", "Начало")).basic(), .time("trim.end", L10n("End", "Конец")).basic(),
                                       .text("pdf.password", L10n("Password", "Пароль"), secure: true).basic(),
                                       .slider("quality", L10n("Quality", "Качество"), min: 10, max: 100, def: 80).basic()],
                              prompt: ["trim.start", "trim.end", "pdf.password"])
    }
}
