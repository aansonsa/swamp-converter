import SwiftUI

// Offscreen snapshots of the renderer (`./build.sh snapshot <dir> studio-core`). Every view runs on the fixture session (a fake 4K clip with two audio streams),
// so the pictures show real states: defaults, edits, a locked field, a disabled field with its reason, warnings and an error with fixes, search, collapsed groups.

@MainActor
enum StudioCoreSnapshots {
    private static var harness: StudioHarness?

    static func makeSession(density: DensitySetting = .simple, page: String = "main", showExpert: Bool = false, scenario: Scenario = .plain) -> StudioSession {
        let h = harness ?? StudioHarness()
        harness = h
        h.presets.registerBuiltins([
            Preset.builtin("web", target: StudioFixture.schemaID, L10n("Web 1080p", "Веб 1080p"), symbol: "globe", group: .web, [FixtureKeys.quality: 24, FixtureKeys.container: "mp4"]),
            Preset.builtin("phone", target: StudioFixture.schemaID, L10n("iPhone", "iPhone"), symbol: "iphone", group: .devices, [FixtureKeys.quality: 22]),
            Preset.builtin("small", target: StudioFixture.schemaID, L10n("Small file", "Малый файл"), symbol: "arrow.down.right.and.arrow.up.left", group: .smallSize, [FixtureKeys.quality: 34]),
            Preset.builtin("lossless", target: StudioFixture.schemaID, L10n("Lossless", "Без потерь"), symbol: "checkmark.seal", group: .lossless, [FixtureKeys.quality: 0])
        ])
        let file = FileItem(url: URL(fileURLWithPath: "/Users/demo/Movies/Holiday in Riga.mov"), isDirectory: false, size: 412_000_000)
        let s = h.session(files: [file], target: "test.studio.a")
        s.applyProbe(StudioFixture.sourceInfo(for: file.url, kind: .video), forSourceID: s.sources[0].id)
        s.density = density
        s.showExpert = showExpert
        s.selectedPageID = page
        scenario.apply(to: s, harness: h)
        return s
    }

    enum Scenario {
        case plain, edited, locked, search
        @MainActor func apply(to s: StudioSession, harness h: StudioHarness) {
            switch self {
            case .plain: break
            case .edited:
                s.apply(preset: h.presets.preset(id: "builtin.web")!)
                s.set(FixtureKeys.quality, 45); s.set(FixtureKeys.rc, "abr"); s.set(FixtureKeys.bitrate, 8000); s.set(FixtureKeys.mode, "universal")
                s.set(FixtureKeys.trimStart, 20.0); s.set(FixtureKeys.trimEnd, 8.0); s.set(FixtureKeys.title, "Holiday in Riga"); s.set(FixtureKeys.gated, true)
                s.set(FixtureKeys.tracks, .rows([["source": 1, "codec": "aac", "bitrate": 192, "lang": "en", "title": "English"], ["source": 2, "codec": "copy", "bitrate": 160, "lang": "ru", "title": "Русский"]]))
            case .locked:
                if let p = try? s.saveAsPreset(name: "Studio master", symbol: "star", group: .custom, locks: [FixtureKeys.quality, FixtureKeys.container], onWheel: nil) { _ = p }
            case .search:
                s.searchText = "bitrate"
            }
        }
    }

