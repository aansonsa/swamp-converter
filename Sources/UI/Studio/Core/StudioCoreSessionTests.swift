import Foundation

// StudioSession flows against the fixture operations (own registry, settings, preset store and runner: see StudioHarness).

enum StudioCoreSessionTests {
    typealias T = StudioCoreTests

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("studio-core", "a session preselects the requested target, seeds from the wheel sector's quick recipe, and starts unmodified") {
            let h = StudioHarness(); defer { h.cleanup() }
            let f = try h.file()
            let b = h.session(files: [f], target: "test.studio.b")
            try expectEqual(b.targetID, StudioFixture.schemaID); try expectEqual(b.operationID, "test.studio.b")
            try expectEqual(b.resolved?.values.int(FixtureKeys.quality), 28); try expectEqual(b.resolved?.values.string(FixtureKeys.container), "mov")
            try expect(!b.isModified && b.isDefault(FixtureKeys.quality), "the quick recipe IS the default")
            let a = h.session(files: [f], target: StudioFixture.schemaID)
            try expectEqual(a.operationID, "test.studio.a", "a target id alone runs its primary operation"); try expectEqual(a.resolved?.values.int(FixtureKeys.quality), 23)
            let any = h.session(files: [f])
            try expectEqual(any.targetID, StudioFixture.schemaID, "the first available target is preselected")
            try expectEqual(any.targets.map(\.id), [StudioFixture.schemaID], "a single file offers no merge")
            let two = h.session(files: [f, try h.file("second.stud")])
            try expect(two.targets.contains { $0.id == "test.studio.merge" }, "two files offer the batch target")
            let empty = h.session()
            try expect(empty.targetID == nil && empty.schema == nil && !empty.canStart)
            try expect(empty.targets.count >= 3, "an empty Studio lists every target so a recipe can be edited")
            empty.selectTarget("test.studio.b")
            try expectEqual(empty.operationID, "test.studio.b"); try expect(empty.schema != nil)
            try expect(!empty.canStart && empty.startBlockReason != nil, "no input yet")
        }

