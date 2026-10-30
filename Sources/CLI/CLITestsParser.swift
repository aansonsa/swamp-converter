import Foundation

/// Golden tests of the pure parser: every command shape, the quoting rules (`--`, `=`), and every kind of usage error.
enum CLITestsParser {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("cli.parser", "convert: files, --op, repeated --set, --out, --json in any order, both --key value and --key=value") {
            let a = try cliParse(["convert", "a.png", "b.png", "--op", "image.to.jpg", "--set", "img.quality=80", "--set=img.progressive=true", "--out", "/tmp/o", "--json"])
            try expectEqual(a, CLIInvocation(command: .convert, positional: ["a.png", "b.png"], options: ["op": "image.to.jpg", "out": "/tmp/o"],
                                             sets: ["img.quality=80", "img.progressive=true"], json: true, flags: []))
            let b = try cliParse(["convert", "--op=png", "--preset=Web 720", "x.mp4", "-o", "out"])
            try expectEqual(b.positional, ["x.mp4"]); try expectEqual(b.options, ["op": "png", "preset": "Web 720", "out": "out"])
            let c = try cliParse(["convert", "--preset", "my", "a.mov"])
            try expectEqual(c.options["preset"], "my"); try expectEqual(c.options["op"], nil)
            let d = try cliParse(["convert", "a.png", "--op", "x", "--set", "k=a=b=c"])
            try expectEqual(d.sets, ["k=a=b=c"], "only the first = splits")
            let e = try cliParse(["convert", "a.png", "--op", "x", "--op", "y"])
            try expectEqual(e.options["op"], "y", "the last --op wins")
        }

        t.register("cli.parser", "`--` ends the options: names with a leading dash, even ones that look like options") {
            let a = try cliParse(["convert", "--op", "png", "--", "-weird.png", "--not-an-option", "my file.png"])
            try expectEqual(a.positional, ["-weird.png", "--not-an-option", "my file.png"])
            try expectEqual(a.options, ["op": "png"]); try expect(!a.json)
            let b = try cliParse(["convert", "--op", "png", "--", "--json"])
            try expect(!b.json && b.positional == ["--json"], "--json after -- is a file name")
            try expect(!CLI.jsonRequested(["convert", "--", "--json"]) && CLI.jsonRequested(["convert", "--json"]))
        }

        t.register("cli.parser", "download, probe, list-ops, options: each command's own options and switches") {
            let d = try cliParse(["download", "https://youtu.be/abc", "--mode", "maximum", "--out", "~/Movies", "--consent", "--json", "--set", "dl.maxHeight=720"])
            try expectEqual(d.command, .download); try expectEqual(d.positional, ["https://youtu.be/abc"])
            try expectEqual(d.options["mode"], "max", "friendly mode names are normalised")
            try expect(d.flags.contains("consent") && d.json); try expectEqual(d.sets, ["dl.maxHeight=720"])
            for (given, normal) in [("best", "best"), ("apple", "best"), ("universal", "universal"), ("audio-m4a", "audio-m4a"), ("mp3", "audio-mp3")] {
                try expectEqual(try cliParse(["download", "https://a.b/c", "--mode=\(given)"]).options["mode"], normal)
            }
            let p = try cliParse(["probe", "a.mov", "--plan", "--pretty"])
            try expectEqual(p.command, .probe); try expect(p.flags == ["plan", "pretty"])
            let l = try cliParse(["list-ops", "--kind", "VIDEO", "--available", "--json"])
            try expectEqual(l.options["kind"], "video"); try expect(l.flags.contains("available") && l.json)
            try expectEqual(try cliParse(["list-ops", "--kind=convert"]).options["kind"], "convert", "a wheel is a kind too")
            let o = try cliParse(["options", "image.to.jpg", "--json"])
            try expectEqual(o.command, .options); try expectEqual(o.positional, ["image.to.jpg"])
        }

        t.register("cli.parser", "presets: list is the default, show / export / import take their arguments") {
            try expectEqual(try cliParse(["presets"]).positional, [])
            try expectEqual(try cliParse(["presets", "list", "--target", "video.convert", "--json"]).options["target"], "video.convert")
            try expectEqual(try cliParse(["presets", "show", "Web 720"]).positional, ["show", "Web 720"])
            let e = try cliParse(["presets", "export", "web", "/tmp/x.swampreset", "--force"])
            try expectEqual(e.positional, ["export", "web", "/tmp/x.swampreset"]); try expect(e.flags.contains("force"))
            try expectEqual(try cliParse(["presets", "import", "f.swampreset"]).positional, ["import", "f.swampreset"])
        }

        t.register("cli.parser", "version and help forms: --version, --help, help <command>, <command> --help, -h") {
            try expectEqual(try cliParse(["version"]).command, .version)
            try expectEqual(try cliParse(["--version"]).command, .version)
            try expectEqual(try cliParse(["version", "--json"]).json, true)
            try expectEqual(try cliParse(["help"]), CLIInvocation(command: .help))
            try expectEqual(try cliParse(["help", "convert"]).positional, ["convert"])
            try expectEqual(try cliParse(["--help"]).command, .help)
            let h = try cliParse(["convert", "--help"])
            try expect(h.command == .help && h.positional == ["convert"], "convert --help is help for convert")
            let h2 = try cliParse(["download", "-h"])
            try expect(h2.command == .help && h2.positional == ["download"])
            try expectEqual(try cliParse(["--cli", "version"]).command, .version, "the --cli prefix is accepted")
        }

