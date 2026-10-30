import Foundation

// One download job, start to finish: info -> format choice -> disk check -> yt-dlp -> (convert) -> files in the output folder.
// `DownloadLinkOperation.executeLinks` is a thin wrapper around `DownloadRunner.run`.
//
// Stages: "download" (weight 0.6), "convert" (0.4; skipped for keep-original and audio). Several links download one after the other, then convert.
// Cancel: yt-dlp is killed with its process tree (Core), the partial files (.part, .ytdl, fragments) are removed with the hidden work area,
// finished files are rescued into the output folder. A failed download keeps its partials so the next try resumes.

struct DownloadedItem: Sendable {
    var link: LinkItem
    var info: DownloadInfo?
    var area: DownloadWorkArea
    var outputDirectory: URL
    var files: [URL]
    var warnings: [String]
}

/// Work areas touched by a run, for the cancel / failure clean-up. Reference type: the run's error handlers see what the loop created.
final class DownloadRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _areas: [DownloadWorkArea] = []
    private var _dirs: [URL] = []
    var areas: [DownloadWorkArea] { lock.lock(); defer { lock.unlock() }; return _areas }
    private var writing: [URL] = []
    /// Registers a work area and marks its output folder as "being written by us" (watched folders ignore what appears there).
    func add(_ a: DownloadWorkArea, outputDirectory: URL) {
        lock.lock(); _areas.append(a); _dirs.append(outputDirectory); writing.append(outputDirectory); lock.unlock()
        OwnOutputs.shared.beginWriting(to: outputDirectory)
    }
    func endWriting() {
        lock.lock(); let dirs = writing; writing = []; lock.unlock()
        dirs.forEach { OwnOutputs.shared.endWriting(to: $0) }
    }
    func directory(of a: DownloadWorkArea) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return _areas.firstIndex(where: { $0.root == a.root }).map { _dirs[$0] }
    }
    func forget(_ a: DownloadWorkArea) { lock.lock(); if let i = _areas.firstIndex(where: { $0.root == a.root }) { _areas.remove(at: i); _dirs.remove(at: i) }; lock.unlock() }
}

struct DownloadRunner {
    let ctx: OperationContext
    var tools: ToolLocator { ctx.tools }

    func run(links: [LinkItem]) async throws -> OperationResult {
        let opts = ctx.options
        let mode = DownloadMode(rawValue: opts.string(DownloadKeys.mode)) ?? .bestForApple
        let after = DownloadOptionsMapper.effectiveAfter(opts)
        let burn = !mode.isAudioOnly && ctx.isActive(DownloadKeys.subtitles) && opts.string(DownloadKeys.subtitles) == "burn"
        let converts = !mode.isAudioOnly && (after != .keepOriginal || burn)
        let state = DownloadRunState()
        defer { state.endWriting() }
        var result = OperationResult()
        var downloaded: [DownloadedItem] = []

        ctx.beginStage("download")
        do {
            for (i, link) in links.enumerated() {
                try ctx.checkCancelled()
                try await ctx.waitIfPaused()
                do {
                    downloaded.append(try await download(link, index: i, count: links.count, state: state))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if links.count == 1 { throw error }
                    result.failures.append("\(link.displayTitle): \(ConversionError.describe(error))")
                    ctx.log("FAILED \(link.displayTitle): \(ConversionError.describe(error))")
                }
            }
            guard !downloaded.isEmpty else { throw ConversionError.aggregate(result.failures) }
            ctx.finishStage("download")
            if converts { ctx.beginStage("convert") } else { ctx.skipStage("convert") }
            for d in downloaded {
                try ctx.checkCancelled()
                let r = try await finalize(d, after: after, burn: burn, converts: converts, state: state)
                result.outputs += r.outputs
                result.warnings += r.warnings
            }
            ctx.report(1)
            if !result.warnings.isEmpty { result.note = L10n(result.warnings.joined(separator: " "), result.warnings.joined(separator: " ")) }
            return result
        } catch is CancellationError {
            // Finished files are kept, partials and the work areas go. Runs detached so the cancelled task can still do file work.
            let salvaged = await Task.detached { Self.salvage(state) }.value
            if !salvaged.isEmpty { ctx.log("Cancelled; kept the finished files: \(salvaged.map(\.lastPathComponent).joined(separator: ", "))") }
            throw CancellationError()
        } catch {
            // A failed run keeps its partials for the next try, an area with nothing in it goes away.
            for a in state.areas { a.removeIfEmpty() }
            throw error
        }
    }