        t.register("studio-core", "the user's edit of a quick recipe is the new default in Studio") {
            let h = StudioHarness(); defer { h.cleanup() }
            h.settings.update { $0.quickRecipes["test.studio.a"] = [FixtureKeys.quality: 19] }
            let s = h.session(files: [try h.file()], target: "test.studio.a")
            try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 19); try expect(!s.isModified)
            s.set(FixtureKeys.quality, 21)
            try expectEqual(s.defaultValue(for: FixtureKeys.quality), .int(19)); try expect(s.isModified)
        }

        t.register("studio-core", "set, revert, revertAll, undo and redo: one undo group per field, Modified and the change list") {
            let h = StudioHarness(); defer { h.cleanup() }
            let s = h.probedSession(files: [try h.file()], operationID: "test.studio.a")
            s.set(FixtureKeys.quality, 20)
            try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 20); try expect(s.isModified && !s.isDefault(FixtureKeys.quality))
            let ch = try unwrap(s.changes.first); try expectEqual(s.changes.count, 1)
            try expectEqual(ch.change.old, .int(23)); try expectEqual(ch.change.new, .int(20)); try expectEqual(ch.field.key, FixtureKeys.quality)
            s.set(FixtureKeys.quality, 19)   // same field, moments later: still ONE undo step
            try expectEqual(s.undoStack.count, 1)
            s.undo()
            try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 23); try expect(!s.isModified && !s.canUndo && s.canRedo)
            s.redo()
            try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 19)
            s.set(FixtureKeys.container, "mov"); s.set(FixtureKeys.quality, 25)
            try expectEqual(s.undoStack.count, 3, "a different field in between starts a new group")
            s.undo(); try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 19)
            s.undo(); try expectEqual(s.resolved?.values.string(FixtureKeys.container), "mp4")
            s.redo(); s.redo()
            try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 25)
            s.revert(key: FixtureKeys.quality)
            try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 23); try expect(s.isModified, "the container is still changed")
            s.revertAll()
            try expect(!s.isModified && s.values.isEmpty)
            s.undo()
            try expect(s.isModified, "even Revert All can be undone")
            // Setting what is already shown is not an edit.
            let n = s.undoStack.count
            s.set(FixtureKeys.refs, 3); s.set("nonexistent.key", 1); s.set(FixtureKeys.rc, nil)
            try expectEqual(s.undoStack.count, n)
            // An explicit editing gesture is one step however long it takes.
            s.revertAll(); s.resetUndo()
            s.beginEditing(key: FixtureKeys.quality)
            for q in 30...34 { s.set(FixtureKeys.quality, .int(q)); s.lastUndoAt = .distantPast }
            s.endEditing(key: FixtureKeys.quality)
            try expectEqual(s.undoStack.count, 1, "begin / end editing groups a drag")
        }

        t.register("studio-core", "conditions in the session: inactive values reset to defaults, a gated toggle stays off with its reason") {
            let h = StudioHarness(); defer { h.cleanup() }
            let s = h.probedSession(files: [try h.file()], operationID: "test.studio.a")
            let bitrateField = try unwrap(s.schema?.field(FixtureKeys.bitrate))
            s.set(FixtureKeys.bitrate, 8000)
            try expectEqual(s.resolved?.values.int(FixtureKeys.bitrate), 4000, "disabled while rate control is constant quality")
            var ctx = s.context(for: bitrateField)
            try expect(!ctx.isEnabled && ctx.disabledReason == bitrateField.disabledReason)
            s.set(FixtureKeys.rc, "abr")
            ctx = s.context(for: bitrateField)
            try expect(ctx.isEnabled); try expectEqual(s.resolved?.values.int(FixtureKeys.bitrate), 8000, "the person's value comes back once the field is active")
            let gated = try unwrap(s.schema?.field(FixtureKeys.gated))
            s.set(FixtureKeys.gated, true)
            try expectEqual(s.resolved?.values.bool(FixtureKeys.gated), false)
            let g = s.context(for: gated)
            try expect(!g.isEnabled && g.disabledReason == gated.disabledReason && !g.isLocked)
            s.set(FixtureKeys.container, "mkv")
            try expectEqual(s.resolved?.values.string(FixtureKeys.container), "mp4", "an option whose tool is missing is never selected")
            try expect(s.context(for: try unwrap(s.schema?.field(FixtureKeys.container))).optionEnvironment != nil)
        }

        t.register("studio-core", "messages: rule warning with a fix, operation error with a fix, a general note; Start follows the errors") {
            let h = StudioHarness(); defer { h.cleanup() }
            let s = h.probedSession(files: [try h.file()], operationID: "test.studio.a")
            try expect(s.messages.isEmpty && s.canStart)
            s.set(FixtureKeys.quality, 45)
            let w = try unwrap(s.messages(for: FixtureKeys.quality).first)
            try expectEqual(w.severity, .warning); try expect(s.canStart, "a warning does not block")
            s.applyFix(try unwrap(w.fix))
            try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 30); try expect(s.messages(for: FixtureKeys.quality).isEmpty)
            s.undo()
            try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 45, "a fix is one undo group")
            s.set(FixtureKeys.trimStart, 10.0); s.set(FixtureKeys.trimEnd, 5.0)
            let e = try unwrap(s.messages.first { $0.id == "V19" })
            try expectEqual(e.severity, .error); try expectEqual(s.errorCount, 1)
            try expect(!s.canStart); try expect(s.startBlockReason == e.text)
            try expectEqual(s.messages.first?.severity, .error, "errors sort first")
            s.applyFix(try unwrap(e.fix))
            try expect(s.canStart, "the fix removes the error")
            s.set(FixtureKeys.mode, "universal")
            try expectEqual(s.generalMessages.count, 1); try expectEqual(s.generalMessages[0].severity, .info)
            s.set(FixtureKeys.title, "x")   // schema text validation does not apply to this field: no stray messages
            try expect(s.messages(for: FixtureKeys.title).isEmpty)
        }

        t.register("studio-core", "presets: apply, Modified against the preset, locks, save as new, save changes, read-only built-ins, make default") {
            let h = StudioHarness(); defer { h.cleanup() }
            h.presets.registerBuiltins([Preset.builtin("web", target: StudioFixture.schemaID, L10n("Web", "Веб"), symbol: "globe", group: .web, [FixtureKeys.quality: 26, FixtureKeys.container: "mov"]),
                                        Preset.builtin("small", target: StudioFixture.schemaID, L10n("Small", "Малый"), group: .smallSize, [FixtureKeys.quality: 34]),
                                        Preset.builtin("other", target: "somewhere.else", L10n("Other"), [:])])
            let s = h.probedSession(files: [try h.file()], operationID: "test.studio.a")
            try expectEqual(s.availablePresets.count, 2, "only presets of the target")
            try expectEqual(s.groupedPresets.map { $0.group }, [.web, .smallSize])
            let web = try unwrap(h.presets.preset(id: "builtin.web"))
            s.apply(preset: try unwrap(h.presets.preset(id: "builtin.other")))
            try expect(s.presetID == nil, "a preset of another target is ignored")
            s.set(FixtureKeys.refs, 5)
            s.apply(preset: web)
            try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 26); try expectEqual(s.resolved?.values.int(FixtureKeys.refs), 3, "the person's layer is dropped")
            try expect(!s.isModified && s.presetID == "builtin.web"); try expectEqual(s.lastUsedPreset?.id, "builtin.web")
            s.set(FixtureKeys.quality, 22)
            try expect(s.isModified); try expectEqual(s.changes.first?.change.old, .int(26)); try expectEqual(s.changes.first?.change.new, .int(22))
            do { try s.saveChangesToPreset(); throw TestFailure(message: "built-in presets are read-only", file: #fileID, line: #line) } catch let e as PresetError { try expect(e.errorDescription == PresetError.builtinReadOnly.errorDescription) }
            let before = s.resolved?.values
            let mine = try s.saveAsPreset(name: " Mine ", symbol: "star", group: .custom, locks: [FixtureKeys.quality, "no.such.key"], onWheel: .tools)
            try expectEqual(mine.name.en, "Mine"); try expect(!mine.isBuiltin && mine.onWheel == .tools && mine.operationID == "test.studio.a")
            try expectEqual(mine.values.int(FixtureKeys.quality), 22); try expectEqual(mine.values.string(FixtureKeys.container), "mov")
            try expectEqual(mine.locks, [FixtureKeys.quality], "locks of fields that are not in the preset are dropped")
            try expect(s.presetID == mine.id && s.values.isEmpty && !s.isModified); try expect(s.resolved?.values == before, "saving changes nothing visible")
            try expect(h.presets.userPresets.contains { $0.id == mine.id })
            // The preset locks the quality field.
            s.set(FixtureKeys.quality, 30)
            try expectEqual(s.resolved?.values.int(FixtureKeys.quality), 22)
            let qctx = s.context(for: try unwrap(s.schema?.field(FixtureKeys.quality)))
            try expect(qctx.isLocked && !qctx.isEnabled && qctx.disabledReason != nil)
            // Save changes writes a user preset; Modified clears.
            s.set(FixtureKeys.refs, 6)
            try expect(s.isModified)
            try s.saveChangesToPreset()
            try expectEqual(h.presets.preset(id: mine.id)?.values.int(FixtureKeys.refs), 6); try expect(!s.isModified && s.values.isEmpty)
            try expectEqual(s.resolved?.values.int(FixtureKeys.refs), 6)
            // Make default: a fresh Studio on the target opens on it; one that came from a wheel sector does not.
            s.makeDefaultPreset()
            try expect(s.isDefaultPreset)
            let fresh = h.session(files: [try h.file("b.stud")], target: StudioFixture.schemaID)
            try expectEqual(fresh.presetID, mine.id); try expectEqual(fresh.resolved?.values.int(FixtureKeys.quality), 22)
            let fromWheel = h.session(files: [try h.file("c.stud")], target: "test.studio.a")
            try expect(fromWheel.presetID == nil, "the wheel's sector decides, not the default preset")
            // Undo walks back through preset changes.
            fresh.apply(preset: web); fresh.undo()
            try expectEqual(fresh.presetID, mine.id); try expect(fresh.lockedKeys == [FixtureKeys.quality])
            fresh.clearPreset()
            try expect(fresh.presetID == nil && fresh.lockedKeys.isEmpty)
        }

        t.register("studio-core", "presets: duplicate, rename, delete keep the visible settings; export and import round-trip; nothing private is saved") {
            let h = StudioHarness(); defer { h.cleanup() }
            let s = h.probedSession(files: [try h.file()], operationID: "test.studio.a")
            s.set(FixtureKeys.quality, 21); s.set(FixtureKeys.password, "hunter2"); s.set(FixtureKeys.tracks, .rows([["source": 1]])); s.set("out.dirMode", "subfolder"); s.set(FixtureKeys.title, "Hi")
            let saved = s.valuesForSaving()
            try expectEqual(saved.int(FixtureKeys.quality), 21); try expectEqual(saved.string(FixtureKeys.title), "Hi")
            try expect(!saved.has(FixtureKeys.password) && !saved.has(FixtureKeys.tracks) && !saved.has("out.dirMode"), "no secrets, no track rows, no destination")
            try expect(s.isModified && s.changes.allSatisfy { !$0.change.key.hasPrefix("out.") }, "the destination is not part of Modified")
            let p = try s.saveAsPreset(name: "Mine", symbol: "star", group: .custom, locks: [], onWheel: nil)
            try expect(!p.values.has(FixtureKeys.password))
            try expectEqual(s.resolved?.values.string(FixtureKeys.password), "hunter2", "the secret stays in the session")
            let before = s.resolved?.values
            let copy = try s.duplicateCurrentPreset()
            try expect(copy.id != p.id && s.presetID == copy.id && copy.name.en == "Mine copy")
            try s.renameCurrentPreset(to: "Renamed")
            try expectEqual(h.presets.preset(id: copy.id)?.name.en, "Renamed")
            let url = h.fx.url("one.swampreset")
            try s.exportCurrentPreset(to: url)
            try s.deleteCurrentPreset()
            try expect(s.presetID == nil && h.presets.preset(id: copy.id) == nil)
            try expect(s.resolved?.values == before, "deleting a preset leaves the settings as they were")
            let back = try s.importPresets(from: url)
            try expectEqual(back.count, 1); try expectEqual(back[0].name.en, "Renamed"); try expectEqual(back[0].values.int(FixtureKeys.quality), 21)
            do { try s.deleteCurrentPreset(); throw TestFailure(message: "no preset selected", file: #fileID, line: #line) } catch is PresetError {}
            s.apply(preset: try unwrap(h.presets.preset(id: p.id)))
            let junk = h.fx.url("junk.swampreset"); try Data("not json".utf8).write(to: junk)
            do { _ = try s.importPresets(from: junk); throw TestFailure(message: "junk imported", file: #fileID, line: #line) } catch let e as PresetError { try expect(e.errorDescription == PresetError.notAPresetFile.errorDescription) }
        }

        t.register("studio-core", "output rules: the Output page and the destination control stay in step, and are not part of a preset or Modified") {
            let h = StudioHarness(); defer { h.cleanup() }
            let s = h.probedSession(files: [try h.file()], operationID: "test.studio.a")
            try expect(s.outputRulesOverride == nil && s.schema?.pages.last?.id == "output")
            s.set("out.dirMode", "subfolder"); s.set("out.subfolder", "Done")
            try expectEqual(s.outputRules.dirMode, .subfolder); try expectEqual(s.outputRules.subfolderName, "Done")
            try expectEqual(s.recipe().output?.subfolderName, "Done"); try expect(!s.isModified)
            s.outputRules.after = .reveal
            try expectEqual(s.values.string("out.after"), "reveal", "assigning the rules mirrors into the values the Output page shows")
            s.outputRules.after = .nothing
            try expect(!s.values.has("out.after"))
            s.revertAll()
            try expect(s.values.has("out.dirMode"), "Revert All leaves the destination alone")
            s.set("out.dirMode", nil); s.set("out.subfolder", nil)
            try expect(s.outputRulesOverride == nil)
        }

        t.register("studio-core", "estimate, chips and preview are computed off the main thread, keyed by the options, and a newer edit always wins") {
            let h = StudioHarness(); defer { h.cleanup() }
            let s = h.probedSession(files: [try h.file()], operationID: "test.studio.a")
            await s.settle()
            try expect(s.estimate?.bytes != nil && s.summaryChips.contains("CRF 23"), "computed on creation")
            let calls = h.hooks.estimateCalls.value
            for q in [31, 32, 33, 34, 35] { s.set(FixtureKeys.quality, .int(q)); s.lastUndoAt = .distantPast }
            await s.settle()
            try expect(s.summaryChips.contains("CRF 35"), "the last edit wins: \(s.summaryChips)")
            try expect(h.hooks.estimateCalls.value > calls)
            let big = s.estimate?.bytes ?? 0
            s.set(FixtureKeys.quality, 10); await s.settle()
            try expect((s.estimate?.bytes ?? 0) > big, "better quality, larger estimate")
            try expect(s.activeSource?.info != nil)
            // Preview: cancelled on request, on edit and on cancelPreview; results are tied to the options.
            h.hooks.previewDelay.value = 10_000_000_000
            s.requestPreview(time: 1, maxPixel: 256)
            try await T.waitUntil("preview start") { h.hooks.previewStarted.value == 1 }
            try expect(s.isPreviewing)
            s.cancelPreview()
            try await T.waitUntil("preview cancelled") { h.hooks.previewCancelled.value == 1 }
            try expect(!s.isPreviewing && s.preview == nil)
            h.hooks.previewDelay.value = 0
            s.requestPreview(time: 2, maxPixel: 256); await s.settle()
            try expectEqual(s.preview?.sampleOutputBytes, 4242 + 10); try expect(s.isPreviewCurrent && !s.isPreviewing)
            s.set(FixtureKeys.quality, 12)
            try expect(!s.isPreviewCurrent, "an edit makes the shown preview stale at once")
            await s.settle()
            try expectEqual(s.preview?.sampleOutputBytes, 4242 + 12); try expect(s.isPreviewCurrent)
            // A slow preview for old options is cancelled by a new request and never published.
            h.hooks.previewDelay.value = 10_000_000_000
            let startedBefore = h.hooks.previewStarted.value
            s.requestPreview(time: 3, maxPixel: 256)
            try await T.waitUntil("second slow preview") { h.hooks.previewStarted.value > startedBefore }
            let cancelledBefore = h.hooks.previewCancelled.value
            h.hooks.previewDelay.value = 0
            s.requestPreview(time: 4, maxPixel: 256); await s.settle()
            try await T.waitUntil("old preview cancelled") { h.hooks.previewCancelled.value > cancelledBefore }
            try expectEqual(s.preview?.sampleOutputBytes, 4242 + 12); try expect(s.isPreviewCurrent)
            // Measure turns a real sample into a measured estimate.
            s.measure()
            try await T.waitUntil("measured") { s.estimate?.confidence == .measured }
            try expectEqual(s.estimate?.bytes, 4242 + 12)
            s.cancelPreview()
        }

        t.register("studio-core", "inputs: probing fills the source and its computed defaults, a missing file fails calmly, files and links never mix") {
            let h = StudioHarness(); defer { h.cleanup() }
            let f = try h.file()
            let s = h.session(files: [f], target: "test.studio.a", autoProbe: true)
            try expect(s.isProbing, "background probing starts at once")
            try expectEqual(s.resolved?.values.string(FixtureKeys.limit), "1080", "before the probe the schema fallback applies")
            await s.probeAll()
            try expect(!s.isProbing && s.sources[0].status == .ready)
            let info = try unwrap(s.sources[0].info)
            try expect(!info.chips.isEmpty && info.streams.count == 4)
            try expectEqual(s.resolved?.values.string(FixtureKeys.limit), "2160", "a default computed from the probed source")
            try expect(s.isDefault(FixtureKeys.limit) && !s.isModified, "source-dependent defaults are defaults, not edits")
            try expectEqual(s.resolved?.values.rows(FixtureKeys.tracks).count, 2, "one audio row per audio stream")
            // A file that is not there.
            let gone = FileItem(url: h.fx.url("missing.stud"), isDirectory: false)
            let m = h.session(files: [gone], target: StudioFixture.schemaID, autoProbe: true)
            await m.probeAll()
            if case .failed(let why) = m.sources[0].status { try expect(!why.isEmpty) } else { throw TestFailure(message: "should fail", file: #fileID, line: #line) }
            try expect(!m.canStart)
            // Dedupe, add, remove, mixing.
            s.addSources([.file(f)]); try expectEqual(s.sources.count, 1)
            let link = LinkItem(url: URL(string: "https://example.com/watch?v=abc123")!, title: "A page")
            s.addSources([.link(link)])
            try expectEqual(s.sources.count, 2)
            if case .failed(let why) = s.sources[1].status { try expectEqual(why, StudioSession.mixedInputsReason) } else { throw TestFailure(message: "mixing must fail", file: #fileID, line: #line) }
            try expectEqual(s.activeFiles.count, 1); try expectEqual(s.activeLinks.count, 0)
            s.removeSource(id: s.sources[0].id)
            try expect(s.sources[0].status == .ready, "the link recovers when the file goes")
            try expect(s.isLinkSession); try expectEqual(s.targetID, "test.studio.dl"); try expectEqual(s.operationID, "test.studio.dl")
            try expect(s.canStart)
            // Several sources: the focused one decides source-dependent defaults.
            let two = h.session(files: [f, try h.file("b.stud")], target: StudioFixture.schemaID)
            let second = two.sources[1]
            var info2 = StudioFixture.sourceInfo(for: second.input.file!.url); info2.facts["video.height"] = .int(720)
            two.applyProbe(StudioFixture.sourceInfo(for: f.url), forSourceID: two.sources[0].id); two.applyProbe(info2, forSourceID: second.id)
            try expectEqual(two.resolved?.values.string(FixtureKeys.limit), "2160")
            two.focus(sourceID: second.id)
            try expectEqual(two.resolved?.values.string(FixtureKeys.limit), "720")
        }

        t.register("studio-core", "UI state is remembered: density per family, the inspector page per target; Cmd-number picks the n-th page") {
            let h = StudioHarness(); defer { h.cleanup() }
            let s = h.probedSession(files: [try h.file()], operationID: "test.studio.a")
            try expectEqual(s.density, .simple); try expectEqual(s.selectedPageID, "main")
            s.density = .advanced
            try expectEqual(h.settings.data.studio.densityByFamily["video"], .advanced)
            s.selectPage(at: 1)
            try expectEqual(s.selectedPageID, "extra"); try expectEqual(h.settings.data.studio.inspectorPage[StudioFixture.schemaID], "extra")
            s.selectPage(at: 9); try expectEqual(s.selectedPageID, "extra", "out of range is ignored")
            let again = h.probedSession(files: [try h.file("again.stud")], operationID: "test.studio.a")
            try expectEqual(again.density, .advanced); try expectEqual(again.selectedPageID, "extra")
            let before = s.searchFocusToken; s.focusSearch(); try expectEqual(s.searchFocusToken, before + 1)
        }
    }
}
