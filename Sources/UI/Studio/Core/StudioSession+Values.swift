import Foundation
import SwiftUI

// Values, resolution, messages, "Modified", undo / redo, output rules. Part of StudioSession (see StudioSession.swift).

extension StudioSession {
    static let outPrefix = "out."
    static func isOutputKey(_ key: String) -> Bool { key.hasPrefix(outPrefix) }

    // MARK: Resolution

    /// Recomputes `resolved`, the base, the messages, the change list and the "Modified" flag, then schedules the derived work (estimate, chips, preview).
    func recompute(refreshDerived: Bool = true, previewToo: Bool = true) {
        guard let schema, let op = operation else {
            resolved = nil; baseResolved = nil; messages = []; changeList = []; isModified = false
            estimate = nil; summaryChips = []; preview = nil
            derivedTask?.cancel(); previewTask?.cancel(); isPreviewing = false
            return
        }
        let src = activeSource?.info
        let snap = settings.data
        let quick = QuickRecipes.current(for: op, settings: snap)
        let presetValues = currentPreset?.values ?? OptionValues()
        let outBase = snap.output.optionValues
        let layers = [quick, presetValues, outBase]
        let base = schema.resolve(layers: layers, source: src)
        let full = schema.resolve(layers: layers + [values], source: src)
        baseResolved = base
        resolved = full
        messages = mergedMessages(full.messages, op.validate(options: full.values, source: src))
        let diffs = full.values.diff(against: base.values).filter { !Self.isOutputKey($0.key) }
        let byKey = Dictionary(uniqueKeysWithValues: diffs.map { ($0.key, $0) })
        changeList = schema.allFields.compactMap { f in byKey[f.key].map { (f, $0) } }   // in the order of the form
        isModified = !changeList.isEmpty
        if refreshDerived { scheduleDerived(previewToo: previewToo) }
    }

    private func mergedMessages(_ a: [OptionMessage], _ b: [OptionMessage]) -> [OptionMessage] {
        var seen = Set<String>()
        var out: [OptionMessage] = []
        for m in a + b where seen.insert(m.id + "|" + (m.fieldKey ?? "")).inserted { out.append(m) }
        return out.enumerated().sorted { l, r in l.element.severity != r.element.severity ? l.element.severity > r.element.severity : l.offset < r.offset }.map(\.element)
    }

    /// "Show changes": fields whose resolved value differs from the base, with labels, for the list with per-line revert.
    var changes: [(field: OptionField, change: OptionChange)] { changeList }

    func messages(for key: String) -> [OptionMessage] { messages.filter { $0.fieldKey == key } }
    var generalMessages: [OptionMessage] { messages.filter { $0.fieldKey == nil } }
    var errorCount: Int { messages.filter { $0.severity == .error }.count }
    var warningCount: Int { messages.filter { $0.severity == .warning }.count }

    /// The resolved value of a key (the value engines will read).
    func value(for key: String) -> OptionValue? { resolved?.values[key] }

    /// Is the resolved value equal to the base (quick recipe or preset)? Fields the person set to the same value count as default.
    func isDefault(_ key: String) -> Bool {
        guard let r = resolved?.values[key], let b = baseResolved?.values[key] else { return true }
        return OptionValues([key: r]).diff(against: OptionValues([key: b])).isEmpty
    }

    func defaultValue(for key: String) -> OptionValue? { baseResolved?.values[key] }

    // MARK: Per-field helpers for the renderer

    /// A binding for one field: reads the resolved value, writes through `set` (one undo group per field).
    func binding(for field: OptionField) -> Binding<OptionValue> {
        Binding(get: { [weak self] in self?.resolved?.values[field.key] ?? field.defaultValue.resolve(nil) },
                set: { [weak self] in self?.set(field.key, $0) })
    }

    /// Everything `OptionFieldView` needs besides the value.
    func context(for field: OptionField, group: OptionGroup? = nil, page: OptionPage? = nil) -> OptionFieldContext {
        let env = formEnvironment
        let page = page ?? schema.flatMap { OptionFormLogic.location(of: field.key, in: $0)?.page }
        let group = group ?? schema.flatMap { OptionFormLogic.location(of: field.key, in: $0)?.group }
        let st = OptionFormLogic.state(of: field, group: group, page: page, env: env, lockedKeys: lockedKeys, lockedBy: currentPreset?.name)
        var ctx = OptionFieldContext()
        ctx.isEnabled = st.enabled
        ctx.disabledReason = st.reason
        ctx.messages = messages(for: field.key)
        ctx.isDefault = isDefault(field.key)
        ctx.defaultValue = defaultValue(for: field.key)
        ctx.source = activeSource?.info
        ctx.optionEnvironment = env
        ctx.isLocked = st.isLocked
        return ctx
    }

    // MARK: Editing