    private static func salvage(_ state: DownloadRunState) -> [URL] {
        var placed: [URL] = []
        for a in state.areas {
            guard let dir = state.directory(of: a) else { a.remove(); continue }
            placed += DownloadPlacer.salvage(a, into: dir)
        }
        return placed
    }

    // MARK: Download

    private func download(_ link: LinkItem, index: Int, count: Int, state: DownloadRunState) async throws -> DownloadedItem {
        if let r = LinkParsing.rejection(for: link.url) { throw ConversionError.message(r.message) }
        let ytdlp = try tools.require(.ytdlp)
        let settings = ctx.settings
        var request = DownloadOptionsMapper.request(from: ctx.options, url: link.url, settings: settings, active: { ctx.isActive($0) })
        let outDir = request.outputDirectory
        do { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) } catch { throw ConversionError.outputNotWritable(outDir) }
        guard FileManager.default.isWritableFile(atPath: outDir.path) else { throw ConversionError.outputNotWritable(outDir) }
        DownloadWorkArea.cleanStale(in: outDir)

        let jsRuntime = JSRuntimeDetector.detect(tools: tools)
        var supportsJS = await Self.supportsJSRuntimes(ytdlp: ytdlp, tools: tools)
        let runner: DownloadProcessRunner = { exe, args in try await ctx.runProcess(exe, args, captureStdout: true, allowNonZeroExit: true) }

        // 1. Information (also the size for the disk check and the title for the job card).
        try NetworkGate.authorize(.mediaInfo, host: link.host)
        let wantsList = request.playlistItems != nil
        var query = DownloadInfoFetcher.Query(url: link.url, flat: true, wholePlaylist: wantsList, cookies: request.cookies, jsRuntime: jsRuntime, supportsJSRuntimes: supportsJS)
        ctx.report(nil, message: L("Contacting the site…", "Связь с сайтом…"))
        var info: DownloadInfo?
        do {
            info = try await DownloadInfoFetcher.fetch(query, executable: ytdlp, run: runner)
        } catch let e as ConversionError {
            if case .message(let m) = e, m.en.contains("too old for the app"), supportsJS {
                supportsJS = false; query.supportsJSRuntimes = false     // an older yt-dlp without --js-runtimes: retry without it
                info = try await DownloadInfoFetcher.fetch(query, executable: ytdlp, run: runner)
            } else { throw e }
        }
        if let info {
            DownloadJobTitle.set(info.title, jobID: ctx.jobID)
            ctx.log("Title: \(info.title)" + (info.channel.map { " (\($0))" } ?? ""))
            if info.isLive {
                throw ConversionError.message(L10n("This is a live stream that is still running. Try again after it has ended.", "Это прямая трансляция, она ещё идёт. Повторите после её окончания."))
            }
            if info.isPlaylist {
                if info.entries.isEmpty { throw ConversionError.message(L10n("The list is empty, or none of its videos can be opened. If this is a site’s home page or a feed, open the video itself and try again.", "Список пуст, либо ни одно из его видео не открывается. Если это главная страница сайта или лента, откройте само видео и попробуйте снова.")) }
                if request.playlistItems == nil {
                    throw ConversionError.message(L10n("This link is a list of \(info.entries.count) videos. Open the Studio to choose which ones to download, or set the list option to download them all.",
                                                       "Эта ссылка — список из \(info.entries.count) видео. Откройте Студию, чтобы выбрать нужные, или включите загрузку всего списка."))
                }
            }
        }

        // 2. Formats: explicit ids from the page when it is a single video.
        var choice: FormatChoice?
        if let info, !info.isPlaylist {
            choice = FormatSelector.choose(info: info, mode: request.mode, maxHeight: request.maxHeight)
            request.formatSelector = choice?.selector
        }

        // Without ffmpeg nothing can be joined or embedded: one-file formats, no embedding, no soft subtitles.
        if tools.url(.ffmpeg) == nil {
            if !request.mode.isAudioOnly { request.formatSelector = FormatSelector.singleFileSelector(info: info.flatMap { $0.isPlaylist ? nil : $0 }, maxHeight: request.maxHeight) }
            request.embedMetadata = false; request.embedThumbnail = false
            if request.subtitles == .soft || request.subtitles == .burn { request.subtitles = .external }
            ctx.log("WARNING: ffmpeg is not installed; video and sound are not joined and nothing is embedded (brew install ffmpeg).")
        }

        // 3. Room on the disk (the real size is known now): the work area, the finished file and the converted copy share the volume.
        if settings.freeSpaceGuard, let bytes = choice?.estimatedBytes, bytes > 0 {
            let verdict = DiskSpaceGuard.check(estimatedOutput: bytes, tempBytes: bytes, outputDir: outDir)
            if verdict.level == .insufficient { throw ConversionError.message(verdict.message ?? L10n("Not enough free space.", "Недостаточно места.")) }
            if let m = verdict.message { ctx.log("WARNING: " + m.en) }
        }

