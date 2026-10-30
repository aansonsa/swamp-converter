import Foundation

/// `--set key=value` typing against a fixture schema that has a field of every kind.
enum CLITestsOptions {
    private static func typed(_ sets: [String]) throws -> OptionValues {
        switch CLIArguments.optionValues(from: sets, schema: CLIFixtureOp.schema()) {
        case .success(let v): return v
        case .failure(let e): throw TestFailure(message: "typing \(sets) failed: \(e.message)", file: #fileID, line: #line)
        }
    }

    private static func problem(_ sets: [String], schema: OptionSchema = CLIFixtureOp.schema()) throws -> String {
        let saved = Loc.shared.setting
        Loc.shared.set(.english)
        defer { Loc.shared.set(saved) }
        switch CLIArguments.optionValues(from: sets, schema: schema) {
        case .success(let v): throw TestFailure(message: "expected an error for \(sets), got \(v.storage)", file: #fileID, line: #line)
        case .failure(let e): return e.message
        }
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("cli.options", "values are typed from the field kind: bool, int, number, seconds, choice, colour, text") {
            let v = try typed(["f.text=a=b c", "f.count=3", "f.upper=yes", "f.level=7", "f.mode=B", "f.start=1:30", "f.gain=1,5", "f.color=ff72d9"])
            try expectEqual(v["f.text"], .string("a=b c")); try expectEqual(v["f.count"], .int(3)); try expectEqual(v["f.upper"], .bool(true))
            try expectEqual(v["f.level"], .int(7), "an integral slider gives an Int"); try expectEqual(v["f.mode"], .string("b"), "choices match without regard to case")
            try expectEqual(v["f.start"], .double(90), "1:30 is 90 seconds"); try expectEqual(v["f.gain"], .double(1.5), "a decimal comma works")
            try expectEqual(v["f.color"], .string("#FF72D9"), "a colour gets its # and upper case")
            let w = try typed(["f.upper=Off", "f.start=01:02:03.5", "f.start=", "f.mode=Bee", "f.gain=-20", "f.level=0"])
            try expectEqual(w["f.upper"], .bool(false)); try expectEqual(w["f.start"], .string(""), "the last value wins; an empty time means not set")
            try expectEqual(w["f.mode"], .string("b"), "a choice matches its label too"); try expectEqual(w["f.gain"], .double(-20)); try expectEqual(w["f.level"], .int(0))
            try expectEqual(try typed(["f.start=01:02:03.5"])["f.start"], .double(3723.5))
            for word in ["true", "TRUE", "on", "1", "да", "вкл"] { try expectEqual(try typed(["f.upper=\(word)"])["f.upper"], .bool(true), word) }
            for word in ["false", "No", "off", "0", "нет", "выкл"] { try expectEqual(try typed(["f.upper=\(word)"])["f.upper"], .bool(false), word) }
            try expectEqual(try typed([]).isEmpty, true)
        }

        t.register("cli.options", "folders become absolute paths; ~ and relative names are resolved") {
            let home = (("~" as NSString).expandingTildeInPath)
            try expectEqual(try typed(["f.dir=~/Movies"])["f.dir"], .string(home + "/Movies"))
            let rel = try typed(["f.dir=sub/../x y"])["f.dir"]?.asString ?? ""
            try expect(rel.hasPrefix("/") && rel.hasSuffix("/x y") && !rel.contains(".."), rel)
            try expectEqual(try typed(["f.dir="])["f.dir"], .string(""), "empty stays empty")
        }

        t.register("cli.options", "track lists come as JSON rows") {
            let v = try typed(["f.tracks=[{\"codec\":\"ac3\",\"bitrate\":384},{\"codec\":\"aac\"}]"])
            let rows = try unwrap(v["f.tracks"]?.asRows, "rows")
            try expectEqual(rows.count, 2); try expectEqual(rows[0]["codec"], .string("ac3")); try expectEqual(rows[0]["bitrate"], .int(384))
            try expectEqual(try typed(["f.tracks=[]"])["f.tracks"]?.asRows?.count, 0)
            try expectEqual(try typed(["f.tracks="])["f.tracks"]?.asRows?.count, 0)
            try expect(try problem(["f.tracks={bad"]).contains("JSON list"))
        }

        t.register("cli.options", "unknown keys are usage errors with the nearest valid key; a bare name finds its dotted key") {
            let a = try problem(["f.cnt=3"])
            try expect(a.contains("Unknown option 'f.cnt'") && a.contains("Did you mean 'f.count'?"), a)
            let b = try problem(["count=3"])
            try expect(b.contains("Did you mean 'f.count'?"), "a suffix names the key: \(b)")
            let c = try problem(["zzzzzzzzzz=1"])
            try expect(c.contains("swamp options"), "no near key: point at the options command: \(c)")
            let d = try problem(["x=1"], schema: OptionSchema.empty(id: "none"))
            try expect(d.contains("has no options"), d)
            try expect(try problem(["novalue"]).contains("key=value"))
        }

        t.register("cli.options", "out-of-range, wrong-type and non-member values are usage errors that say what was expected") {
            let range = try problem(["f.count=9"])
            try expect(range.contains("'f.count'") && range.contains("1...5"), range)
            try expect(try problem(["f.count=2.5"]).contains("whole number"))
            try expect(try problem(["f.count=abc"]).contains("whole number"))
            try expect(try problem(["f.level=11"]).contains("0...10"))
            try expect(try problem(["f.level=-1"]).contains("0...10"))
            try expect(try problem(["f.level=nan"]).contains("expected a number"))
            try expect(try problem(["f.gain=99"]).contains("above the maximum"))
            try expect(try problem(["f.gain=-99"]).contains("below the minimum"))
            try expect(try problem(["f.upper=maybe"]).contains("true or false"))
            let mode = try problem(["f.mode=z"])
            try expect(mode.contains("not one of: a, b, c"), mode)
            try expect(try problem(["f.start=abc"]).contains("expected a time"))
            try expect(try problem(["f.start=1:2:3:4"]).contains("expected a time"))
            try expect(try problem(["f.start=-5"]).contains("expected a time"))
            try expect(try problem(["f.color=red"]).contains("#FF72D9"))
            try expect(try problem(["f.color=#12345"]).contains("expected a colour"))
        }

        t.register("cli.options", "the quick recipe and --set layer correctly through the schema (set wins, inactive and unusable values are reported)") {
            let schema = CLIFixtureOp.schema()
            let op = CLIFixtureOp()
            let quick = op.quickOverrides(settings: SettingsData())
            let resolved = schema.resolve(layers: [quick, try typed(["f.count=4", "f.level=9", "f.mode=c"])])
            try expectEqual(resolved.values.string("f.text"), "quick", "the quick recipe supplies what --set leaves alone")
            try expectEqual(resolved.values.int("f.count"), 4, "--set beats the quick recipe")
            try expect(resolved.inactive.contains("f.level"), "f.level is off while f.upper is off")
            try expectEqual(resolved.values.string("f.mode"), "a", "an option whose capability is missing falls back")
        }
    }
}