    /// Sets one value (an undo group per field); recomputes resolution, messages, estimate, chips, preview. nil removes the person's value (back to the base).
    func set(_ key: String, _ value: OptionValue?) {
        guard let field = schema?.field(key), !lockedKeys.contains(key) else { return }
        if values[key] == value { return }
        if value == nil && values[key] == nil { return }
        if let value, let current = resolved?.values[key], values[key] == nil,
           OptionValues([key: value]).diff(against: OptionValues([key: current])).isEmpty, !Self.isOutputKey(key) {
            // Setting what is already shown is not an edit (a slider released where it started).
            return
        }
        pushUndo(key: key)
        values[key] = value
        afterEdit(changed: [key], affects: field.affects)
    }

    /// Removes the person's value of one field (the "revert" button next to a non-default value).
    func revert(key: String) {
        guard !lockedKeys.contains(key), values[key] != nil else { return }
        pushUndo(key: nil)
        values[key] = nil
        afterEdit(changed: [key], affects: schema?.field(key)?.affects ?? [.estimate, .plan])
    }

    /// Back to the preset (or to the quick recipe when none is selected). The destination (`out.*`) is not part of that.
    func revertAll() {
        let out = OptionValues(values.storage.filter { Self.isOutputKey($0.key) })
        guard out != values else { return }
        pushUndo(key: nil)
        values = out
        afterEdit(changed: [], affects: [.estimate, .plan, .preview])
    }

    /// Applies a fix of a validation message ("Switch the container to MOV") as ONE undo group.
    func applyFix(_ fix: OptionFix) {
        let editable = fix.set.filter { schema?.field($0.key) != nil && !lockedKeys.contains($0.key) }
        guard !editable.isEmpty else { return }
        pushUndo(key: nil)
        for (k, v) in editable { values[k] = v }
        afterEdit(changed: Array(editable.keys), affects: [.estimate, .plan, .preview])
    }

    /// Slider drags and text typing call these so a whole gesture is a single undo step.
    func beginEditing(key: String) { openGroupKey = key }
    func endEditing(key: String) { if openGroupKey == key { openGroupKey = nil } }

    func afterEdit(changed: [String], affects: OptionAffects) {
        if changed.contains(where: Self.isOutputKey) { syncOutputRulesFromValues() }
        recompute(previewToo: affects.contains(.preview) || previewRequest != nil)
        persistEditingJob()
    }

    // MARK: Undo and redo

    /// Remembers the state before an edit. Consecutive edits of the same field (a slider drag, typing) within a second, or inside `beginEditing` / `endEditing`, are ONE step.
    func pushUndo(key: String?) {
        let now = Date()
        if let key, key == lastUndoKey, openGroupKey == key || now.timeIntervalSince(lastUndoAt) < 1.0 {
            lastUndoAt = now
            return
        }
        undoStack.append(StudioUndoState(values: values, presetID: presetID, lockedKeys: lockedKeys))
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
        redoStack.removeAll()
        lastUndoKey = key
        lastUndoAt = now
        canUndo = true; canRedo = false
    }

    func resetUndo() {
        undoStack.removeAll(); redoStack.removeAll()
        lastUndoKey = nil; openGroupKey = nil
        canUndo = false; canRedo = false
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(StudioUndoState(values: values, presetID: presetID, lockedKeys: lockedKeys))
        restore(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(StudioUndoState(values: values, presetID: presetID, lockedKeys: lockedKeys))
        restore(next)
    }

    private func restore(_ s: StudioUndoState) {
        values = s.values; presetID = s.presetID; lockedKeys = s.lockedKeys
        lastUndoKey = nil
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
        syncOutputRulesFromValues()
        recompute()
        persistEditingJob()
    }

    // MARK: Output rules (the Output page's `out.*` keys <-> `outputRules`)

    /// `outputRules` was assigned from outside (the window's destination control): mirror it into the person's layer.
    func outputRulesAssigned() {
        mirrorOutputRulesIntoValues()
        recompute(refreshDerived: false)
        persistEditingJob()
    }

    func mirrorOutputRulesIntoValues() {
        let base = settings.data.output.optionValues
        let cur = outputRules.optionValues
        for (k, v) in cur.storage {
            if base[k] == v { values[k] = nil } else { values[k] = v }
        }
    }

    /// `out.*` values changed: rebuild `outputRules` from them over the global rules.
    func syncOutputRulesFromValues() {
        let outValues = OptionValues(values.storage.filter { Self.isOutputKey($0.key) })
        syncingOutput = true
        outputRules = OutputRules(options: outValues, base: settings.data.output)
        syncingOutput = false
    }

    /// The rules to attach to a recipe or job: nil when they equal the global ones.
    var outputRulesOverride: OutputRules? { outputRules == settings.data.output ? nil : outputRules }
}