        t.register("cli.parser", "global switches: --quiet -q --verbose -v --pretty --lang; --json=false switches off") {
            let a = try cliParse(["list-ops", "-q", "-v", "--pretty", "--lang", "Russian"])
            try expect(a.flags == ["quiet", "verbose", "pretty"]); try expectEqual(a.options["lang"], "ru")
            try expectEqual(try cliParse(["list-ops", "--lang=en"]).options["lang"], "en")
            try expectEqual(try cliParse(["list-ops", "--lang", "system"]).options["lang"], "system")
            try expectEqual(try cliParse(["list-ops", "--json=false"]).json, false)
            try expectEqual(try cliParse(["list-ops", "--json=true"]).json, true)
            try expect(!(try cliParse(["list-ops", "--quiet=no"]).flags.contains("quiet")))
        }

        t.register("cli.parser", "usage errors name the problem and suggest the nearest command or option") {
            try expect(try cliParseError([]).contains("No command"))
            let convrt = try cliParseError(["convrt"])
            try expect(convrt.contains("Did you mean 'convert'"), convrt)
            try expect(try cliParseError(["frobnicate"]).contains("Unknown command 'frobnicate'"))
            let otp = try cliParseError(["convert", "a.png", "--otp", "x"])
            try expect(otp.contains("Unknown option --otp") && otp.contains("Did you mean --op?"), otp)
            try expect(try cliParseError(["convert", "a.png", "--op"]).contains("--op needs a value"))
            try expect(try cliParseError(["convert", "a.png", "--op", "--json"]).contains("--op needs a value"), "an option is not a value")
            try expect(try cliParseError(["convert", "--op", "x"]).contains("at least one file"))
            try expect(try cliParseError(["convert", "a.png"]).contains("--op"))
            try expect(try cliParseError(["convert", "a.png", "--op", "x", "--set", "novalue"]).contains("key=value"))
            try expect(try cliParseError(["convert", "a.png", "--op", "x", "--set", "=5"]).contains("key=value"))
            try expect(try cliParseError(["convert", "a.png", "--op", "x", "--json=maybe"]).contains("takes no value"))
            try expect(try cliParseError(["convert", "a.png", "--op", "x", "-x"]).contains("Unknown option -x"))
            try expect(try cliParseError(["download"]).contains("exactly one link"))
            try expect(try cliParseError(["download", "a", "b"]).contains("exactly one link"))
            try expect(try cliParseError(["download", "https://a.b/c", "--mode", "bogus"]).contains("Unknown download mode 'bogus'"))
            try expect(try cliParseError(["download", "https://a.b/c", "--out"]).contains("needs a value"))
            try expect(try cliParseError(["list-ops", "--kind", "nope"]).contains("Unknown kind 'nope'"))
            try expect(try cliParseError(["list-ops", "x"]).contains("no arguments"))
            try expect(try cliParseError(["list-ops", "--lang", "klingon"]).contains("Unknown language"))
            try expect(try cliParseError(["presets", "frob"]).contains("Unknown presets command"))
            try expect(try cliParseError(["presets", "show"]).contains("Usage: swamp presets show"))
            try expect(try cliParseError(["presets", "export", "a"]).contains("Usage: swamp presets export"))
            try expect(try cliParseError(["probe"]).contains("exactly one file"))
            try expect(try cliParseError(["options"]).contains("exactly one operation"))
            try expect(try cliParseError(["version", "x"]).contains("no arguments"))
            try expect(try cliParseError(["convert", "a.png", "--op", "x", "--plan"]).contains("Unknown option --plan"), "options of other commands are not accepted")
        }

        t.register("cli.parser", "usage errors are localised: Russian text when the language is Russian") {
            let saved = Loc.shared.setting
            Loc.shared.set(.russian)
            defer { Loc.shared.set(saved) }
            guard case .failure(let e) = CLIArguments.parse(["convrt"]) else { throw TestFailure(message: "should fail", file: #fileID, line: #line) }
            try expect(e.message.contains("Неизвестная команда") && e.message.contains("convert"), e.message)
            guard case .failure(let e2) = CLIArguments.parse(["convert", "a", "--op"]) else { throw TestFailure(message: "should fail", file: #fileID, line: #line) }
            try expect(e2.message.contains("нужно указать значение"), e2.message)
        }

        t.register("cli.parser", "suggestions: suffix match, edit distance, nothing for unrelated words") {
            try expectEqual(CLISuggest.nearest("crf", among: ["video.crf", "video.preset"]), "video.crf")
            try expectEqual(CLISuggest.nearest("vidoe.crf", among: ["video.crf", "video.preset"]), "video.crf")
            try expectEqual(CLISuggest.nearest("zzzzzzzz", among: ["video.crf", "video.preset"]), nil)
            try expectEqual(CLISuggest.nearest("", among: ["a"]), nil)
            try expectEqual(CLISuggest.distance("kitten", "sitting"), 3)
            try expectEqual(CLISuggest.closest("jpg", among: ["image.to.jpg", "image.to.png", "pdf.merge"], limit: 1), ["image.to.jpg"])
        }
    }
}
