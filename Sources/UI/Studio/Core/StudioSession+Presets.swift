import Foundation
import AppKit

// Presets of the selected target: apply, save, save changes, default, duplicate, rename, delete, import, export. Part of StudioSession.
//
// A preset holds SPARSE values over the schema defaults. It never holds the destination (`out.*`), secrets, or concrete track rows (rows point at streams of one
// particular file; the audio / subtitle RULES belong in presets, the picks do not). Its `locks` are fields the preset makes read-only while it is selected.

extension StudioSession {
    var currentPreset: Preset? { presetID.flatMap { presetStore.preset(id: $0) } }

    /// Presets of the target, for the pop-up.
    var availablePresets: [Preset] { targetID.map { presetStore.presets(for: $0) } ?? [] }

    /// The pop-up's order: last used on top, then by group (Web, Devices, Social, Archive, Small size, Lossless, Custom), each group in registration order.
    var groupedPresets: [(group: PresetGroup, presets: [Preset])] {
        let all = availablePresets
        return PresetGroup.allCases.compactMap { g in
            let list = all.filter { $0.group == g }
            return list.isEmpty ? nil : (g, list)
        }
    }

    var lastUsedPreset: Preset? {
        guard let t = targetID, let id = settings.data.studio.lastPresetByTarget[t] else { return nil }
        return availablePresets.first { $0.id == id }
    }

    var isDefaultPreset: Bool { presetID != nil && presetID == targetID.flatMap { presetStore.defaultPresetID(for: $0) } }

    /// Values a preset never carries and that therefore survive choosing, saving or deleting a preset: the destination, secrets and the track rows of this file.
    func survivesPresetChange(_ key: String) -> Bool {
        if Self.isOutputKey(key) { return true }
        guard let f = schema?.field(key) else { return false }
        if !f.persist { return true }
        if case .tracks = f.kind { return true }
        return false
    }

    var userLayerKeptAcrossPresets: OptionValues { OptionValues(values.storage.filter { survivesPresetChange($0.key) }) }

    /// Selects `preset`: the person's layer is dropped (the destination, secrets and track rows stay), the preset's locks apply.
    func apply(preset: Preset) {
        guard preset.targetID == targetID else { return }
        pushUndo(key: nil)
        values = userLayerKeptAcrossPresets
        presetID = preset.id
        lockedKeys = Set(preset.locks)
        if let t = targetID { let pid = preset.id; settings.update { $0.studio.lastPresetByTarget[t] = pid } }
        recompute()
        persistEditingJob()
    }

    /// Back to no preset: the quick recipe of the operation.
    func clearPreset() {
        guard presetID != nil else { return }
        pushUndo(key: nil)
        presetID = nil
        lockedKeys = []
        recompute()
        persistEditingJob()
    }

    /// The sparse values a preset made from the current state would hold: quick recipe + selected preset + the person's changes, minus what equals the schema default
    /// (unless the quick recipe overrides that key, which the preset must then override back), minus destination, secrets and track rows.
    func valuesForSaving() -> OptionValues {
        guard let schema, let op = operation else { return OptionValues() }
        let quick = QuickRecipes.current(for: op, settings: settings.data)
        let explicit = quick.overlaying(currentPreset?.values ?? OptionValues()).overlaying(values)
        let defaults = schema.defaults()
        var out = OptionValues()
        for (k, v) in explicit.storage {
            guard let f = schema.field(k), f.persist, !Self.isOutputKey(k) else { continue }
            if case .tracks = f.kind { continue }
            let same = defaults[k].map { OptionValues([k: v]).diff(against: OptionValues([k: $0])).isEmpty } ?? false
            if !same || quick.has(k) { out[k] = v }
        }
        return out
    }

    /// Save As New Preset (name, symbol, group, lock-selected-fields, optionally "show on wheel"). The new preset becomes the selected one.
    @discardableResult
    func saveAsPreset(name: String, symbol: String, group: PresetGroup, locks: [String], onWheel: WheelKind?) throws -> Preset {
        guard let t = targetID else { throw PresetError.notFound }
        let vals = valuesForSaving()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = try presetStore.create(name: clean.isEmpty ? L("My preset", "Мой шаблон") : clean, targetID: t, values: vals, symbol: symbol, group: group,
                                       operationID: operationID, onWheel: onWheel, locks: locks.filter { vals.has($0) })
        pushUndo(key: nil)
        values = userLayerKeptAcrossPresets
        presetID = p.id
        lockedKeys = Set(p.locks)
        settings.update { $0.studio.lastPresetByTarget[t] = p.id }
        recompute()
        persistEditingJob()
        return p
    }

    /// Save Changes to a USER preset (built-ins are read-only: the UI offers Save As New).
    func saveChangesToPreset() throws {
        guard var p = currentPreset else { throw PresetError.notFound }
        if p.isBuiltin { throw PresetError.builtinReadOnly }
        p.values = valuesForSaving()
        p.locks = p.locks.filter { p.values.has($0) }
        try presetStore.save(p)
        pushUndo(key: nil)
        values = userLayerKeptAcrossPresets
        lockedKeys = Set(p.locks)
        recompute()
    }

    /// Make Default (per target): the preset a fresh Studio opens on for this target.
    func makeDefaultPreset() {
        guard let t = targetID, let id = presetID else { return }
        presetStore.setDefaultPreset(id, for: t)
        objectWillChange.send()
    }

    @discardableResult
    func duplicateCurrentPreset() throws -> Preset {
        guard let id = presetID else { throw PresetError.notFound }
        let copy = try presetStore.duplicate(id: id)
        apply(preset: copy)
        return copy
    }

    func renameCurrentPreset(to name: String) throws {
        guard let id = presetID else { throw PresetError.notFound }
        try presetStore.rename(id: id, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
        objectWillChange.send()
    }

    /// Deletes the selected USER preset; the values it contributed stay as the person's own changes, so nothing visible jumps.
    func deleteCurrentPreset() throws {
        guard let p = currentPreset else { throw PresetError.notFound }
        if p.isBuiltin { throw PresetError.builtinReadOnly }
        try presetStore.delete(id: p.id)
        pushUndo(key: nil)
        values = p.values.overlaying(values)
        presetID = nil
        lockedKeys = []
        if let t = targetID, settings.data.studio.lastPresetByTarget[t] == p.id { settings.update { $0.studio.lastPresetByTarget[t] = nil } }
        recompute()
    }

    @discardableResult
    func importPresets(from url: URL) throws -> [Preset] {
        let list = try presetStore.importFile(url)
        objectWillChange.send()
        return list
    }

    func exportCurrentPreset(to url: URL) throws {
        guard let id = presetID else { throw PresetError.notFound }
        try presetStore.export(ids: [id], to: url)
    }
}