        // 4. yt-dlp
        let key = [LinkParsing.canonicalKey(of: link.url), request.formatSelector ?? "-", request.mode.rawValue, String(request.maxHeight ?? 0),
                   request.sectionStart.map { String($0) } ?? "-", request.sectionEnd.map { String($0) } ?? "-", request.playlistItems ?? "-",
                   request.subtitles.rawValue].joined(separator: "|")
        let area = DownloadWorkArea.make(in: outDir, key: key)
        try area.create()
        state.add(area, outputDirectory: outDir)
        let listFile = ctx.tempDir.appendingPathComponent("results-\(index).txt")
        try? FileManager.default.removeItem(at: listFile)
        var ytRequest = request
        ytRequest.outputDirectory = area.out
        ytRequest.workDirectory = area.tmp
        ytRequest.resultListFile = listFile
        let ffmpegDir = tools.url(.ffmpeg)?.deletingLastPathComponent()
        let args = try YtDlpArguments.downloadArguments(ytRequest, ffmpegDirectory: ffmpegDir, jsRuntime: jsRuntime, supportsJSRuntimes: supportsJS)

        let parts = Self.partWeights(choice: choice, mode: request.mode, selector: request.formatSelector)
        let items = request.playlistItems.map { $0.isEmpty ? (info?.entries.count ?? 1) : (DownloadOptionsMapper.itemCount(of: $0) ?? info?.entries.count ?? 1) } ?? 1
        let sink = DownloadProgressSink(parts: parts, items: items)
        let context = ctx
        try NetworkGate.authorize(.mediaDownload, host: link.host)
        let out = try await ctx.runProcess(ytdlp, args, onStdoutLine: { line in
            if let u = sink.feed(line: line) {
                context.report(u.fraction.map { (Double(index) + $0) / Double(count) }, message: u.message)
            }
            if !DownloadProgressSink.isProgressNoise(line) { context.log(line) }   // "Destination", "Merger", "Resuming ..." help to diagnose a failure
        }, onStderrLine: { sink.addStderr($0) }, allowNonZeroExit: true)

