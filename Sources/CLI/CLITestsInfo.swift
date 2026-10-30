import Foundation

/// The read-only commands: list-ops equals the registry, options equals the schema, probe, presets (list / show / export / import), version, help.
enum CLITestsInfo {
    @MainActor private static func rig(_ body: (CLIRig) async throws -> Void) async throws {
        let rig = CLIRig()
        defer { rig.cleanup() }
        try await body(rig)
    }

    private static func doc(_ r: CLIResult) throws -> [String: Any] {
        try expectEqual(r.lines.count, 1, "a JSON document is ONE line: \(r.stdout.prefix(200))")
        return try unwrap(CLIJSON.parseObject(r.lines[0]), "the line is a JSON object")
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("cli.info", "list-ops --json equals the registry: same operations, same order, same facts (shared registry with the real engines)") {
            let sink = CLISink()
            let code = await CLI.run(arguments: ["list-ops", "--json"], environment: CLIEnvironment(), sink: sink)
            try expectEqual(code, 0)
            let d = try unwrap(CLIJSON.parseObject(try unwrap(sink.stdoutLines.first)))
            try expectEqual(sink.stdoutLines.count, 1)
            let ops = try unwrap(d["operations"] as? [[String: Any]])
            let registry = OperationRegistry.shared.allOperations()
            try expectEqual(ops.map { $0["id"] as? String ?? "" }, registry.map(\.meta.id), "ids and catalogue order")
            try expectEqual(d["count"] as? Int, registry.count)
            for (json, op) in zip(ops, registry) {
                try expectEqual(json["wheel"] as? String, op.meta.wheel.rawValue, op.meta.id)
                try expectEqual(json["schema"] as? String, op.meta.schemaID, op.meta.id)
                try expectEqual(json["family"] as? String, op.meta.family.rawValue)
                try expectEqual(json["usesNetwork"] as? Bool, op.meta.usesNetwork, op.meta.id)
                let availability = op.availability(for: [], tools: .shared)
                try expectEqual(json["available"] as? Bool, availability.isAvailable, op.meta.id)
                try expectEqual(json["reason"] is NSNull, availability.isAvailable, "a reason exactly when unavailable: \(op.meta.id)")
                let label = try unwrap(json["label"] as? [String: String])
                try expectEqual(label["en"], op.meta.label.en)
            }
            // Download operations are the ones that use the network, and nothing else does.
            let net = Set(ops.filter { ($0["usesNetwork"] as? Bool) == true }.compactMap { $0["id"] as? String })
            try expect(net.allSatisfy { $0.hasPrefix("link.") }, "only link operations use the network: \(net)")
        }

        t.register("cli.info", "list-ops: --kind filters by family or wheel, --available hides the unavailable, human mode is one line per operation") {
            try await rig { rig in
                let all = try doc(await rig.run(["list-ops", "--json"]))
                try expectEqual((all["operations"] as? [[String: Any]])?.map { $0["id"] as? String }, rig.registry.allOperations().map { $0.meta.id })
                let app = try doc(await rig.run(["list-ops", "--json", "--kind", "app"]))
                let appIDs = (app["operations"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
                try expect(appIDs.contains("test.cli.report") && !appIDs.contains("test.cli.png"), "family app: \(appIDs)")
                let image = try doc(await rig.run(["list-ops", "--json", "--kind", "image"]))
                try expectEqual((image["operations"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["test.cli.png"])
                let actions = try doc(await rig.run(["list-ops", "--json", "--kind", "actions"]))
                try expectEqual((actions["operations"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["test.cli.action"], "a wheel name is a kind too")
                let avail = try doc(await rig.run(["list-ops", "--json", "--available"]))
                let ids = (avail["operations"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
                try expect(!ids.contains("test.cli.unavailable") && ids.contains("test.cli.report"), "--available: \(ids)")
                let human = await rig.run(["list-ops"])
                try expectEqual(human.code, 0); try expectEqual(human.lines.count, rig.registry.allOperations().count)
                try expect(human.lines.contains { $0.hasPrefix("test.cli.unavailable") && $0.contains("Needs Pandoc") }, "the reason is shown: \(human.stdout)")
                let pretty = await rig.run(["list-ops", "--json", "--pretty", "--kind", "actions"])
                try expect(pretty.lines.count > 3, "--pretty indents the document")
                try expect(CLIJSON.parseObject(pretty.stdout) != nil, "and it is still one JSON document")
            }
        }

        t.register("cli.info", "options --json lists every knob of the schema: keys, kinds, defaults, quick values, ranges, choices; secrets have no value") {
            try await rig { rig in
                let d = try doc(await rig.run(["options", "test.cli.report", "--json"]))
                let schema = CLIFixtureOp().studioSchema(for: [])
                try expectEqual(d["operation"] as? String, "test.cli.report"); try expectEqual(d["schema"] as? String, "test.cli")
                try expectEqual(d["fieldCount"] as? Int, schema.allFields.count)
                var fields: [String: [String: Any]] = [:]
                for p in try unwrap(d["pages"] as? [[String: Any]]) { for g in try unwrap(p["groups"] as? [[String: Any]]) { for f in try unwrap(g["fields"] as? [[String: Any]]) { fields[f["key"] as? String ?? ""] = f } } }
                try expectEqual(Set(fields.keys), Set(schema.allFields.map(\.key)), "every field of the schema, the Output page included")
                try expect(fields.keys.contains("out.dir") && fields.keys.contains("out.collision"), "the Output page keys are options too")
                try expectEqual(fields["f.text"]?["kind"] as? String, "text"); try expectEqual(fields["f.text"]?["default"] as? String, "hello")
                try expectEqual(fields["f.text"]?["quick"] as? String, "quick", "the value the wheel uses")
                try expectEqual(fields["f.count"]?["quick"] as? Int, 2); try expectEqual(fields["f.count"]?["min"] as? Int, 1); try expectEqual(fields["f.count"]?["max"] as? Int, 5)
                try expectEqual(fields["f.level"]?["max"] as? Double, 10); try expectEqual(fields["f.level"]?["conditional"] as? Bool, true)
                let options = try unwrap(fields["f.mode"]?["options"] as? [[String: Any]])
                try expectEqual(options.map { $0["value"] as? String }, ["a", "b", "c"]); try expectEqual(options.map { $0["available"] as? Bool }, [true, true, false])
                try expectEqual(fields["f.start"]?["kind"] as? String, "time"); try expectEqual(fields["f.gain"]?["unit"] as? String, "dB")
                try expectEqual(fields["f.needs"]?["available"] as? Bool, false); try expectEqual(fields["f.needs"]?["requires"] as? [String], ["tool.nonexistent"])
                try expectEqual(fields["f.secret"]?["secret"] as? Bool, true); try expect(fields["f.secret"]?["default"] == nil, "a secret field shows no value")
                try expectEqual(fields["f.tracks"]?["kind"] as? String, "tracks"); try expectEqual((fields["f.tracks"]?["columns"] as? [[String: Any]])?.count, 2)
                for f in schema.allFields {
                    let label = try unwrap(fields[f.key]?["label"] as? [String: String]); try expectEqual(label["en"], f.label.en, f.key)
                }
                let human = await rig.run(["options", "test.cli"])
                try expectEqual(human.code, 0, "a target id works too")
                try expect(human.stdout.contains("f.count  stepper  = 1 (quick: 2)  [1...5]"), human.stdout)
                try expect(human.stdout.contains("f.mode  picker  = a  {a|b|c}"), human.stdout)
                let unknown = await rig.run(["options", "test.cli.reprot"])
                try expectEqual(unknown.code, 2); try expect(unknown.stderr.contains("Did you mean"), unknown.stderr)
            }
        }

        t.register("cli.info", "options on a real operation matches its schema (when the engine is registered)") {
            guard let op = OperationRegistry.shared.allOperations().first(where: { !$0.optionSchema(for: []).allFields.isEmpty && !$0.meta.isAppAction }) else {
                try skipTest("no registered operation with options in this build")
            }
            let sink = CLISink()
            let code = await CLI.run(arguments: ["options", op.meta.id, "--json"], environment: CLIEnvironment(), sink: sink)
            try expectEqual(code, 0, sink.stderr)
            let d = try unwrap(CLIJSON.parseObject(try unwrap(sink.stdoutLines.first)))
            let schema = op.studioSchema(for: [])
            try expectEqual(d["fieldCount"] as? Int, schema.allFields.count, op.meta.id)
            var keys: [String] = []
            for p in try unwrap(d["pages"] as? [[String: Any]]) { for g in try unwrap(p["groups"] as? [[String: Any]]) { for f in try unwrap(g["fields"] as? [[String: Any]]) { keys.append(f["key"] as? String ?? "") } } }
            try expectEqual(keys, schema.allFields.map(\.key), "same keys in the same order")
        }

        t.register("cli.info", "probe: facts of a generated PNG as JSON and as text; a missing file is a usage error; --plan needs a video") {
            try await rig { rig in
                let png = try rig.fx.png("probe me.png", width: 64, height: 48)
                let size = Int64(TestFile.size(png))
                let d = try doc(await rig.run(["probe", png.path, "--json"]))
                try expectEqual(d["kind"] as? String, "image"); try expectEqual(d["name"] as? String, "probe me.png"); try expectEqual(d["file"] as? String, png.path)
                try expectEqual((d["size"] as? NSNumber)?.int64Value, size)
                let facts = try unwrap(d["facts"] as? [String: Any])
                if let w = facts["image.width"] { try expectEqual(w as? Int, 64, "the image probe is registered: width"); try expectEqual(facts["image.height"] as? Int, 48) }
                try expect(d["chips"] is [Any] && d["streams"] is [Any] && d["warnings"] is [Any])
                let human = await rig.run(["probe", png.path])
                try expectEqual(human.code, 0); try expect(human.lines.first?.hasPrefix("probe me.png  (Image") == true, human.stdout)
                let missing = await rig.run(["probe", rig.fx.url("nothing.png").path, "--json"])
                try expectEqual(missing.code, 2); try expectEqual(try missing.events().first?["event"] as? String, "error")
                let plan = await rig.run(["probe", png.path, "--plan"])
                try expectEqual(plan.code, 3); try expect(plan.stderr.contains("only for video"), plan.stderr); try expect(plan.stdout.isEmpty)
            }
        }

        t.register("cli.info", "probe --plan on a generated video: a plan for each of Best for Apple, Maximum, Universal", requires: ["tool.ffmpeg"]) {
            let rig = CLIRig()
            defer { rig.cleanup() }
            let clip = try await rig.fx.video("clip.mp4", seconds: 1)
            // The shared registry has the real probes; the rig's registry is irrelevant for probe.
            let sink = CLISink()
            let code = await CLI.run(arguments: ["probe", clip.path, "--plan", "--json"], environment: rig.environment, sink: sink)
            if code == 3 { try skipTest("media probing is not available in this build: \(sink.stdout)") }
            try expectEqual(code, 0, sink.stdout + sink.stderr)
            let d = try unwrap(CLIJSON.parseObject(try unwrap(sink.stdoutLines.first)))
            let plans = try unwrap(d["plans"] as? [String: [String: Any]])
            try expectEqual(Set(plans.keys), ["best", "max", "universal"])
            for (mode, p) in plans {
                try expectEqual(p["mode"] as? String, mode); try expect((p["container"] as? String ?? "").isEmpty == false, "a container for \(mode)")
                try expect((p["video"] as? [String: Any])?["action"] is String)
            }
            try expect(plans["best"]?["remux"] is Bool && plans["max"]?["faststart"] is Bool, "the plan carries the remux and faststart facts")
        }

        t.register("cli.info", "presets: list / show / export / import round trip, filters, refusal to overwrite") {
            try await rig { rig in
                let a = try rig.presets.create(name: "Alpha", targetID: "test.cli", values: ["f.text": "A", "f.count": 3])
                _ = try rig.presets.create(name: "Beta", targetID: "test.cli.flaky", values: [:])
                let list = try doc(await rig.run(["presets", "list", "--json"]))
                try expectEqual(list["count"] as? Int, 2); try expectEqual((list["presets"] as? [[String: Any]])?.count, rig.presets.all.count)
                let filtered = try doc(await rig.run(["presets", "--target", "test.cli", "--json"]))
                try expectEqual((filtered["presets"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [a.id], "list is the default and --target filters")
                let human = await rig.run(["presets", "list"])
                try expectEqual(human.lines.count, 2); try expect(human.stdout.contains("Alpha") && human.stdout.contains("test.cli.flaky"))

                let shown = try doc(await rig.run(["presets", "show", "alpha", "--json"]))
                try expectEqual(shown["id"] as? String, a.id)
                let values = try unwrap(shown["values"] as? [String: Any]); try expectEqual(values["f.text"] as? String, "A"); try expectEqual(values["f.count"] as? Int, 3)
                let text = await rig.run(["presets", "show", a.id])
                try expect(text.stdout.contains("f.count = 3") && text.stdout.contains("f.text = A"), text.stdout)
                let missing = await rig.run(["presets", "show", "Gamma"])
                try expectEqual(missing.code, 2); try expect(missing.stderr.contains("Unknown preset"), missing.stderr)

                let file = rig.fx.url("alpha.swampreset")
                let exported = await rig.run(["presets", "export", "Alpha", file.path])
                try expectEqual(exported.code, 0, exported.stderr); try expectEqual(exported.lines, [file.path])
                try expect(FileManager.default.fileExists(atPath: file.path))
                let again = await rig.run(["presets", "export", "Alpha", file.path])
                try expectEqual(again.code, 2, "an existing file is not overwritten"); try expect(again.stderr.contains("--force"), again.stderr)
                let forced = await rig.run(["presets", "export", "Alpha", file.path, "--force"])
                try expectEqual(forced.code, 0)

                // Import into a second, empty world.
                let other = CLIRig()
                defer { other.cleanup() }
                let imported = try doc(await other.run(["presets", "import", file.path, "--json"]))
                let ids = try unwrap(imported["imported"] as? [String])
                try expectEqual(ids.count, 1)
                let p = try unwrap(other.presets.preset(id: ids[0]))
                try expectEqual(p.name.en, "Alpha"); try expectEqual(p.targetID, "test.cli"); try expectEqual(p.values["f.text"], .string("A")); try expectEqual(p.values["f.count"], .int(3))
                let noFile = await other.run(["presets", "import", other.fx.url("nope.swampreset").path])
                try expectEqual(noFile.code, 2)
                let garbage = try other.file("garbage.swampreset", "this is not json")
                let bad = await other.run(["presets", "import", garbage.path])
                try expectEqual(bad.code, 1, "not a preset file"); try expect(bad.stderr.contains("not a preset file"), bad.stderr)
            }
        }

        t.register("cli.info", "version and help: text, JSON, per-command help, unknown topics") {
            try await rig { rig in
                let v = await rig.run(["version"])
                try expectEqual(v.code, 0); try expect(v.stdout.hasPrefix("swamp "), v.stdout)
                let vj = try doc(await rig.run(["version", "--json"]))
                try expectEqual(vj["name"] as? String, "swamp"); try expect(vj["version"] is String && vj["tools"] is [String: Any])
                let h = await rig.run(["help"])
                try expectEqual(h.code, 0)
                for verb in ["convert", "download", "probe", "list-ops", "options", "presets", "version"] { try expect(h.stdout.contains("swamp \(verb)"), "help mentions \(verb)") }
                try expect(h.stdout.contains("130"), "help lists the exit codes")
                for c in CLICommand.allCases {
                    let one = await rig.run(["help", c.rawValue])
                    try expectEqual(one.code, 0, c.rawValue); try expect(one.stdout.contains("swamp"), "help \(c.rawValue)")
                }
                let viaFlag = await rig.run(["convert", "--help"])
                try expectEqual(viaFlag.code, 0); try expect(viaFlag.stdout.contains("--set k=v"))
                let bad = await rig.run(["help", "frobnicate"])
                try expectEqual(bad.code, 2)
                let json = try doc(await rig.run(["help", "--json"]))
                try expect((json["usage"] as? String ?? "").contains("swamp convert"))
            }
        }
    }
}