    static func register() {
        let r = SnapshotRegistry.shared
        let inspector = CGSize(width: 380, height: 780)
        r.register("studio-core.inspector-simple", size: inspector, backdrop: .windowBackground, chrome: .window(title: "Studio"), variants: SnapshotVariant.lightDarkRu) {
            OptionFormView(session: makeSession()).appRoot()
        }
        r.register("studio-core.inspector-advanced", size: CGSize(width: 380, height: 1300), backdrop: .windowBackground, variants: [.light, .dark]) {
            OptionFormView(session: makeSession(density: .advanced, showExpert: true)).appRoot()
        }
        r.register("studio-core.inspector-edited", size: CGSize(width: 380, height: 1500), backdrop: .windowBackground, variants: SnapshotVariant.lightDarkRu) {
            OptionFormView(session: makeSession(density: .advanced, scenario: .edited)).appRoot()
        }
        r.register("studio-core.inspector-locked", size: CGSize(width: 380, height: 700), backdrop: .windowBackground, variants: [.light, .dark]) {
            OptionFormView(session: makeSession(scenario: .locked)).appRoot()
        }
        r.register("studio-core.inspector-search", size: CGSize(width: 380, height: 560), backdrop: .windowBackground, variants: SnapshotVariant.lightDarkRu) {
            OptionFormView(session: makeSession(density: .advanced, scenario: .search)).appRoot()
        }
        r.register("studio-core.inspector-more", size: CGSize(width: 380, height: 640), backdrop: .windowBackground, variants: [.light, .dark, SnapshotVariant(dark: false, language: .ru)]) {
            OptionFormView(session: makeSession(page: "extra")).appRoot()
        }
        r.register("studio-core.inspector-a11y", size: CGSize(width: 380, height: 780), backdrop: .windowBackground, variants: SnapshotVariant.accessibility) {
            OptionFormView(session: makeSession(scenario: .edited)).appRoot()
        }
        r.register("studio-core.fields", size: CGSize(width: 420, height: 1180), backdrop: .windowBackground, variants: SnapshotVariant.lightDarkRu) { FieldGallery().appRoot() }
        r.register("studio-core.tracks", size: CGSize(width: 400, height: 560), backdrop: .windowBackground, variants: [.light, .dark, SnapshotVariant(dark: false, language: .ru)]) { TrackGallery().appRoot() }
        r.register("studio-core.source", size: CGSize(width: 400, height: 560), backdrop: .windowBackground, variants: SnapshotVariant.lightDarkRu) { SourceGallery().appRoot() }
        r.register("studio-core.summary", size: CGSize(width: 400, height: 360), backdrop: .wallpaper, variants: SnapshotVariant.lightDarkRu + SnapshotVariant.accessibility) { SummaryGallery().appRoot() }
        r.register("studio-core.presets", size: CGSize(width: 420, height: 520), backdrop: .windowBackground, variants: [.light, .dark, SnapshotVariant(dark: false, language: .ru)]) { PresetGallery().appRoot() }
        r.register("studio-core.save-preset", size: CGSize(width: 420, height: 520), backdrop: .windowBackground, variants: [.light, .dark, SnapshotVariant(dark: false, language: .ru)]) {
            SavePresetSheet(session: makeSession(scenario: .edited)).appRoot()
        }
    }
}

// MARK: - Galleries

/// Every field kind in a grouped form, standalone (no session): default, changed (chip + revert), disabled with a reason, locked, with a message and a fix.
private struct FieldGallery: View {
    @State private var values: [String: OptionValue] = [:]
    private let schema = StudioFixture.schema()

    private func binding(_ f: OptionField) -> Binding<OptionValue> {
        Binding(get: { values[f.key] ?? f.defaultValue.resolve(nil) }, set: { values[f.key] = $0 })
    }

    private func ctx(_ f: OptionField) -> OptionFieldContext {
        var c = OptionFieldContext()
        c.defaultValue = f.defaultValue.resolve(nil)
        switch f.key {
        case FixtureKeys.quality:
            c.isDefault = false; c.defaultValue = .int(23)
            c.messages = [OptionMessage(id: "q", severity: .warning, text: L10n("This quality loses a lot of detail. The typical range is 18 to 30.", "При таком качестве теряется много деталей. Обычный диапазон - от 18 до 30."), fieldKey: f.key,
                                        fix: OptionFix(title: L10n("Use 30", "Взять 30"), set: [:]))]
        case FixtureKeys.bitrate: c.isEnabled = false; c.disabledReason = f.disabledReason
        case FixtureKeys.gated: c.isEnabled = false; c.disabledReason = f.disabledReason
        case FixtureKeys.container: c.isDefault = false; c.defaultValue = .string("mp4")
        case FixtureKeys.trimEnd:
            c.messages = [OptionMessage(id: "e", severity: .error, text: L10n("The end must come after the start.", "Конец должен быть позже начала."), fieldKey: f.key)]
        case FixtureKeys.password: c.isEnabled = false; c.isLocked = true; c.disabledReason = OptionFormLogic.lockedReason(presetName: L10n("Studio master"))
        default: break
        }
        return c
    }

