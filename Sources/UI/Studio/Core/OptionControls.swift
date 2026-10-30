import SwiftUI
import AppKit
import UniformTypeIdentifiers

// One native control per FieldKind. `OptionFieldView` adds the label, the help, the reason, the default chip and the messages around them.

struct OptionControl: View {
    var field: OptionField
    @Binding var value: OptionValue
    var context: OptionFieldContext
    @Binding var problem: L10n?
    var onEditingChanged: ((Bool) -> Void)?
    /// Segmented fields that do not fit show as a menu.
    var segmentedAsMenu = false

    var body: some View {
        switch field.kind {
        case .toggle:
            Toggle(field.label.text, isOn: Binding(get: { value.asBool ?? false }, set: { value = .bool($0) }))
                .labelsHidden().toggleStyle(.switch)
        case .picker(let opts):
            OptionPickerControl(title: field.label.text, options: opts, selection: stringBinding, env: context.optionEnvironment)
        case .segmented(let opts):
            OptionSegmentedControl(title: field.label.text, options: opts, selection: stringBinding, env: context.optionEnvironment, asMenu: segmentedAsMenu)
        case .slider(let spec):
            OptionSliderControl(field: field, spec: spec, value: $value, onEditingChanged: onEditingChanged)
        case .stepper(let spec):
            OptionStepperControl(title: field.label.text, spec: spec, fallbackUnit: field.unit, value: $value)
        case .text(let spec):
            OptionTextControl(title: field.label.text, spec: spec, text: stringBinding)
        case .time(let spec):
            OptionTimeControl(title: field.label.text, spec: spec, value: $value, problem: $problem)
        case .number(let spec):
            OptionNumberControl(title: field.label.text, spec: spec, fallbackUnit: field.unit, value: $value, problem: $problem)
        case .folder:
            OptionPathControl(title: field.label.text, isFolder: true, types: [], prompt: L10n("Choose Folder…", "Выбрать папку…"), path: stringBinding)
        case .file(let spec):
            OptionPathControl(title: field.label.text, isFolder: false, types: spec.types, prompt: spec.prompt, path: stringBinding)
        case .color:
            OptionColorControl(title: field.label.text, hex: stringBinding)
        case .tracks(let spec):
            TrackListEditor(field: field, spec: spec, rows: Binding(get: { value.asRows ?? [] }, set: { value = .rows($0) }), source: context.source)
        }
    }

    private var stringBinding: Binding<String> {
        Binding(get: { value.asString ?? "" }, set: { value = .string($0) })
    }
}

// MARK: Picker and segmented

private func menuTitle(_ o: FieldOption, enabled: Bool, hint: L10n?) -> String {
    if !enabled, let h = hint { return "\(o.label.text) \u{2014} \(h.text)" }
    return o.label.text
}

struct OptionPickerControl: View {
    var title: String
    var options: [FieldOption]
    @Binding var selection: String
    var env: ExprEnvironment?

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let av = OptionFormLogic.availability(of: o, env: env)
                Text(menuTitle(o, enabled: av.enabled, hint: av.hint)).tag(o.value).disabled(!av.enabled)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityLabel(Text(title))
    }
}

/// A segmented control while the labels fit and every option is usable; a pop-up menu otherwise (a segment cannot be disabled, and Russian labels run long).
struct OptionSegmentedControl: View {
    var title: String
    var options: [FieldOption]
    @Binding var selection: String
    var env: ExprEnvironment?
    /// The field row decides the layout: the segmented control goes under the label, the menu beside it (`OptionFieldView`).
    var asMenu = false

    /// Every option can be chosen (a segment can't be disabled, so any gap forces the menu).
    static func allUsable(_ options: [FieldOption], env: ExprEnvironment?) -> Bool {
        options.allSatisfy { OptionFormLogic.availability(of: $0, env: env).enabled }
    }

    var body: some View {
        if !asMenu && Self.allUsable(options, env: env) {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].label.text).tag(options[$0].value) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
        } else {
            OptionPickerControl(title: title, options: options, selection: $selection, env: env)
        }
    }
}

// MARK: Slider and stepper

/// Slider with the value (shown by the field row), direction words under the ends ("Smaller file" ... "Better quality") and a spoken value.
/// Few steps (12 or fewer) use the system's stepped slider with its tick marks; many steps use a smooth slider that snaps in code (a 52-step quality slider with 52
/// ticks is noise). Arrow keys always move by one schema step: when a key press is too small to reach the next step, it is turned into a one-step move.
/// Logarithmic sliders map through `OptionSlider`.
struct OptionSliderControl: View {
    var field: OptionField
    var spec: SliderSpec
    @Binding var value: OptionValue
    var onEditingChanged: ((Bool) -> Void)?
    @State private var dragging = false

