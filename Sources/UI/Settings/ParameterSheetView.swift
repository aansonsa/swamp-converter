import SwiftUI
import AppKit

/// The small sheet a quick run opens when an operation needs an answer (trim start / end, a target size, a password): the operation's name, what it will run on, the asked fields
/// drawn by the same renderer the Studio uses, calm messages beside their cause, and Cancel / Run. Return runs, Escape cancels.
struct ParameterSheetView: View {
    @State private var model: ParamSheetModel
    var onRun: (OptionValues) -> Void
    var onCancel: () -> Void

    init(model: ParamSheetModel, onRun: @escaping (OptionValues) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: model); self.onRun = onRun; self.onCancel = onCancel
    }

    var body: some View {
        let messages = model.messages()
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            header
            Form {
                ForEach(model.fields, id: \.key) { field in
                    OptionFieldView(field: field, value: Binding(get: { model.values[field.key] ?? field.defaultOptionValue }, set: { model.set(field.key, $0) }),
                                    context: OptionFieldContext(isEnabled: true, disabledReason: nil, messages: messages.filter { $0.fieldKey == field.key }, isDefault: true, source: nil,
                                                                defaultValue: nil, optionEnvironment: ExprEnvironment(values: model.merged, source: nil)))
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            ForEach(messages.filter { m in m.fieldKey == nil || !model.fields.contains { $0.key == m.fieldKey } }) { m in
                InlineMessage(m.text.text, severity: m.severity)
            }
            HStack {
                Spacer()
                Button(L("Cancel", "Отмена"), role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button(L("Run", "Запустить")) { if model.canRun { onRun(model.answers()) } }
                    .keyboardShortcut(.defaultAction).disabled(!model.canRun)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .appRoot()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            SymbolIcon(model.operation.meta.symbol, size: 24, style: .secondary).frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(model.operation.meta.label.text).font(DS.Typo.headline)
                Text(model.items.summaryTitle).font(DS.Typo.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Opens the sheet in a small floating panel (the quick path has no window of its own to hang a sheet on), one at a time, and returns the answers or nil on Cancel.
@MainActor
final class ParameterSheetPresenter: NSObject, NSWindowDelegate {
    static let shared = ParameterSheetPresenter(memory: .shared)

    private let memory: ParameterMemory
    /// Tests answer for the person instead of opening a window.
    var testResponder: ((ParamSheetModel) -> OptionValues?)?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var busy = false
    private var panel: NSPanel?
    private var pending: CheckedContinuation<OptionValues?, Never>?

    init(memory: ParameterMemory) { self.memory = memory; super.init() }

    /// The hook `QuickRun.parameterPrompt` calls.
    func ask(operation: Operation, items: [FileItem], fields: [OptionField], current: OptionValues) async -> OptionValues? {
        let model = ParamSheetModel(operation: operation, items: items, fields: fields, current: current, remembered: memory.values(for: operation.meta.id))
        let answers: OptionValues?
        if let responder = testResponder {
            answers = responder(model)
        } else {
            await acquire()
            answers = await present(model)
            release()
        }
        if let answers {
            var done = model
            for (k, v) in answers.storage { done.set(k, v) }
            memory.remember(done.memorable(), for: operation.meta.id)
        }
        return answers
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    private func present(_ model: ParamSheetModel) async -> OptionValues? {
        await withCheckedContinuation { (cont: CheckedContinuation<OptionValues?, Never>) in
            pending = cont
            let view = ParameterSheetView(model: model, onRun: { [weak self] in self?.finish($0) }, onCancel: { [weak self] in self?.finish(nil) })
            let host = NSHostingController(rootView: view)
            let panel = NSPanel(contentViewController: host)
            panel.styleMask = [.titled, .closable]
            panel.title = model.operation.meta.label.text
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            self.panel = panel
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func finish(_ answers: OptionValues?) {
        guard let cont = pending else { return }
        pending = nil
        let p = panel
        panel = nil
        p?.delegate = nil
        p?.orderOut(nil)
        p?.contentViewController = nil
        cont.resume(returning: answers)
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }
}