    var body: some View {
        let keys = [FixtureKeys.container, FixtureKeys.mode, FixtureKeys.fast, FixtureKeys.quality, FixtureKeys.bitrate, FixtureKeys.refs, FixtureKeys.maxrate,
                    FixtureKeys.gated, FixtureKeys.trimStart, FixtureKeys.trimEnd, FixtureKeys.title, FixtureKeys.password, FixtureKeys.bg, FixtureKeys.outdir, FixtureKeys.cover]
        Form {
            Section(L("Every kind", "Все виды")) {
                ForEach(keys, id: \.self) { k in
                    if let f = schema.field(k) { OptionFieldView(field: f, value: binding(f), context: ctx(f), onRevert: {}) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TrackGallery: View {
    @State private var rows: [[String: OptionValue]] = [
        ["source": 1, "codec": "aac", "bitrate": 192, "lang": "en", "title": "English"],
        ["source": 2, "codec": "copy", "bitrate": 160, "lang": "ru", "title": "Русский"]
    ]
    private let schema = StudioFixture.schema()

    var body: some View {
        let field = schema.field(FixtureKeys.tracks)!
        let info = StudioFixture.sourceInfo(for: URL(fileURLWithPath: "/tmp/x.mov"))
        Form {
            Section(L("Audio tracks", "Аудиодорожки")) {
                if case .tracks(let spec) = field.kind { TrackListEditor(field: field, spec: spec, rows: $rows, source: info) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SourceGallery: View {
    var body: some View {
        let url = URL(fileURLWithPath: "/Users/demo/Movies/Holiday in Riga.mov")
        let file = FileItem(url: url, isDirectory: false, size: 412_000_000)
        var ready = StudioSource(input: .file(file)); ready.info = StudioFixture.sourceInfo(for: url, kind: .video); ready.status = .ready
        let probing = StudioSource(input: .file(FileItem(url: URL(fileURLWithPath: "/Users/demo/Movies/Reading this one.mp4"), isDirectory: false)))
        var failed = StudioSource(input: .file(FileItem(url: URL(fileURLWithPath: "/Users/demo/Movies/Gone.mov"), isDirectory: false)))
        failed.status = .failed(L("The file can’t be found.", "Файл не найден."))
        var link = StudioSource(input: .link(LinkItem(url: URL(string: "https://www.youtube.com/watch?v=abc123")!, title: "A very long video title that goes on and on for two lines of text", sourceName: "Safari")))
        link.status = .ready
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                SourceInspectorView(source: ready)
                SourceInspectorView(source: probing)
                SourceInspectorView(source: failed)
                SourceInspectorView(source: link)
            }
            .padding(DS.Space.lg)
        }
    }
}

private struct SummaryGallery: View {
    var body: some View {
        VStack(spacing: DS.Space.lg) {
            SummaryCapsule(session: StudioCoreSnapshots.makeSession())
            SummaryCapsule(session: StudioCoreSnapshots.makeSession(density: .advanced, scenario: .edited))
        }
        .padding(DS.Space.lg)
    }
}

private struct PresetGallery: View {
    var body: some View {
        let s = StudioCoreSnapshots.makeSession(scenario: .edited)
        return VStack(alignment: .leading, spacing: DS.Space.lg) {
            PresetBar(session: s)
            ChangesListView(session: s).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
    }
}