    private var current: Double { Util.clamp(value.asDouble ?? spec.min, spec.min, spec.max) }
    private var stepCount: Int { spec.step > 0 ? Int(((spec.max - spec.min) / spec.step).rounded()) : Int.max }
    private var useNativeSteps: Bool { !(spec.logarithmic && spec.min > 0) && stepCount <= 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            slider
                .accessibilityLabel(Text(field.label.text))
                .accessibilityValue(Text(OptionSlider.spoken(value: current, spec: spec, fallbackUnit: field.unit)))
                .accessibilityHint(Text(OptionSlider.direction(spec: spec) ?? ""))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: assign(OptionSlider.snap(current + stepSize, spec: spec))
                    case .decrement: assign(OptionSlider.snap(current - stepSize, spec: spec))
                    @unknown default: break
                    }
                }
            if spec.minLabel != nil || spec.maxLabel != nil {
                HStack(alignment: .top, spacing: DS.Space.md) {
                    Text(spec.minLabel?.text ?? "").multilineTextAlignment(.leading)
                    Spacer(minLength: DS.Space.sm)
                    Text(spec.maxLabel?.text ?? "").multilineTextAlignment(.trailing)
                }
                .font(DS.Typo.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One keyboard / VoiceOver step: the schema's step, or 1% of a log range.
    private var stepSize: Double { OptionSlider.stepSize(spec: spec) }

    private func editing(_ on: Bool) { dragging = on; onEditingChanged?(on) }

    @ViewBuilder private var slider: some View {
        if useNativeSteps {
            Slider(value: Binding(get: { current }, set: { assign(OptionSlider.snap($0, spec: spec)) }),
                   in: spec.min...spec.max, step: spec.step, onEditingChanged: editing)
        } else if spec.logarithmic && spec.min > 0 {
            Slider(value: Binding(get: { OptionSlider.position(of: current, spec: spec) },
                                  set: { assign(nudged(OptionSlider.value(atPosition: $0, spec: spec), raw: OptionSlider.value(atPosition: $0, spec: spec))) }),
                   in: 0...1, onEditingChanged: editing)
        } else {
            Slider(value: Binding(get: { current }, set: { raw in assign(nudged(OptionSlider.snap(raw, spec: spec), raw: raw)) }),
                   in: spec.min...spec.max, onEditingChanged: editing)
        }
    }

    private func nudged(_ snapped: Double, raw: Double) -> Double {
        OptionSlider.nudged(snapped: snapped, raw: raw, current: current, dragging: dragging, spec: spec)
    }

    private func assign(_ v: Double) {
        guard abs(v - current) > 1e-9 else { return }
        value = OptionSlider.stored(v, spec: spec)
    }
}

struct OptionStepperControl: View {
    var title: String
    var spec: StepperSpec
    var fallbackUnit: String?
    @Binding var value: OptionValue

    var body: some View {
        let v = Util.clamp(value.asInt ?? spec.min, spec.min, spec.max)
        HStack(spacing: DS.Space.sm) {
            Text([String(v), spec.unit ?? fallbackUnit].compactMap { $0 }.joined(separator: " "))
                .font(DS.Typo.numeric()).foregroundStyle(.secondary)
            Stepper(title, value: Binding(get: { v }, set: { value = .int(Util.clamp($0, spec.min, spec.max)) }), in: spec.min...spec.max, step: spec.step)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}

// MARK: Text, time, number

struct OptionTextControl: View {
    var title: String
    var spec: TextSpec
    @Binding var text: String

    var body: some View {
        Group {
            if spec.secure {
                SecureField(title, text: $text, prompt: spec.placeholder.map { Text($0.text) })
            } else if spec.multiline {
                TextField(title, text: $text, prompt: spec.placeholder.map { Text($0.text) }, axis: .vertical).lineLimit(3...6)
            } else {
                TextField(title, text: $text, prompt: spec.placeholder.map { Text($0.text) })
            }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .frame(minWidth: 120, idealWidth: 180, maxWidth: .infinity)
    }
}

/// `H:MM:SS.mmm`. Empty = not set. Typing is validated live; a half-typed value is kept as typed and only committed when it parses.
struct OptionTimeControl: View {
    var title: String
    var spec: TimeSpec
    @Binding var value: OptionValue
    @Binding var problem: L10n?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft, prompt: Text((spec.placeholder ?? L10n("Not set", "Не задано")).text))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(DS.Typo.numeric(.body))
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 110, idealWidth: 130, maxWidth: 160)
            .focused($focused)
            .onAppear { draft = OptionFormat.timeText(value) }
            .onChange(of: draft) { _, new in commit(new) }
            .onChange(of: value) { _, new in if !focused { draft = OptionFormat.timeText(new) } }
            .onChange(of: focused) { _, now in if !now { draft = OptionFormat.timeText(value); problem = nil } }
    }

    private func commit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            problem = nil
            if spec.allowEmpty { if OptionFormat.timeText(value) != "" { value = .string("") } }
            return
        }
        if let s = Util.parseTime(t) {
            problem = nil
            if abs((value.asDouble ?? -1) - s) > 0.0005 || OptionFormat.timeText(value).isEmpty { value = .double(s) }
        } else {
            problem = OptionFormat.timeProblem
        }
    }
}

