import SwiftUI

// The generic renderer: OptionSchema -> native views. No operation-specific code lives here.
// Files: OptionRendering (this: context + one field with label, markers, messages), OptionControls (one control per FieldKind), OptionFormView (the inspector),
// TrackListEditor, SummaryCapsule, SourceInspectorView, PresetBar. Pure logic is in OptionFormLogic.

/// What a field view needs to know besides its value.
struct OptionFieldContext {
    var isEnabled = true
    var disabledReason: L10n?
    var messages: [OptionMessage] = []
    /// The value equals the schema default / quick recipe (non-default values show a Swamp Blue "Default: ..." chip and a revert button).
    var isDefault = true
    var source: SourceInfo?
    /// The default itself, for the chip text and the standalone revert.
    var defaultValue: OptionValue?
    /// Values + source + capabilities, to evaluate `FieldOption.enabledWhen` of picker items.
    var optionEnvironment: ExprEnvironment?
    /// Disabled because the selected preset locks it (the info glyph becomes a lock).
    var isLocked = false
}

/// ONE field: toggle, picker (menu), segmented (becomes a menu automatically when labels are long: Russian), slider with live value + unit + direction labels, stepper, text
/// (validated, secure for passwords), time (hh:mm:ss.mmm), number, folder / file (open panels), colour well (#RRGGBB), tracks (`TrackListEditor`). Label + help popover (never
/// tooltip-only), disabled-with-reason (info glyph + reason on hover, click and VoiceOver), a default chip and a revert button for non-default values, validation messages
/// beside the cause with fix buttons. Also used by the Settings parameter sheet (pass just `field`, `value` and a `context`).
struct OptionFieldView: View {
    var field: OptionField
    @Binding var value: OptionValue
    var context: OptionFieldContext = OptionFieldContext()
    /// Revert to the base; nil = write `context.defaultValue` back into the binding.
    var onRevert: (() -> Void)? = nil
    var onFix: ((OptionFix) -> Void)? = nil
    /// A drag or typing gesture starts / ends (slider): the session makes it one undo step.
    var onEditingChanged: ((Bool) -> Void)? = nil
    /// Track-row columns: no default chip, no help popover.
    var compact = false

    @State private var reasonShown = false
    @State private var localProblem: L10n?
    @Environment(\.a11y) private var a11y

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if case .segmented(let opts) = field.kind {
                // Segmented control under the label while it fits; otherwise a menu beside the label, or under it when the label is long too.
                ViewThatFits(in: .horizontal) {
                    if OptionSegmentedControl.allUsable(opts, env: context.optionEnvironment) { stackedLayout }
                    inlineLayout(asMenu: true)
                    stackedLayout(asMenu: true)
                }
            } else if Self.isStacked(field.kind) {
                stackedLayout
            } else {
                ViewThatFits(in: .horizontal) {
                    inlineLayout
                    stackedLayout
                }
            }
            markerRow
            if let p = localProblem { OptionMessageRow(p.text, severity: .error) }
            ForEach(context.messages.filter { $0.fieldKey == field.key }) { m in
                OptionMessageRow(m, onFix: onFix)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Kinds that always put the control under the label.
    static func isStacked(_ kind: FieldKind) -> Bool {
        switch kind {
        case .segmented, .slider, .tracks: return true
        case .text(let spec): return spec.multiline
        default: return false
        }
    }

    // MARK: Layouts

    private var inlineLayout: some View { inlineLayout(asMenu: false) }
    private var stackedLayout: some View { stackedLayout(asMenu: false) }

    private func inlineLayout(asMenu: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
            labelBlock.fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: DS.Space.sm)
            control(asMenu: asMenu).disabled(!context.isEnabled).fixedSize(horizontal: true, vertical: false)
        }
    }

    private func stackedLayout(asMenu: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
                labelBlock
                Spacer(minLength: DS.Space.sm)
                if case .slider(let spec) = field.kind {
                    Text(OptionSlider.spoken(value: value.asDouble ?? spec.min, spec: spec, fallbackUnit: field.unit))
                        .font(DS.Typo.numeric()).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            control(asMenu: asMenu).disabled(!context.isEnabled)
        }
    }

    private func control(asMenu: Bool) -> OptionControl {
        OptionControl(field: field, value: $value, context: context, problem: $localProblem, onEditingChanged: onEditingChanged, segmentedAsMenu: asMenu)
    }

    // MARK: Label

    private var labelBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            if compact {
                Text(field.label.text).fixedSize(horizontal: false, vertical: true)
            } else {
                OptionHelpLabel(field.label.text, help: field.help?.text)
            }
            if let reason = reasonText { reasonButton(reason) }
        }
        .opacity(context.isEnabled ? 1 : 0.6)
    }

    private var reasonText: String? {
        guard !context.isEnabled else { return nil }
        return (context.disabledReason ?? OptionFormLogic.conditionReason).text
    }

    private func reasonButton(_ reason: String) -> some View {
        Button { reasonShown.toggle() } label: {
            Image(systemName: context.isLocked ? "lock" : "info.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.callout.weight(DS.symbolWeight))
                .foregroundStyle(a11y.increaseContrast ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(reason)
        .accessibilityLabel(Text(reason))
        .popover(isPresented: $reasonShown, arrowEdge: .bottom) { OptionHelpContent(title: nil, help: reason) }
    }

    // MARK: Default chip and revert

    @ViewBuilder private var markerRow: some View {
        if !context.isDefault && !context.isLocked && !compact {
            HStack(spacing: DS.Space.sm) {
                InfoChip(defaultChipText, emphasized: true)
                Button(action: revert) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "arrow.counterclockwise").imageScale(.small)
                        Text(L("Revert", "Вернуть"))
                    }
                    .font(DS.Typo.caption.weight(.medium))
                    .foregroundStyle(Brand.blueInk)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(OptionStrings.revertToDefault.text)
                .accessibilityLabel(Text(OptionStrings.revertToDefault.text))
                Spacer(minLength: 0)
            }
            .disabled(!context.isEnabled)
        }
    }

    private var defaultChipText: String {
        guard let d = context.defaultValue else { return L("Default", "По умолчанию") }
        let t = OptionFormat.display(d, for: field)
        return L("Default: \(t)", "По умолчанию: \(t)")
    }

    private func revert() {
        if let onRevert { onRevert(); return }
        if let d = context.defaultValue { value = d }
    }
}