        var files = area.confined(Self.lines(of: listFile))
        if files.isEmpty { files = area.confined(sink.reportedDestinations) }
        if files.isEmpty { files = DownloadWorkArea.finishedFiles(in: area.out) }
        var warnings: [String] = []
        if out.exitCode != 0 {
            let message = YtDlpInfoParser.friendlyMessage(forStderr: sink.stderrText.isEmpty ? out.stderrTail.joined(separator: "\n") : sink.stderrText)
            // A list where some videos failed still delivers the others.
            guard !DownloadWorkArea.finishedFiles(in: area.out).filter(DownloadFileKinds.isMedia).isEmpty, request.playlistItems != nil else { throw ConversionError.message(message) }
            warnings.append(message.text)
        }
        guard !files.isEmpty else { throw ConversionError.noOutput }
        return DownloadedItem(link: link, info: info, area: area, outputDirectory: outDir, files: files, warnings: warnings)
    }

    /// Relative sizes of the files of one video in download order, so the bar does not jump back when the audio starts.
    static func partWeights(choice: FormatChoice?, mode: DownloadMode, selector: String?) -> [Double] {
        if mode.isAudioOnly { return [1] }
        if let c = choice {
            if c.needsMerge, let v = c.video?.bytes ?? c.video?.tbr.map({ Int64($0) }), let a = c.audio?.bytes ?? c.audio?.tbr.map({ Int64($0) }), v > 0, a > 0 { return [Double(v), Double(a)] }
            return c.needsMerge ? [0.9, 0.1] : [1]
        }
        return (selector ?? FormatSelector.expression(for: mode, maxHeight: nil)).contains("+") ? [0.9, 0.1] : [1]
    }

    private static func lines(of file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func supportsJSRuntimes(ytdlp: URL, tools: ToolLocator) async -> Bool {
        let version = await Task.detached(priority: .utility) { tools.version(of: .ytdlp) }.value
        return YtDlpToolManager.supportsJSRuntimesOption(version: version)
    }

    // MARK: Finish (convert / place)

    private func finalize(_ d: DownloadedItem, after: AfterDownload, burn: Bool, converts: Bool, state: DownloadRunState) async throws -> (outputs: [URL], warnings: [String]) {
        var outputs: [URL] = []
        var warnings = d.warnings
        let all = DownloadWorkArea.finishedFiles(in: d.area.out)
        let rules = ctx.outputRules
        for raw in all.filter(DownloadFileKinds.isMedia) {
            try ctx.checkCancelled()
            let rel = d.area.relativePath(of: raw)
            let parent = (rel as NSString).deletingLastPathComponent
            let destDir = parent.isEmpty ? d.outputDirectory : d.outputDirectory.appendingPathComponent(parent, isDirectory: true)
            let rawStem = raw.deletingPathExtension().lastPathComponent
            let sidecars = DownloadPlacer.sidecars(of: raw, in: all)
            var source = raw
            var burned = false
            if converts && DownloadFileKinds.isVideo(raw) {
                do {
                    if burn {
                        if let srt = sidecars.first(where: { DownloadFileKinds.ext($0) == "srt" }) {
                            source = try await DownloadBurnIn.run(source: raw, subtitles: srt, area: d.area, duration: d.info?.duration, ctx: ctx)
                            burned = true
                        } else { warnings.append(L("This video has no subtitles to draw into the picture.", "У этого видео нет субтитров, которые можно вшить.")) }
                    }
                    if after != .keepOriginal {
                        let converted = try await convert(source, after: after, destDir: destDir, rules: rules)
                        outputs += converted
                        if !burned, let first = converted.first {
                            DownloadPlacer.placeSidecars(sidecars, rawStem: rawStem, finalStem: first.deletingPathExtension().lastPathComponent, into: destDir)
                        }
                        continue
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The conversion failed: the download itself is fine, keep it and say so.
                    let why = ConversionError.describe(error)
                    ctx.log("Convert failed: \(why)")
                    warnings.append(L("The video was saved as downloaded because the conversion did not work: \(why)", "Видео сохранено как скачано, потому что конвертация не удалась: \(why)"))
                    source = raw
                    burned = false
                }
            }
            let (final, note) = try await place(source, base: rawStem, into: destDir, rules: rules)
            if let note { warnings.append(note) }
            outputs.append(final)
            if !burned { DownloadPlacer.placeSidecars(sidecars, rawStem: rawStem, finalStem: final.deletingPathExtension().lastPathComponent, into: destDir) }
        }
        // Anything else yt-dlp left (a cover picture, an .srt without a video) goes along.
        for rest in DownloadWorkArea.finishedFiles(in: d.area.out) where !DownloadFileKinds.isMedia(rest) {
            let rel = d.area.relativePath(of: rest)
            let parent = (rel as NSString).deletingLastPathComponent
            let dir = parent.isEmpty ? d.outputDirectory : d.outputDirectory.appendingPathComponent(parent, isDirectory: true)
            if let moved = try? await DownloadPlacer.place(rest, into: dir, rules: OutputRules()) { _ = moved }
        }
        d.area.remove()
        state.forget(d.area)
        return (outputs, warnings)
    }

    private func place(_ source: URL, base: String, into dir: URL, rules: OutputRules) async throws -> (URL, String?) {
        do {
            return (try await DownloadPlacer.place(source, into: dir, base: base, rules: rules), nil)
        } catch ConversionError.skippedExisting(let existing) {
            return (existing, L("\(existing.lastPathComponent) already exists and was left as it is.", "\(existing.lastPathComponent) уже существует и оставлен без изменений."))
        }
    }

    /// The nested smart / preset run. Output lands in `destDir` under the download's own name.
    private func convert(_ source: URL, after: AfterDownload, destDir: URL, rules: OutputRules) async throws -> [URL] {
        var r = OutputRules()
        r.dirMode = .custom
        r.customDir = destDir.path
        // A template that differs from exactly "{name}" keeps the smart operation from appending its " (Best for Apple)" suffix.
        r.nameTemplate = "{name} "
        r.collision = rules.collision
        r.keepDates = false
        r.verify = rules.verify
        r.after = .nothing
        if let override = DownloadPostProcess.override { return try await override(source, after, r, ctx) }
        guard let (op, overrides) = DownloadPostProcess.operation(for: after) else {
            throw ConversionError.message(L10n("The chosen conversion is not available.", "Выбранная конвертация недоступна."))
        }
        let item = FileItem(url: source)
        if case .unavailable(let reason, _) = op.availability(for: [item], tools: tools) { throw ConversionError.message(reason) }
        guard op.appliesInStudio([item]) else {
            throw ConversionError.message(L10n("The chosen conversion does not apply to this file.", "Выбранная конвертация не подходит для этого файла."))
        }
        let res = try await ctx.runNested(op, items: [item], overrides: overrides, outputRules: r)
        guard !res.outputs.isEmpty else { throw ConversionError.noOutput }
        return res.outputs
    }
}