struct OptionNumberControl: View {
    var title: String
    var spec: NumberSpec
    var fallbackUnit: String?
    @Binding var value: OptionValue
    @Binding var problem: L10n?
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var unit: String? { spec.unit ?? fallbackUnit }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            TextField(title, text: $draft, prompt: spec.placeholder.map { Text($0.text) })
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(DS.Typo.numeric(.body))
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 70, idealWidth: 90, maxWidth: 120)
                .focused($focused)
                .onAppear { draft = shown(value) }
                .onChange(of: draft) { _, new in commit(new) }
                .onChange(of: value) { _, new in if !focused { draft = shown(new) } }
                .onChange(of: focused) { _, now in if !now { draft = shown(value); problem = nil } }
            if let unit { Text(unit).foregroundStyle(.secondary) }
        }
    }

    private func shown(_ v: OptionValue) -> String { OptionFormat.number(v.asDouble ?? 0, decimals: spec.decimals) }

    private func commit(_ text: String) {
        guard let n = OptionFormat.parseNumber(text) else {
            problem = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : L10n("Enter a number.", "Введите число.")
            return
        }
        problem = nil
        var c = n
        if let lo = spec.min { c = max(c, lo) }
        if let hi = spec.max { c = min(c, hi) }
        let stored: OptionValue = spec.decimals == 0 && spec.step == spec.step.rounded() ? .int(Int(c.rounded())) : .double(c)
        if stored != value { value = stored }
    }
}

// MARK: Folder, file, colour

@MainActor
enum OptionPanels {
    static func chooseFolder(start: String, completion: @escaping (String) -> Void) {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.prompt = L("Choose", "Выбрать")
        if !start.isEmpty { p.directoryURL = URL(fileURLWithPath: start) }
        run(p) { completion($0.path) }
    }

    static func chooseFile(types: [UTType], start: String, prompt: L10n, completion: @escaping (String) -> Void) {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        if !types.isEmpty && types != [.item] { p.allowedContentTypes = types }
        p.prompt = prompt.text
        if !start.isEmpty { p.directoryURL = URL(fileURLWithPath: start).deletingLastPathComponent() }
        run(p) { completion($0.path) }
    }

    private static func run(_ panel: NSOpenPanel, _ done: @escaping (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { r in if r == .OK, let u = panel.url { done(u) } }
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }
}

struct OptionPathControl: View {
    var title: String
    var isFolder: Bool
    var types: [UTType]
    var prompt: L10n
    @Binding var path: String

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            if !path.isEmpty {
                Text(Self.shortPath(path)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing).help(path)
                Button { path = "" } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(Text(L("Clear", "Очистить")))
            }
            Button(path.isEmpty ? prompt.text : L("Change…", "Изменить…")) {
                if isFolder { OptionPanels.chooseFolder(start: path) { path = $0 } }
                else { OptionPanels.chooseFile(types: types, start: path, prompt: prompt) { path = $0 } }
            }
            .secondaryButtonLook()
            .accessibilityLabel(Text(title))
        }
    }

    /// "~/Movies/Exports" style: the last two components, home abbreviated.
    static func shortPath(_ p: String) -> String {
        let abbreviated = (p as NSString).abbreviatingWithTildeInPath
        let parts = abbreviated.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count <= 3 { return abbreviated }
        return ".../" + parts.suffix(2).joined(separator: "/")
    }
}

struct OptionColorControl: View {
    var title: String
    @Binding var hex: String
    @State private var draft = ""

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            ColorPicker(title, selection: colorBinding, supportsOpacity: false).labelsHidden()
            TextField(title, text: $draft)
                .labelsHidden().textFieldStyle(.roundedBorder)
                .font(DS.Typo.mono).frame(width: 92)
                .onAppear { draft = hex }
                .onChange(of: draft) { _, new in
                    let t = new.trimmingCharacters(in: .whitespaces)
                    if OptionFormat.rgb(fromHex: t) != nil, t.uppercased() != hex.uppercased() { hex = t.uppercased() }
                }
                .onChange(of: hex) { _, new in if OptionFormat.rgb(fromHex: draft) == nil || draft.uppercased() != new.uppercased() { draft = new } }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(get: {
            let c = OptionFormat.rgb(fromHex: hex) ?? (255, 255, 255)
            return Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        }, set: { color in
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            hex = OptionFormat.hex(r: Int((ns.redComponent * 255).rounded()), g: Int((ns.greenComponent * 255).rounded()), b: Int((ns.blueComponent * 255).rounded()))
        })
    }
}
