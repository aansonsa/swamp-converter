import Foundation
import PDFKit

// Engine selection and the two optional engines. The router is proven on a table with fake tool sets; the argument lists of Pandoc and LibreOffice by golden values; the
// whole path (route -> process -> result moved into place) with fake `pandoc` / `soffice` scripts, including a failing LibreOffice, a hung one (watchdog) and a cancelled
// one (the process tree must be gone and nothing may be left behind). The real LibreOffice runs only when it is installed (SKIP otherwise).

enum DocsRouteTests {
    // MARK: Fake tools

    /// A folder with a fake `pandoc` and `soffice` (zsh scripts that record their arguments) and a `ToolLocator` that finds them first.
    struct FakeTools {
        let dir: URL
        let locator: ToolLocator
        var pandoc: URL { dir.appendingPathComponent("pandoc") }
        var soffice: URL { dir.appendingPathComponent("soffice") }

        init(_ fx: TestFixtures) throws {
            dir = try fx.makeDirectory("fake-tools-\(Util.hex8())")
            let pandocScript = """
            #!/bin/zsh
            dir=${0:A:h}
            if [[ $1 == --version ]]; then print "pandoc 3.1.11"; exit 0; fi
            printf '%s\\n' "$@" > $dir/pandoc.last
            print -r -- "$@" >> $dir/pandoc.calls
            args=("$@"); out=""
            for ((i=1; i<=$#args; i++)); do [[ ${args[i]} == -o ]] && out=${args[i+1]}; done
            print "FAKE-PANDOC-OUTPUT" > $out
            """
            let officeScript = """
            #!/bin/zsh
            dir=${0:A:h}
            printf '%s\\n' "$@" > $dir/soffice.last
            print -r -- "$@" >> $dir/soffice.calls
            args=("$@"); out=""; target=""
            for ((i=1; i<=$#args; i++)); do
              [[ ${args[i]} == --outdir ]] && out=${args[i+1]}
              [[ ${args[i]} == --convert-to ]] && target=${args[i+1]}
            done
            inp=${args[-1]}; ext=${target%%:*}; base=${inp:t:r}
            mode=$(cat $dir/soffice.mode 2>/dev/null)
            case $mode in
              hang) print $$ > $dir/soffice.pid; sleep 120 & print $! > $dir/child.pid; wait ;;
              fail) exit 0 ;;
              *) mkdir -p $out
                 if [[ -f $dir/payload.$ext ]]; then cp $dir/payload.$ext "$out/$base.$ext"; else print "FAKE-LIBREOFFICE-OUTPUT" > "$out/$base.$ext"; fi ;;
            esac
            """
            try Data(pandocScript.utf8).write(to: dir.appendingPathComponent("pandoc"))
            try Data(officeScript.utf8).write(to: dir.appendingPathComponent("soffice"))
            for n in ["pandoc", "soffice"] { chmod(dir.appendingPathComponent(n).path, 0o755) }
            locator = ToolLocator()
            locator.setUserOverrides(["pandoc": dir.appendingPathComponent("pandoc").path, "soffice": dir.appendingPathComponent("soffice").path])
        }

        func read(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        func setMode(_ m: String) throws { try Data(m.utf8).write(to: dir.appendingPathComponent("soffice.mode")) }
        func calls(_ file: String) -> Int { read(file).split(separator: "\n").count }
    }

    static func register() {
        registerRouter()
        registerArguments()
        registerFakeEngines()
        registerRealLibreOffice()
    }

    // MARK: Router

