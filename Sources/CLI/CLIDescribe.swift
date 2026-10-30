import Foundation

/// The machine-readable shape of operations, option schemas, presets, probed files and smart-transcode plans (`--json` of list-ops, options, presets, probe).
/// Pure value-to-dictionary mapping: nothing here runs an operation.
@MainActor
enum CLIDescribe {
    static func l10n(_ l: L10n) -> [String: String] { ["en": l.en, "ru": l.ru] }

    // MARK: Operations

    static func operation(_ op: Operation, tools: ToolLocator) -> [String: Any] {
        let m = op.meta
        let availability = op.availability(for: [], tools: tools)
        var missing: [String] = []
        if case .unavailable(_, let tl) = availability { missing = tl.map(\.rawValue) }
        return [
            "id": m.id,
            "wheel": m.wheel.rawValue,
            "family": m.family.rawValue,
            "label": l10n(m.label),
            "subtitle": m.subtitle.map(l10n) as Any,
            "schema": m.schemaID,
            "target": m.targetFormat as Any,
            "inputs": m.inputs.map { Array($0).sorted() } as Any,
            "folders": m.acceptsDirectories,
            "anyFile": m.acceptsAnyFile,
            "minItems": m.minItems,
            "links": m.acceptsLinks,
            "app": m.isAppAction,
            "usesNetwork": m.usesNetwork,
            "studioOnly": m.studioOnly,
            "concurrency": m.concurrency.rawValue,
            "passthrough": m.passthrough.rawValue,
            "requires": m.requires.map(\.rawValue),
            "available": availability.isAvailable,
            "reason": availability.reason.map(l10n) as Any,
            "missing": missing
        ]
    }

    // MARK: Option schemas

    static func kindName(_ kind: FieldKind) -> String {
        switch kind {
        case .toggle: return "toggle"
        case .picker: return "picker"
        case .segmented: return "segmented"
        case .slider: return "slider"
        case .stepper: return "stepper"
        case .text: return "text"
        case .time: return "time"
        case .number: return "number"
        case .folder: return "folder"
        case .file: return "file"
        case .color: return "color"
        case .tracks: return "tracks"
        }
    }

    static func field(_ f: OptionField, quick: OptionValues, page: String, group: String) -> [String: Any] {
        var d: [String: Any] = [
            "key": f.key,
            "kind": kindName(f.kind),
            "label": l10n(f.label),
            "help": f.help.map(l10n) as Any,
            "level": f.level == .basic ? "basic" : (f.level == .standard ? "standard" : "expert"),
            "page": page,
            "group": group,
            "requires": f.requires,
            "available": Capabilities.shared.hasAll(f.requires),
            "conditional": f.visibleWhen != nil || f.enabledWhen != nil,
            "persist": f.persist
        ]
        if !f.aliases.isEmpty { d["aliases"] = f.aliases }
        if let unit = f.unit { d["unit"] = unit }
        let def = f.defaultValue.resolve(nil)
        var secret = false
        switch f.kind {
        case .slider(let s):
            d["min"] = s.min; d["max"] = s.max; d["step"] = s.step; d["decimals"] = s.decimals
            if let u = s.unit { d["unit"] = u }
        case .stepper(let s):
            d["min"] = s.min; d["max"] = s.max; d["step"] = s.step
            if let u = s.unit { d["unit"] = u }
        case .number(let n):
            if let lo = n.min { d["min"] = lo }
            if let hi = n.max { d["max"] = hi }
            d["step"] = n.step; d["decimals"] = n.decimals
            if let u = n.unit { d["unit"] = u }
        case .picker(let opts), .segmented(let opts):
            d["options"] = opts.map { o -> [String: Any] in
                ["value": o.value, "label": l10n(o.label), "available": Capabilities.shared.hasAll(o.requires), "hint": o.hint.map(l10n) as Any]
            }
        case .text(let t):
            secret = t.secure
            if t.multiline { d["multiline"] = true }
        case .time(let t):
            d["allowEmpty"] = t.allowEmpty
            d["format"] = "seconds, 1:30 or 01:02:03.5"
        case .tracks(let t):
            d["columns"] = t.columns.map { c in field(c, quick: OptionValues(), page: page, group: group) }
            if let m = t.maxRows { d["maxRows"] = m }
        case .toggle, .folder, .file, .color: break
        }
        if !secret {
            d["default"] = CLIJSON.optionValue(def)
            if let q = quick[f.key] { d["quick"] = CLIJSON.optionValue(q) } else { d["quick"] = CLIJSON.optionValue(def) }
        } else {
            d["secret"] = true
        }
        return d
    }