    private static func registerRouter() {
        docTest("router: with no optional tool every pair of the eight formats is built-in; Pandoc or LibreOffice are chosen by the documented rules and never override an option only the built-in engine honours",
                proves: ["doc.engine.route"]) {
            let none = DocFakeTools(), lo = DocFakeTools(.soffice), pd = DocFakeTools(.pandoc), both = DocFakeTools(.soffice, .pandoc)
            let formats = ["docx", "doc", "odt", "rtf", "md", "txt", "html", "epub"]
            for a in formats { for b in DocsConformance.targets {
                try expectEqual(DocRouter.route(input: a, target: b, tools: none).route, .native, "\(a) -> \(b) with no tools")
            } }
            func r(_ a: String, _ b: String, _ t: DocToolProbe, changed: Bool = false, engine: String = "auto") -> DocRoute? {
                DocRouter.route(input: a, target: b, engine: engine, nativeOptionsChanged: changed, tools: t).route
            }
            // LibreOffice keeps the layout of word-processor files going to page formats.
            for a in ["docx", "doc", "odt", "rtf"] { for b in ["pdf", "docx", "odt", "rtf"] where a != b {
                try expectEqual(r(a, b, lo), .soffice, "\(a) -> \(b) with LibreOffice")
                try expectEqual(r(a, b, both), .soffice, "\(a) -> \(b) with both")
            } }
            try expectEqual(r("docx", "docx", lo), .native, "same format: the built-in writer applies the options (a re-flow)")
            for b in ["md", "html", "txt", "epub"] { try expectEqual(r("docx", b, lo), .native, "docx -> \(b): LibreOffice's markup is not used") }
            for a in ["md", "txt", "html", "epub"] { try expectEqual(r(a, "pdf", lo), .native, "\(a) -> pdf: LibreOffice cannot read it, or the built-in layout honours the options") }
            try expectEqual(r("txt", "pdf", lo), .native); try expectEqual(r("html", "docx", lo), .native, "web page -> docx stays built-in without Pandoc")
            // The old binary format gets its structure through LibreOffice when available.
            for b in ["md", "html", "txt", "epub"] { try expectEqual(r("doc", b, lo), .sofficeThenNative, "doc -> \(b)") }
            for b in ["md", "html", "txt", "epub"] { try expectEqual(r("doc", b, both), .sofficeThenPandoc, "doc -> \(b) with both") }
            try expectEqual(r("doc", "md", pd), .native, "Pandoc cannot read .doc and there is no LibreOffice")
            // Pandoc for the structural formats.
            for (a, b) in [("docx", "md"), ("md", "docx"), ("html", "epub"), ("epub", "docx"), ("md", "txt"), ("rtf", "md"), ("odt", "html"), ("md", "odt"), ("docx", "txt")] {
                try expectEqual(r(a, b, pd), .pandoc, "\(a) -> \(b) with Pandoc")
                try expectEqual(r(a, b, both), a == "docx" && ["odt", "rtf"].contains(b) ? .soffice : .pandoc, "\(a) -> \(b) with both")
            }
            try expectEqual(r("txt", "docx", pd), .native, "plain text is never given to Pandoc (it would parse it as Markdown)")
            try expectEqual(r("txt", "epub", both), .native)
            try expectEqual(r("docx", "pdf", pd), .native, "Pandoc cannot make a PDF")
            try expectEqual(r("md", "pdf", both), .native, "automatic never chains two tools for a PDF")
            // Options only the built-in writers honour win over the upgrades.
            try expectEqual(r("docx", "pdf", both, changed: true), .native); try expectEqual(r("md", "docx", both, changed: true), .native)
            try expectEqual(r("doc", "md", both, changed: true), .sofficeThenNative)
            let s = { () -> DocSettings in var s = DocSettings(); s.pageSize = "letter"; return s }()
            try expectEqual(s.nativeOnlyChanges(for: "pdf"), [DocKeys.pageSize]); try expect(s.nativeOnlyChanges(for: "md").isEmpty, "paper size means nothing for Markdown")
            var t = DocSettings(); t.encodingOut = "windows-1251"; t.title = "x"
            try expectEqual(Set(t.nativeOnlyChanges(for: "txt")), [DocKeys.encodingOut, DocKeys.title])
            try expect(DocSettings().nativeOnlyChanges(for: "pdf").isEmpty && DocSettings().nativeOnlyChanges(for: "html").isEmpty, "the quick recipe changes nothing")
            // Forced engines.
            for a in formats { for b in DocsConformance.targets where a != b { try expectEqual(r(a, b, both, engine: "native"), .native, "forced built-in \(a) -> \(b)") } }
            try expectEqual(r("docx", "pdf", lo, engine: "soffice"), .soffice); try expectEqual(r("docx", "pdf", both, changed: true, engine: "soffice"), .soffice, "forcing wins over options")
            try expectEqual(r("md", "docx", both, engine: "soffice"), .pandocThenSoffice); try expectEqual(r("md", "pdf", both, engine: "pandoc"), .pandocThenSoffice)
            try expectEqual(r("doc", "md", both, engine: "pandoc"), .sofficeThenPandoc); try expectEqual(r("docx", "md", pd, engine: "pandoc"), .pandoc)
            try expect(r("docx", "epub", lo, engine: "soffice") == nil, "LibreOffice does not write EPUB")
            try expect(r("md", "docx", lo, engine: "soffice") == nil, "LibreOffice cannot read Markdown and there is no Pandoc to prepare it")
            // The reasons are calm, localised and name the tool.
            for (engine, tools, tool) in [("pandoc", none, "Pandoc"), ("soffice", none, "LibreOffice")] as [(String, DocToolProbe, String)] {
                guard case .none(let reason, let missing) = DocRouter.route(input: "docx", target: "md", engine: engine, tools: tools) else { throw TestFailure(message: "expected no route", file: #fileID, line: #line) }
                try expect(reason.en.contains(tool) && reason.ru.contains(tool), "\(engine): the reason names \(tool): \(reason.en)")
                try expect(missing == [tool == "Pandoc" ? .pandoc : .soffice], "\(engine): the missing tool is listed")
            }
            guard case .none(let generic, let m) = DocRouter.noRoute("docx", "md", missing: []) else { throw TestFailure(message: "noRoute", file: #fileID, line: #line) }
            try expectEqual(generic.en, "Converting DOCX to MD needs Pandoc or LibreOffice."); try expectEqual(generic.ru, "Для конвертации DOCX в MD требуется Pandoc или LibreOffice.")
            try expectEqual(m, [.pandoc, .soffice])
            for route in [DocRoute.native, .pandoc, .soffice, .pandocThenSoffice, .sofficeThenPandoc, .sofficeThenNative] {
                try expect(!route.explanation.en.isEmpty && !route.explanation.ru.isEmpty && !route.label.en.isEmpty, "\(route) has its info-line text")
            }
            try expect(DocRoute.native.explanation.en.contains("Page layout") && DocRoute.soffice.explanation.en.contains("do not apply"), "the info line says what each engine keeps and ignores")
        }

        docTest("router: the Studio engine picker shows Pandoc and LibreOffice as options that need the tool, and the info line follows the real route") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let schema = DocSchemas.convert(items: [])
            guard case .picker(let opts)? = schema.field(DocKeys.engine)?.kind else { throw TestFailure(message: "engine picker", file: #fileID, line: #line) }
            try expectEqual(opts.map(\.value), ["auto", "native", "pandoc", "soffice"])
            try expectEqual(opts.first { $0.value == "pandoc" }?.requires ?? [], ["tool.pandoc"])
            try expectEqual(opts.first { $0.value == "soffice" }?.requires ?? [], ["tool.soffice"])
            let op = try DocRun.op("doc.to.pdf")
            let docx = fx.url("a.docx")
            let info = SourceInfo(url: docx, kind: .document)
            let messages = op.validate(options: [DocKeys.format: "pdf", DocKeys.engine: "native"], source: info)
            try expect(messages.contains { $0.id == "doc.route" && $0.text.en.hasPrefix("Engine: Built-in. Built-in engine:") }, "the info line names the built-in engine: \(messages.map(\.text.en))")
            let forced = op.validate(options: [DocKeys.format: "pdf", DocKeys.engine: "soffice", DocKeys.pageSize: "letter", DocKeys.margins: 30], source: info)
            if ToolLocator.shared.has(.soffice) {
                let w = try unwrap(forced.first { $0.id == "doc.ignored" }, "a warning lists what LibreOffice ignores: \(forced.map(\.text.en))")
                try expect(w.text.en.contains("paper size") && w.text.en.contains("margins") && w.text.ru.contains("размер бумаги"), "the warning names the ignored options in both languages")
                try expectEqual(w.severity, .warning)
            }
            let bad = op.validate(options: [DocKeys.format: "md", DocKeys.engine: "pandoc"], source: info)
            if !ToolLocator.shared.has(.pandoc) { try expect(bad.contains { $0.id == "doc.noroute" && $0.severity == .error && $0.text.en.contains("Pandoc") }, "no route is an error that names Pandoc") }
            try expect(op.validate(options: [DocKeys.format: "pdf", DocKeys.font: "No Such Font 9"], source: info).contains { $0.id == "doc.font" }, "an uninstalled font is called out")
        }
    }

    // MARK: Argument lists

    private static func registerArguments() {
        docTest("tool arguments: Pandoc and LibreOffice command lines are exactly what the recipes say (no shell, paths as separate arguments)") {
            let input = URL(fileURLWithPath: "/tmp/in dir/Отчёт one.docx"), out = URL(fileURLWithPath: "/tmp/out/.x.part.md")
            var s = DocSettings(); s.target = "md"
            let v3 = DocPandocVersion("pandoc 3.1.11.1"), v218 = DocPandocVersion("pandoc 2.18")
            try expectEqual(v3, DocPandocVersion(major: 3, minor: 1)); try expect(v3?.hasEmbedResources == true && v3?.hasSplitLevel == true && v218?.hasEmbedResources == false)
            try expect(DocPandocVersion(nil) == nil && DocPandocVersion("no version here") == nil, "unparsable versions are nil")
            let dir = "/tmp/in dir"
            try expectEqual(DocPandoc.arguments(input: input, inputKey: "docx", target: "md", output: out, settings: s, baseName: "Отчёт one", version: v3),
                            [input.path, "-f", "docx", "-t", "gfm", "-o", out.path, "--quiet", "--wrap=none", "--eol=lf", "--resource-path=" + dir])
            s.markdownGFM = false; s.extractMedia = true
            try expectEqual(DocPandoc.arguments(input: input, inputKey: "docx", target: "md", output: out, settings: s, baseName: "b", version: v3, mediaFolder: "b - media"),
                            [input.path, "-f", "docx", "-t", "commonmark", "-o", out.path, "--quiet", "--wrap=none", "--eol=lf", "--extract-media=b - media", "--resource-path=" + dir])
            var h = DocSettings(); h.target = "html"
            try expectEqual(DocPandoc.arguments(input: input, inputKey: "md", target: "html", output: out, settings: h, baseName: "b", version: v3),
                            [input.path, "-f", "gfm", "-t", "html5", "-o", out.path, "--quiet", "--standalone", "--embed-resources", "--metadata", "pagetitle=b", "--eol=lf", "--resource-path=" + dir])
            try expect(DocPandoc.arguments(input: input, inputKey: "md", target: "html", output: out, settings: h, baseName: "b", version: v218).contains("--self-contained"), "older Pandoc: --self-contained")
            h.htmlEmbed = false
            let linked = DocPandoc.arguments(input: input, inputKey: "html", target: "html", output: out, settings: h, baseName: "b", version: v3)
            try expect(linked.contains("--standalone") && !linked.contains("--embed-resources"), "HTML input is always standalone; no embedding without the option")
            var t = DocSettings(); t.target = "txt"; t.wrap = 80; t.eol = "crlf"; t.title = "T"; t.author = "A"; t.language = "lv"
            try expectEqual(DocPandoc.arguments(input: input, inputKey: "docx", target: "txt", output: out, settings: t, baseName: "b", version: v3),
                            [input.path, "-f", "docx", "-t", "plain", "-o", out.path, "--quiet", "--metadata", "title=T", "--metadata", "author=A", "--metadata", "lang=lv", "--wrap=auto", "--columns=80", "--eol=crlf", "--resource-path=" + dir])
            var e = DocSettings(); e.target = "epub"; e.epubSplit = 2; e.epubCover = "/tmp/c.png"
            let epub = DocPandoc.arguments(input: input, inputKey: "md", target: "epub", output: out, settings: e, baseName: "b", version: v3)
            try expect(epub.contains("-t") && epub.contains("epub3") && epub.contains("--epub-cover-image=/tmp/c.png") && epub.contains("--split-level=2") && epub.contains("--standalone"), "epub flags: \(epub)")
            try expect(!DocPandoc.arguments(input: input, inputKey: "md", target: "epub", output: out, settings: e, baseName: "b", version: v218).contains { $0.hasPrefix("--split-level") }, "no --split-level before Pandoc 3")
            try expect(DocPandoc.arguments(input: input, inputKey: "md", target: "epub", output: out, settings: e, baseName: "b", version: DocPandocVersion("pandoc 3.12.1")).contains("--epub-title-page=false")
                       && !epub.contains("--epub-title-page=false"), "no generated EPUB title page from Pandoc 3.2 on")
            let filtered = DocPandoc.arguments(input: input, inputKey: "docx", target: "md", output: out, settings: s, baseName: "b", version: v3, filter: "/tmp/f.lua")
            try expectEqual(filtered.suffix(2).map { $0 }, ["--lua-filter=/tmp/f.lua", "--resource-path=" + dir])
            try expect(DocPandoc.filterNeeds(target: "md", settings: DocSettings()) == (false, true) && DocPandoc.filterNeeds(target: "epub", settings: DocSettings()) == (true, false),
                       "the source title stays out of the body except for EPUB; only Markdown promotes a header row")
            try expect(DocPandoc.filterSource(keepTitle: false, promoteHeader: true).contains("local keep_title = false"), "the filter is plain Lua with the two switches")
            // LibreOffice.
            let profile = URL(fileURLWithPath: "/tmp/prof dir/lo-profile", isDirectory: true)
            try expectEqual(DocOffice.arguments(input: input, convertTo: DocOffice.convertTo("pdf"), outputDirectory: URL(fileURLWithPath: "/tmp/o"), profile: profile),
                            ["-env:UserInstallation=file:///tmp/prof%20dir/lo-profile/", "--headless", "--norestore", "--nolockcheck", "--nodefault", "--convert-to", "pdf", "--outdir", "/tmp/o", input.path])
            try expectEqual(DocOffice.arguments(input: input, convertTo: "pptx", outputDirectory: URL(fileURLWithPath: "/tmp/o"), profile: profile, infilter: "impress_pdf_import").suffix(6).map { $0 },
                            ["--infilter=impress_pdf_import", "--convert-to", "pptx", "--outdir", "/tmp/o", input.path].suffix(6).map { $0 })
            try expectEqual(["docx", "pptx", "xlsx", "txt", "pdf", "odt", "rtf", "html", "odp"].map(DocOffice.convertTo),
                            ["docx:MS Word 2007 XML", "pptx:Impress MS PowerPoint 2007 XML", "xlsx:Calc MS Excel 2007 XML", "txt:Text", "pdf", "odt", "rtf", "html", "odp"])
            try expectEqual(DocPageRange.indices("1-3, 5", count: 10) ?? [], [0, 1, 2, 4]); try expectEqual(DocPageRange.indices("8-", count: 10) ?? [], [7, 8, 9])
            try expectEqual(DocPageRange.indices("all", count: 3) ?? [], [0, 1, 2]); try expectEqual(DocPageRange.indices("", count: 2) ?? [], [0, 1])
            try expect(DocPageRange.indices("3-1", count: 5) == nil && DocPageRange.indices("x", count: 5) == nil && DocPageRange.indices("0", count: 5) == nil && DocPageRange.indices("1-x", count: 5) == nil, "malformed ranges are rejected")
            try expectEqual(DocPageRange.indices("7", count: 5) ?? [9], [], "a range past the end selects nothing")
        }
    }

    // MARK: Fake engines

    private static func registerFakeEngines() {
        docTest("fake Pandoc: a forced or chosen Pandoc route runs it with the golden arguments and moves its output into place; cleans up after itself", proves: ["doc.engine.route"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let tools = try FakeTools(fx)
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx), name: "Отчёт.docx")
            let md = try await DocRun.convert(docx, to: "md", [DocKeys.engine: "pandoc"], into: out, tools: tools.locator, pinNative: false)
            try expectEqual(try String(contentsOf: md, encoding: .utf8), "FAKE-PANDOC-OUTPUT\n")
            try expectEqual(md.lastPathComponent, "Отчёт.md")
            let args = tools.read("pandoc.last").split(separator: "\n").map(String.init)
            try expectEqual(args.first, docx.path); try expect(args.contains("gfm") && args.contains("--quiet") && args.contains("-o"), "arguments: \(args)")
            try expect(args.contains("--resource-path=" + docx.deletingLastPathComponent().path), "resource path is the source folder")
            try expectEqual(args[args.firstIndex(of: "-o")! + 1].hasPrefix(out.path + "/."), true, "Pandoc wrote into the hidden in-flight file next to the final name")
            try expect(TestFile.partials(in: out).isEmpty, "no in-flight file is left")
            // Automatic with Pandoc present and nothing changed: the same route without forcing it.
            let auto = try await DocRun.convert(docx, to: "html", into: out, tools: tools.locator, pinNative: false)
            try expectEqual(try String(contentsOf: auto, encoding: .utf8), "FAKE-PANDOC-OUTPUT\n", "auto picks Pandoc for docx -> html")
            // An option only the built-in engine honours moves the run back to the built-in engine.
            let native = try await DocRun.convert(docx, to: "html", [DocKeys.encodingOut: "windows-1251"], into: out, tools: tools.locator, pinNative: false)
            try expect(try String(contentsOf: native, encoding: .isoLatin1).hasPrefix("<!DOCTYPE html>"), "encoding choice keeps the run built-in")
            try expectEqual(tools.calls("pandoc.calls"), 2, "Pandoc ran twice, not three times")
        }

        docTest("fake LibreOffice: the private profile, the single-instance gate and the argument list; a deck or document comes out through it", proves: ["doc.engine.route"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let tools = try FakeTools(fx)
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx), name: "letter.docx")
            let pdf = try await DocRun.convert(docx, to: "pdf", into: out, tools: tools.locator, pinNative: false)
            try expectEqual(try String(contentsOf: pdf, encoding: .utf8), "FAKE-LIBREOFFICE-OUTPUT\n")
            let args = tools.read("soffice.last").split(separator: "\n").map(String.init)
            try expect(args[0].hasPrefix("-env:UserInstallation=file://") && args[0].hasSuffix("/lo-profile/"), "private profile: \(args[0])")
            try expectEqual(Array(args[1...7]), ["--headless", "--norestore", "--nolockcheck", "--nodefault", "--convert-to", "pdf", "--outdir"])
            try expectEqual(args.last, docx.path)
            try expect(args[0].contains(AppPaths.supportDir.lastPathComponent) || args[0].contains("Swamp"), "the profile lives in our support folder, not in the person's LibreOffice profile")
            // doc -> md: LibreOffice makes a docx, the built-in engine writes the Markdown. Feed it a real docx.
            let payload = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx), name: "payload.docx")
            try FileManager.default.copyItem(at: payload, to: tools.dir.appendingPathComponent("payload.docx"))
            let legacy = try await DocFixtures.makeInput("doc", in: fx, model: DocFixtures.sample(fx), name: "old.doc")
            // An option only the built-in writers honour (front matter) keeps the second half built-in even though Pandoc is present.
            let md = try await DocRun.convert(legacy, to: "md", [DocKeys.mdFrontMatter: true], into: out, tools: tools.locator, pinNative: false)
            let text = try String(contentsOf: md, encoding: .utf8)
            try expect(text.contains("## Introduction") && text.contains("- first item") && text.contains("| Žluťák |"), "headings, lists and tables survive because LibreOffice's docx is read by the built-in engine: \(text.prefix(200))")
            try expect(tools.read("soffice.last").contains("docx:MS Word 2007 XML"), "the intermediate is a docx")
        }

        docTest("fake LibreOffice: a run that produces nothing is retried once with a fresh profile and then fails with the calm message; a hung run is stopped by the watchdog") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let tools = try FakeTools(fx)
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx), name: "broken.docx")
            try tools.setMode("fail")
            let err = try await expectThrows("a LibreOffice that writes nothing is an error") { _ = try await DocRun.convert(docx, to: "pdf", into: out, tools: tools.locator, pinNative: false) }
            let message = ConversionError.describe(err)
            try expect(message.contains("LibreOffice could not convert the file") || message.contains("LibreOffice не удалось"), "calm message: \(message)")
            try expectEqual(tools.calls("soffice.calls"), 2, "tried twice: the second time with a new profile")
            try expect(TestFile.partials(in: out).isEmpty && (try FileManager.default.contentsOfDirectory(atPath: out.path)).isEmpty, "nothing left behind")
            // Watchdog.
            let saved = DocOffice.timeoutSeconds
            DocOffice.timeoutSeconds = 1.0
            defer { DocOffice.timeoutSeconds = saved }
            try tools.setMode("hang")
            let t0 = Date()
            let err2 = try await expectThrows("a hung LibreOffice is stopped") { _ = try await DocRun.convert(docx, to: "pdf", into: out, tools: tools.locator, pinNative: false) }
            try expect(ConversionError.describe(err2).contains("did not finish in time") || ConversionError.describe(err2).contains("не завершил"), "message: \(ConversionError.describe(err2))")
            try expect(Date().timeIntervalSince(t0) < 8, "the watchdog stopped it after about a second (\(Date().timeIntervalSince(t0)) s)")
            try await Task.sleep(nanoseconds: 2_500_000_000)       // the process tree gets SIGTERM, then SIGKILL after 2 s
            for pidFile in ["soffice.pid", "child.pid"] {
                if let pid = Int32(tools.read(pidFile).trimmingCharacters(in: .whitespacesAndNewlines)) { try expect(kill(pid, 0) != 0, "\(pidFile) \(pid) is gone") }
            }
        }

        docTest("cancelling a LibreOffice run stops the whole process tree within moments, leaves no .part file, and frees the single-instance gate", timeout: 60) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let tools = try FakeTools(fx)
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx), name: "slow.docx")
            try tools.setMode("hang")
            let op = try DocRun.op("doc.to.pdf")
            let items = FileItem.items([docx])
            let ctx = DocRun.context(op, items, extra: [DocKeys.engine: "soffice"], mode: .studio, rules: DocRun.into(out), tools: tools.locator, pinNative: false)
            let task = Task { try await op.execute(items: items, ctx: ctx) }
            var pid: Int32?
            for _ in 0..<100 {
                if let p = Int32(tools.read("soffice.pid").trimmingCharacters(in: .whitespacesAndNewlines)), Int32(tools.read("child.pid").trimmingCharacters(in: .whitespacesAndNewlines)) != nil { pid = p; break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let running = try unwrap(pid, "the fake LibreOffice started")
            let child = try unwrap(Int32(tools.read("child.pid").trimmingCharacters(in: .whitespacesAndNewlines)))
            try expect(DocOffice.gate.isBusy, "the gate is held while LibreOffice runs")
            let t0 = Date()
            task.cancel()
            let result = await task.result
            if case .success = result { throw TestFailure(message: "a cancelled run must not succeed", file: #fileID, line: #line) }
            if case .failure(let e) = result { try expect(e is CancellationError, "cancellation propagates as CancellationError, not \(e)") }
            try expect(Date().timeIntervalSince(t0) < 1.5, "cancel is effective quickly (\(Date().timeIntervalSince(t0)) s)")
            try await Task.sleep(nanoseconds: 2_600_000_000)
            try expect(kill(running, 0) != 0 && kill(child, 0) != 0, "both the script and its child process are gone")
            ctx.cleanupTemp()
            try expect((try FileManager.default.contentsOfDirectory(atPath: out.path)).isEmpty, "no output and no .part file in the output folder")
            try expect(!DocOffice.gate.isBusy, "the gate was released")
            try tools.setMode("ok")
            let again = try await DocRun.convert(docx, to: "pdf", [DocKeys.engine: "soffice"], into: out, tools: tools.locator, pinNative: false)
            try expect(FileManager.default.fileExists(atPath: again.path), "the next run works")
        }

        docTest("two LibreOffice runs never overlap: the second waits for the first, and a waiting run can be cancelled", timeout: 60) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let tools = try FakeTools(fx)
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx), name: "queue.docx")
            try tools.setMode("hang")
            let op = try DocRun.op("doc.to.pdf")
            let items = FileItem.items([docx])
            let c1 = DocRun.context(op, items, extra: [DocKeys.engine: "soffice"], mode: .studio, rules: DocRun.into(out), tools: tools.locator, pinNative: false)
            let c2 = DocRun.context(op, items, extra: [DocKeys.engine: "soffice"], mode: .studio, rules: DocRun.into(out), tools: tools.locator, pinNative: false)
            let first = Task { try await op.execute(items: items, ctx: c1) }
            for _ in 0..<100 { if !tools.read("soffice.pid").isEmpty { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            let second = Task { try await op.execute(items: items, ctx: c2) }
            try await Task.sleep(nanoseconds: 700_000_000)
            try expectEqual(tools.calls("soffice.calls"), 1, "the second run is waiting, not running")
            second.cancel()
            let r2 = await second.result
            if case .failure(let e) = r2 { try expect(e is CancellationError, "a waiting run leaves the queue with CancellationError") } else { throw TestFailure(message: "the waiting run should have been cancelled", file: #fileID, line: #line) }
            first.cancel(); _ = await first.result
            try await Task.sleep(nanoseconds: 2_600_000_000)
            c1.cleanupTemp(); c2.cleanupTemp()
            try expect(!DocOffice.gate.isBusy, "gate free")
        }
    }

    // MARK: Real LibreOffice

    /// A two-slide ODP written by hand (mimetype first and stored). Page 1 and 2 carry known words; the slide master has no background fill.
    static func odp(_ fx: TestFixtures, name: String = "deck.odp", slides: Int = 3) throws -> URL {
        let ns = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:presentation=\"urn:oasis:names:tc:opendocument:xmlns:presentation:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\""
        var pages = ""
        for i in 1...slides {
            pages += "<draw:page draw:name=\"page\(i)\" draw:style-name=\"dp1\" draw:master-page-name=\"Default\"><draw:frame draw:style-name=\"gr1\" draw:name=\"t\(i)\" svg:x=\"1.5cm\" svg:y=\"1.5cm\" svg:width=\"24cm\" svg:height=\"3cm\"><draw:text-box><text:p>Slide \(i) of the swamp deck: Привет \(i)</text:p></draw:text-box></draw:frame></draw:page>"
        }
        let content = DocXML.declaration + "<office:document-content \(ns) office:version=\"1.2\"><office:automatic-styles><style:style style:name=\"dp1\" style:family=\"drawing-page\"><style:drawing-page-properties presentation:background-visible=\"true\" presentation:background-objects-visible=\"true\" draw:fill=\"none\"/></style:style><style:style style:name=\"gr1\" style:family=\"graphic\"><style:graphic-properties draw:stroke=\"none\" draw:fill=\"none\"/></style:style></office:automatic-styles><office:body><office:presentation>\(pages)</office:presentation></office:body></office:document-content>"
        let styles = DocXML.declaration + "<office:document-styles \(ns) office:version=\"1.2\"><office:automatic-styles><style:page-layout style:name=\"PM1\"><style:page-layout-properties fo:margin-top=\"0cm\" fo:margin-bottom=\"0cm\" fo:margin-left=\"0cm\" fo:margin-right=\"0cm\" fo:page-width=\"28cm\" fo:page-height=\"15.75cm\" style:print-orientation=\"landscape\"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name=\"Default\" style:page-layout-name=\"PM1\"/></office:master-styles></office:document-styles>"
        let manifest = DocXML.declaration + "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.2\" manifest:media-type=\"application/vnd.oasis.opendocument.presentation\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"styles.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"
        let url = fx.url(name)
        try DocPackage.write([.init(name: "mimetype", data: Data("application/vnd.oasis.opendocument.presentation".utf8), stored: true), .init(name: "META-INF/manifest.xml", data: Data(manifest.utf8)),
                              .init(name: "content.xml", data: Data(content.utf8)), .init(name: "styles.xml", data: Data(styles.utf8))], to: url)
        return url
    }

    private static func registerRealLibreOffice() {
        docTest("LibreOffice for real: a Word file becomes a PDF with its text and page count, and the legacy .doc becomes a DOCX", requires: ["tool.soffice"], timeout: 180) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let docx = try await DocFixtures.makeInput("docx", in: fx, model: DocFixtures.sample(fx, long: true), name: "real.docx")
            var log: [String] = []
            let r = try await DocRun.run("doc.to.pdf", [docx], [DocKeys.format: "pdf"], mode: .studio, rules: DocRun.into(out), tools: .shared, pinNative: false, log: { log.append($0) })
            let pdf = try unwrap(r.outputs.first)
            try expect(log.contains { $0.contains("Document engine: LibreOffice") }, "the route was LibreOffice: \(log.prefix(3))")
            let doc = try unwrap(PDFDocument(url: pdf))
            try expect(doc.pageCount >= 3, "a long document has pages: \(doc.pageCount)")
            try expect(DocOracle.firstMissing(["Introduction", "Paragraph 12", "The end of the swamp report."], in: doc.string ?? "") == nil, "LibreOffice's PDF holds the text")
            try expect(doc.string?.contains("Болотный отчёт") == true, "Cyrillic survives")
            let legacy = try await DocFixtures.makeInput("doc", in: fx, model: DocFixtures.sample(fx), name: "legacy.doc")
            let up = try await DocRun.run("doc.to.docx", [legacy], [DocKeys.format: "docx"], mode: .studio, rules: DocRun.into(out), tools: .shared, pinNative: false)
            let converted = try unwrap(up.outputs.first)
            try expectEqual(DocOracle.mime(converted), "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
            try expect(DocOracle.firstMissing(["Introduction", "first item", "step two", "The end of the swamp report."], in: DocOracle.text(of: converted)) == nil, "text of the .doc survives LibreOffice")
            let back = try await DocNative.read(converted, key: "docx", settings: DocSettings(), ctx: nil)
            let found = DocsConformance.outline(of: back.blocks)
            try expect(found.contains { $0.hasPrefix("h2 Introduction") } && found.contains { $0.hasPrefix("h1 Болотный") }, "our reader finds the headings in LibreOffice's docx (large bold lines): \(found.prefix(6))")
            // Third-party files in both directions.
            let odt = try await DocRun.run("doc.to.odt", [docx], [DocKeys.format: "odt"], mode: .studio, rules: DocRun.into(out), tools: .shared, pinNative: false)
            let fromLO = try await DocNative.read(try unwrap(odt.outputs.first), key: "odt", settings: DocSettings(), ctx: nil)
            try expect(DocsConformance.outline(of: fromLO.blocks).contains { $0.hasPrefix("h1 Болотный отчёт") } && fromLO.plainText.contains("Žluťák"), "our ODT reader understands LibreOffice's ODT: \(DocsConformance.outline(of: fromLO.blocks).prefix(5))")
        }

        docTest("slides.convert for real: PDF with a slide range, PNG and JPG pictures at the chosen resolution and quality, and PPTX / ODP decks", requires: ["tool.soffice"], timeout: 300) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let out = try fx.makeDirectory("out")
            let deck = try odp(fx)
            // PDF: all slides, then a range.
            let all = try unwrap(try await DocRun.run("slides.to.pdf", [deck], mode: .studio, rules: DocRun.into(out), tools: .shared).outputs.first)
            let allDoc = try unwrap(PDFDocument(url: all))
            try expectEqual(allDoc.pageCount, 3, "three slides, three pages")
            try expect(DocOracle.firstMissing(["Slide 1 of the swamp deck", "Slide 2", "Slide 3"], in: allDoc.string ?? "") == nil, "slide text: \(allDoc.string ?? "")")
            try expectClose(Double(allDoc.page(at: 0)?.bounds(for: .mediaBox).width ?? 0), 28 / 2.54 * 72, tolerance: 2, "slide width is the deck's 28 cm")
            let range = try unwrap(try await DocRun.run("slides.to.pdf", [deck], [DocKeys.slideRange: "2-3"], mode: .studio, rules: DocRun.into(out), tools: .shared).outputs.first)
            let rangeDoc = try unwrap(PDFDocument(url: range))
            try expectEqual(rangeDoc.pageCount, 2); try expect(rangeDoc.string?.contains("Slide 2") == true && rangeDoc.string?.contains("Slide 1 of") == false, "only slides 2 and 3")
            // PNG: several slides -> folder "name (pages)" with numbered files; one slide -> a file.
            let pngs = try unwrap(try await DocRun.run("slides.to.png", [deck], [DocKeys.slideDPI: 100], mode: .studio, rules: DocRun.into(out), tools: .shared).outputs.first)
            var isDir: ObjCBool = false
            try expect(FileManager.default.fileExists(atPath: pngs.path, isDirectory: &isDir) && isDir.boolValue && pngs.lastPathComponent == "deck (pages)", "a folder: \(pngs.lastPathComponent)")
            let files = try FileManager.default.contentsOfDirectory(atPath: pngs.path).sorted()
            try expectEqual(files, ["deck - 1.png", "deck - 2.png", "deck - 3.png"])
            let s100 = try unwrap(TestImage.size(of: pngs.appendingPathComponent(files[0])))
            try expectClose(Double(s100.width), 28 / 2.54 * 100, tolerance: 3, "100 dpi: the width in pixels")
            let single = try unwrap(try await DocRun.run("slides.to.png", [deck], [DocKeys.slideDPI: 200, DocKeys.slideRange: "2"], mode: .studio, rules: DocRun.into(out), tools: .shared).outputs.first)
            let s200 = try unwrap(TestImage.size(of: single))
            try expectClose(Double(s200.width), 28 / 2.54 * 200, tolerance: 4, "200 dpi: twice the pixels")
            try expectEqual(TestImage.info(of: single)?.type, "public.png")
            // JPG: quality is monotonic in the bytes.
            func jpg(_ q: Int) async throws -> URL { try unwrap(try await DocRun.run("slides.to.jpg", [deck], [DocKeys.slideDPI: 150, DocKeys.slideFormatQuality: .int(q), DocKeys.slideRange: "1"], mode: .studio, rules: DocRun.into(out), tools: .shared).outputs.first) }
            let low = try await jpg(55), high = try await jpg(95)
            try expectEqual(TestImage.info(of: low)?.type, "public.jpeg")
            try expect(TestFile.size(high) > TestFile.size(low), "higher JPG quality, bigger file: \(TestFile.size(low)) < \(TestFile.size(high))")
            // Decks.
            let pptx = try unwrap(try await DocRun.run("slides.to.pptx", [deck], mode: .studio, rules: DocRun.into(out), tools: .shared).outputs.first)
            try expectEqual(DocOracle.mime(pptx), "application/vnd.openxmlformats-officedocument.presentationml.presentation")
            try expectEqual(DocOracle.zipNames(pptx).filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }.count, 3, "three slides in the PPTX")
            let backToPDF = try unwrap(try await DocRun.run("slides.to.pdf", [pptx], mode: .studio, rules: DocRun.into(out), tools: .shared).outputs.first)
            try expectEqual(PDFDocument(url: backToPDF)?.pageCount, 3, "the PPTX LibreOffice wrote opens again with three slides")
            let odpOut = try unwrap(try await DocRun.run("slides.to.odp", [try odp(fx, name: "second.odp")], mode: .studio, rules: DocRun.into(out), tools: .shared).outputs.first)
            try expectEqual(DocOracle.zipPart(odpOut, "mimetype"), "application/vnd.oasis.opendocument.presentation")
            try expect(TestFile.partials(in: out).isEmpty, "no in-flight files")
        }

        docTest("slides option mapping: dpi, JPG quality and background reach the renderer; the slide range is validated", proves: ["slides.format.sniff", "slides.range", "slides.dpi", "slides.quality", "slides.background"]) {
            let r = DocSlides.rasterOptions([DocKeys.slideDPI: 144, DocKeys.slideFormatQuality: 73, DocKeys.slideBackground: "#FF8000"], target: "jpg", pages: [1, 2])
            try expectEqual(r.dpi, 144); try expectEqual(r.quality, 73); try expectEqual(r.format, "jpeg"); try expectEqual(r.background, RGBA(r: 255, g: 128, b: 0)); try expectEqual(r.pages ?? [], [1, 2])
            try expectEqual(DocSlides.rasterOptions([DocKeys.slideDPI: 9999], target: "png", pages: nil).dpi, 600, "clamped to the schema's range")
            try expectEqual(DocSlides.rasterOptions([:], target: "png", pages: nil).background, .white)
            try expectEqual(DocSlides.rasterOptions([DocKeys.slideBackground: "not a colour"], target: "png", pages: nil).background, .white, "a bad colour falls back to white")
            // The renderer honours the background behind transparent areas (shared with the PDF module); proven here on a PDF with a transparent page.
            let fx = TestFixtures(); defer { fx.cleanup() }
            let blank = fx.url("blank.pdf")
            var box = CGRect(x: 0, y: 0, width: 200, height: 100)
            let ctx = try unwrap(CGContext(blank as CFURL, mediaBox: &box, nil)); ctx.beginPDFPage(nil); ctx.setFillColor(RGBA.blue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20)); ctx.endPDFPage(); ctx.closePDF()
            let img = try PdfRasterizer.renderPage(pdf: blank, pageIndex: 0, dpi: 72, background: try unwrap(DocColor.rgba("#FF8000")))
            let px = PdfRaster.pixel(img, 150, 30)
            try expect(TestImage.close(px, RGBA(r: 255, g: 128, b: 0), tolerance: 6), "the background colour shows through: \(px)")
            let ctx2 = DocRun.context(try DocRun.op("slides.to.png"), [], extra: [DocKeys.slideRange: "x-y"], mode: .studio)
            _ = ctx2
            let op = try DocRun.op("slides.to.pdf")
            let msgs = op.validate(options: [DocKeys.slideRange: "3-1"], source: nil)
            try expect(msgs.contains { $0.severity == .error && $0.fieldKey == DocKeys.slideRange }, "a bad range is an error on the field")
            try expect(op.validate(options: [DocKeys.slideRange: "1-3, 5"], source: nil).isEmpty && op.validate(options: [DocKeys.slideRange: ""], source: nil).isEmpty, "good ranges validate")
        }
    }
}

/// Pixel access for the background test.
enum PdfRaster {
    static func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> RGBA {
        var px = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: -CGFloat(x), y: -CGFloat(img.height - 1 - y))
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return RGBA(r: px[0], g: px[1], b: px[2], a: px[3])
    }
}