    /// The full schema with the Output page, plus the values the wheel would use (`quick`).
    static func schema(of op: Operation, settings: SettingsData) -> [String: Any] {
        let schema = op.studioSchema(for: [])
        let quick = QuickRecipes.current(for: op, settings: settings)
        let pages = schema.pages.map { p -> [String: Any] in
            ["id": p.id, "title": l10n(p.title), "symbol": p.symbol, "requires": p.requires, "conditional": p.visibleWhen != nil,
             "groups": p.groups.map { g -> [String: Any] in
                 ["id": g.id, "title": g.title.map(l10n) as Any, "level": g.level == .basic ? "basic" : (g.level == .standard ? "standard" : "expert"),
                  "fields": g.fields.map { field($0, quick: quick, page: p.id, group: g.id) }]
             }]
        }
        return ["operation": op.meta.id, "schema": schema.id, "title": l10n(schema.title), "version": schema.version, "pages": pages,
                "fieldCount": schema.allFields.count]
    }

    // MARK: Presets

    static func preset(_ p: Preset) -> [String: Any] {
        ["id": p.id, "target": p.targetID, "name": l10n(p.name), "notes": p.notes.map(l10n) as Any, "group": p.group.rawValue, "builtin": p.isBuiltin,
         "operation": p.operationID as Any, "onWheel": p.onWheel?.rawValue as Any, "locks": p.locks,
         "values": p.values.storage.mapValues { CLIJSON.optionValue($0) }]
    }

    // MARK: Probed files

    static func source(_ info: SourceInfo) -> [String: Any] {
        [
            "file": info.url.path, "name": info.url.lastPathComponent, "kind": info.kind.rawValue,
            "size": info.sizeBytes as Any, "duration": info.duration as Any,
            "facts": info.facts.mapValues { CLIJSON.optionValue($0) },
            "chips": info.chips.map { ["text": $0.text, "symbol": $0.symbol as Any] as [String: Any] },
            "streams": info.streams.map { s -> [String: Any] in
                ["kind": s.kind.rawValue, "index": s.index, "title": s.title, "detail": s.detail, "language": s.language as Any, "default": s.isDefault,
                 "facts": s.facts.mapValues { CLIJSON.optionValue($0) }]
            },
            "warnings": info.warnings.map(l10n)
        ]
    }

    // MARK: Smart-transcode plans

    static func plan(_ p: TranscodePlan) -> [String: Any] {
        var video: [String: Any]
        switch p.video {
        case .copy: video = ["action": "copy"]
        case .hevc(let encoder, let tenBit): video = ["action": "hevc", "encoder": encoder, "tenBit": tenBit]
        case .h264(let encoder): video = ["action": "h264", "encoder": encoder]
        }
        video["width"] = p.targetWidth as Any
        video["height"] = p.targetHeight as Any
        video["fps"] = p.targetFPS as Any
        video["pixelFormat"] = p.pixelFormat as Any
        video["tag"] = p.videoTag as Any
        video["quality"] = p.qualityValue as Any
        let audio = zip(p.audio, p.audioStreamIndexes).map { a, i -> [String: Any] in
            switch a {
            case .copy: return ["stream": i, "action": "copy"]
            case .aac(let kbps): return ["stream": i, "action": "aac", "kbps": kbps]
            case .alac: return ["stream": i, "action": "alac"]
            }
        }
        return [
            "mode": p.mode.rawValue, "container": p.container, "remux": p.isPureRemux, "faststart": p.faststart,
            "video": video, "audio": audio, "subtitleStreams": p.subtitleStreamIndexes,
            "color": ["primaries": p.color.primaries as Any, "transfer": p.color.transfer as Any, "matrix": p.color.matrix as Any,
                      "range": p.color.range as Any, "hdr": p.color.isHDR],
            "warnings": p.warnings.map(l10n), "notes": p.notes.map(l10n)
        ]
    }
}
