# Swamp Converter: architecture

A native menu-bar app for macOS 26 and later in Swift (AppKit + SwiftUI). Files and web links go in; local work comes out. Two speeds, one engine:

* **Quick**: the radial wheel, Services, Dock / menu-bar drop, hotkeys, watched folders. One gesture, the operation's *quick recipe*.
* **Studio**: a HandBrake-class window where any option of any file kind can be set. Same operations, same engine, options edited by the person.

Everything is built with `swiftc` directly (the Xcode licence is not accepted on this Mac: never use `xcrun`, `xcodebuild`, `swift build`). Sources and `dist/` live on the exFAT drive; all compile output lives in `~/Library/Caches/SwampConverter`.

## 1. The rules that keep twenty engineers apart

1. Every file belongs to exactly one module (`modules.json`; `./build.sh check-modules` proves it). You edit only your module's files.
2. `Sources/Core`, `Sources/UI/Shared` and every module's skeleton API are a **frozen contract**: add, never change or remove a signature. If you must change one, stop and report it.
3. Modules depend on Core + Shared + the *skeleton APIs* of other modules, never on their internals. Engines touch only Core (+ the media / image / pdf / data service APIs listed in their briefs).
4. Every option of every schema has a real, tested effect (an *oracle*: read the output back and prove it). A schema field without `.oracle("...")` is a bug.
5. Operation behaviour is a pure function of `(items, ctx.options)`. It never branches on its own id. Several operations share one schema and differ only by `quickOverrides`.
6. Nothing runs at idle: no timers, no polling. Heavy frameworks (Vision, Speech, AVFoundation, PDFKit) are used on first use only. Registration builds descriptors; schemas are built when asked for.
7. No network anywhere except the downloader, after explicit consent, through `NetworkGate`. Tests forbid it entirely.
8. Never write outside the project, the build cache or the scratch folder. Never delete what you did not create (build.sh moves replaced artefacts to `$CACHE/trash`).

## 2. Module map and file ownership

| id | files | what |
|---|---|---|
| core | `Sources/Core/*` (+`Tests/`), `Sources/Bootstrap/*` | model, options, jobs, scheduler, links, settings, test and snapshot harnesses, `EnginesBootstrap`, `Harness` |
| shared | `Sources/UI/Shared/*` | design tokens, `Brand`, glass panel, chips, slanted progress bar, empty state, `.appRoot()` |
| image | `Sources/Engines/Image/*` | ImageIO / CoreImage conversions, edits, images to PDF, schema `image.convert`, `ImageLoader`, `ImageEncoder` |
| media-audio | `Sources/Engines/Media/Audio/*` | audio operations, schema `audio.convert`, `AudioTranscoder` |
| media-video | `Sources/Engines/Media/Video/*`, `Media/Common/*` | video, schema `video.convert`, `MediaProbe`, `FFmpegCommand`, `FFmpegRunner`, `VideoFrameService` |
| pdfocr | `Sources/Engines/Pdf/*` | PDFKit, Vision OCR, protect / unlock, `PdfRasterizer`, `OcrService` |
| docs | `Sources/Engines/Docs/*` | documents and slides, `DocConverter` |
| data | `Sources/Engines/Data/*` | `ZipKit`, spreadsheets, `SubtitleKit`, archives |
| downloader | `Sources/Engines/Downloader/*`, `Tests/Fixtures/downloader/*` | yt-dlp manager, info, formats, runner, `DownloadService` |
| smart | `Sources/Engines/Smart/*` | planner, engine, verifier of "Best for Apple / Maximum / Universal" |
| sizefit | `Sources/Engines/SizeFit/*` | "compress to N MB" planners and operations |
| intelligence | `Sources/Engines/Intelligence/**` | transcription, background removal, privacy scrub, clipboard source |
| cli | `Sources/CLI/*` | headless commands, JSON Lines output |
| studio-core | `Sources/UI/Studio/Core/*` | `StudioSession`, the schema renderer (`OptionFormView`, `OptionFieldView`) |
| studio-window | `Sources/UI/Studio/Window/*` | window, sidebar, toolbar, preview, queue panel |
| actions | `Sources/Actions/*` | Actions wheel, shelf, `ResultActions` |
| automation | `Sources/Automation/*` | watched folders, chains, multi-output packs, watch templates |
| wheel | `Sources/UI/Wheel/*` | drag detection, panel, wheel view, hotkeys, `BrowserLinkReader`, Finder selection |
| settings | `Sources/UI/Settings/*` | Settings window, page registry, layout editor, parameter sheet |
| jobs | `Sources/UI/Jobs/*` | Jobs window, HUD, notifications, toasts, menu-bar progress model |
| download-ui | `Sources/UI/Downloader/*` | link sheet, info card, pickers, consent, Downloader settings page |
| app | `Sources/App/*`, `Resources/*`, `scripts/package.sh`, `install.sh`, `measure.sh` | entry, delegate, status item, Services, URL scheme, onboarding, About, packaging |

Registration order in `EnginesBootstrap.registerAll()` is the catalogue order of the wheels. Every module exposes one `enum` with `registerOperations()` (engines), `registerSelfTests()` and (UI) `registerSnapshots()`.

## 3. The contracts

**Inputs.** `FileItem` (file or folder; kind by extension then UTType) and `LinkItem` (http/https URL, title, host). `InputItem` is the sum; `IncomingInput` (files + links + origin + page title) is what every door produces. `LinkParsing` (pure) extracts, validates (only public http(s); no credentials, no private hosts), strips tracking parameters and gives a canonical key (youtu.be equals youtube.com/watch). `DownloadURLScheme` parses `swampconverter://download?url=...&mode=...`.

**Operation** (`Core/Operation.swift`): `meta` (id, wheel, family, label, symbol, `schemaID`, tools, inputs, `quickPromptKeys`, concurrency class), `quickOverrides(settings:)`, `optionSchema(for:)`, `appliesTo` / `appliesInStudio`, `availability`, `validate`, `estimate`, `summaryChips`, `preview`, `execute(items:ctx:)`, and for links `appliesToLinks`, `executeLinks`, `stagePlan`. Subclass `PerFileOperation` (one file at a time, failures collected per file), `BatchOperation` (all together), `AppAction` (runs in the app, no progress card) or `LinkOperation` (downloads). `WheelKind` is `convert`, `tools`, `actions`, `link`.

**Options.** `OptionSchema` = pages > groups > fields. Field kinds: toggle, picker, segmented, slider, stepper, text, time, number, folder, file, color, tracks (rows for audio / subtitle lists). Each field has a stable dotted `key`, EN/RU label and help, default (literal or computed from the probed source), `level` (basic / standard / expert), `visibleWhen` / `enabledWhen` expressions (`OptionExpr`), `requires` capabilities (a missing one disables the control with a reason, never hides it), validation rules with one-click fixes, `oracle`, aliases for search. `schema.resolve(layers:)` returns complete, clamped `ResolvedOptions`; inactive fields reset to defaults and engines ignore them (`ctx.isActive(key)`). Layer order: defaults(source) < op quick overrides < user quick edits < preset < job overrides. `OptionValues` is plain JSON.

**Recipe and presets.** `Recipe` = operation id + sparse values + output rules. `PresetStore` keeps built-ins (registered by engines, ids `builtin.*`) and user presets (one JSON file each; import / export `.swampreset`). A preset with `onWheel` becomes a sector `preset.<id>`. `QuickRecipes` is the one place that resolves what a wheel run uses; `alwaysStripMetadata` layers `Operation.privacyOverrides()` onto quick and automatic runs.

**Jobs.** `JobRunner.shared` serves everything: `submit`, `enqueue` (held), `startQueue`, pause / resume / cancel / retry / move, per-job `updateOverrides`, `events()` AsyncStream, history (capped), persistence of the unfinished queue. Stages (`StageSpec`, `ctx.beginStage`, `ctx.report` = current stage) give a download-then-convert job one progress and ETA. `ctx.runNested(op, ...)` runs another operation inside the same job (convert stage, chain step, multi-output pack). Output always goes through `ctx.produceFile` / `produceFolder`: hidden `.part`, atomic move, `name (2).ext` collisions, no partial after error or cancel, `OwnOutputs` registration (watched-folder loop guard).

**Scheduler.** `ResourcePolicy` lowers concurrency for Low Power Mode, heat and core count; unattended jobs run at utility QoS with niced child processes and wait on battery if the setting says so; `SleepGuard` holds the Mac awake only while a job runs; `DiskSpaceGuard` checks output plus temp before a job starts; `SystemEnvironmentMonitor` reacts to notifications (no polling).

**Tools.** `ToolLocator` finds ffmpeg, ffprobe, pandoc, soffice (also `/Applications/LibreOffice.app`), magick, cwebp, lame, flac, sox, zstd, xz, pdftotext, yt-dlp and the JS runtimes (user override, bundled, `~/Library/Application Support/Swamp Converter/tools`, Homebrew, PATH). `Capabilities` answers "can this Mac do X": `tool.<name>`, `ff.enc.<encoder>`, `ff.filter.<name>`, `ff.mux.<name>`, `native.*`, `dl.*` (parsed once from the binary, cached by path + mtime). `ProcessRunner` takes argument arrays only (no shell), streams lines split on `\n` and `\r`, kills the process tree on cancel, supports SIGSTOP pause. The legacy ImageMagick 6 in `/opt/ImageMagick` is deliberately ignored.

**Shared services in Core.** `ThumbnailCache.shared` (ImageIO thumbnails with `kCGImageSourceThumbnailMaxPixelSize`, QLThumbnailGenerator for other kinds, file-icon fallback, 32 MB `NSCache`): every module that shows a picture of a file uses it. `WindowPresence.shared.opened/closed(id)` switches the app between menu-bar-only and Dock-icon mode while windows are open. `MessageCenter` carries one-line user messages (toasts). `QuickRun.shared` is the one door for starting work from gestures (files and links); nothing else submits quick jobs.

**Probing.** `SourceProbeRegistry` (cached by path + mtime + size) turns a file into `SourceInfo`: dotted facts (`video.height`, `audio.0.codec`, `image.hasGPS`, ...), chips, streams, plain-words warnings. Schema defaults and conditions read these facts.

**Downloader and smart transcode.** `DownloadService.shared.start(url:mode:)` is the single entry (wheel, hotkeys, Services, URL scheme, CLI, Studio). It validates the link, asks for consent through hooks, checks yt-dlp, then submits a two-stage job (download, then `SmartTranscoder` or a preset). `SmartMode`: *Best for Apple* (remux Apple-friendly streams, else HEVC hvc1 with 10-bit / HDR kept), *Maximum* (no transcode), *Universal* (H.264 <= 1080p + AAC). The planner is pure (`MediaInfo` in, `TranscodePlan` out); `SmartVerifier` proves playability with AVFoundation.

**Network.** `NetworkGate.authorize` is the only checkpoint: consent required, `forbidAll` in `--self-test` / `--snapshot`, host-only activity log. yt-dlp is never shipped or fetched silently; `YtDlpToolManager.install()` is one explicit button with SHA-256 verification.

## 4. Concurrency conventions

* UI types are `@MainActor`. Engines are `async` and run off the main actor (`Task.detached` with the job's QoS from `JobRunner`). Shared mutable state uses `Locked<T>` or an actor; `OperationContext` is `@unchecked Sendable` and thread-safe.
* Cancellation is Swift Task cancellation: call `try ctx.checkCancelled()` in loops, `try await ctx.waitIfPaused()` between work units, let `CancellationError` propagate. Cancel must be effective within 200 ms; child processes die with the task.
* Progress is reported as fractions of the current stage; the Job throttles UI updates (about 10 Hz). Never add a timer to animate progress.
* Compile flags: `-swift-version 5`; the macros `#Preview`, `@Entry`, `#Predicate`, SwiftData are unavailable here (hand-write `EnvironmentKey`s, use closures).

## 5. Localisation

All user-visible strings are `L("English", "Русский")` or an `L10n` value. The language setting (system / Russian / English) takes effect at once: wrap every root view with `.appRoot()` (which includes `.localizedRoot()`). Plurals use `Loc.plural` (one / few / many). RU is 30 to 40 percent longer: no fixed widths, allow two lines, test with the `*.ru` snapshots. Code, comments and identifiers are English. Apple vocabulary in RU: "Конвертировать", "Службы". Calm microcopy: what happened, why, what to do; no exclamation marks, no emoji.

## 6. Design system

Foundation: Apple's macOS 26 design (Liquid Glass on the control layer only, system materials, SF Pro, SF Symbols hierarchical, native `Form .grouped` / `Toggle` / `Picker` / `Table`, automatic light and dark). Tokens in `UI/Shared/DesignSystem`: `DS.Space` (4/8 grid), `DS.Radius` (concentric), `DS.Motion` (spring response 0.35 / damping 0.8; hover 0.22), `DS.Typo`, `Brand`.

Brand = signature only, never large fills. Swamp Pink `#FF72D9` (accent: tint, hover ring, progress fill, drop glow), Swamp Blue `#7DA7D9` (secondary: chips, defaults, scrubbers). Use `Brand.pinkInk` / `blueInk` for text and thin icons (WCAG-checked: text 4.5:1, graphics 3:1, Increase Contrast 7:1); `Brand.tint` is pure pink in dark mode and a deepened pink in light mode so tinted controls stay legible. `Brand.wordmark(size:)` (black-weight italic "swp", tilted 6 degrees) appears sparingly: About, first run, empty states, Studio header, wheel hub. Buttons: one `.brandProminent` call to action per window, `.secondaryButtonLook()` for the rest; never `.glassProminent` / `.borderedProminent` with the pink tint. Respect Reduce Motion, Reduce Transparency, Increase Contrast and Differentiate Without Colour through `@Environment(\.a11y)`. The menu-bar icon is a monochrome template image; pink appears only as a status dot or progress ring while jobs run. Never regenerate the owner's logo or icon.

## 7. How to add things

**An operation.** Subclass `PerFileOperation` (or Batch / App / Link), build a catalogue row with `OperationMeta.make(...)` / `.convert(...)`, implement `optionSchema` (every field with an oracle), `quickOverrides` (the quick recipe from `settings`), `process`, and register it in your module's `registerOperations()`. Write output with `ctx.produceFile`, check `ctx.isActive(key)` before reading a key, report `progress.report(0...1)`. Add tests for every option (golden argv without encoding, and a real run read back with an independent probe).

**A self-test.** `SelfTestRegistry.shared.register("<module>", "behaviour in a sentence") { ... }` inside your module's `registerSelfTests()`. Use `TestFixtures` (generates PNG, JPEG with GPS, WAV, PDF, CSV, SRT, zip, tar.gz, H.264 video; everything in a temp folder). Assertions: `expect`, `expectEqual`, `expectClose`, `expectThrows`, `unwrap`, `skipTest`. Tests that need an optional tool declare `requires: ["tool.ffmpeg"]` and SKIP with the reason. Output is one PASS / FAIL / SKIP line per test; any FAIL exits 1.

**A snapshot.** `SnapshotRegistry.shared.register("<module>.<what>", size:, backdrop:, variants:) { View }` inside `registerSnapshots()`. Variants: light, dark, `.ru`, `.rt` (Reduce Transparency), `.rm` (Reduce Motion), `.ic` (Increase Contrast). Glass only renders through WindowServer capture, so the harness puts a backdrop and the view in one off-screen window and captures it (never on a real display). Known limit: system controls such as toggles and sliders may draw in their inactive grey; judge brand colours on custom-drawn elements.

## 8. build.sh cheat sheet

```
./build.sh typecheck all            live tree, fast (-Onone -typecheck), safe to run concurrently
./build.sh typecheck <module-id>    pristine skeleton snapshot + that module's live files: other people's edits cannot block you
./build.sh build [--release]        one swiftc invocation into ~/Library/Caches/SwampConverter/build/{debug,release}
./build.sh selftest [filter]        build, run --self-test (filter = text in "suite/name"); exit 1 on any failure
./build.sh snapshot <dir> [filter]  build, run --snapshot (offscreen PNGs + index.txt)
./build.sh package                  release build, assemble + ad-hoc sign "Swamp Converter.app" in the cache, ZIP + copy to dist/
./build.sh run                      debug build, assemble, launch
./build.sh measure size|links|idle|launch|opt   bundle size, linked libraries, 60 s idle CPU / wake-ups / footprint, time to ready, -O vs -Osize (metric=value lines; the app is started with its own isolated home and quit with SIGTERM)
./build.sh check-modules | modules | snapshot-skeleton | gc
```

Environment knobs: `SC_MODULE=core,image,media-audio,...` swaps several modules from the pristine skeleton to their live files at once (a comma list builds a private copy of the file set, `SC_SNAPSHOT=1` does the same for one module, so colleagues' edits cannot break your run); `SC_TIMEOUT` bounds a whole self-test run (seconds, default 1800; every test also has its own watchdog).

## 8b. Conformance: real converters, not renamed copies

`./build.sh selftest conformance` runs every registered operation for real, on realistic fixtures (a photographic picture with grain, text and 1-pixel colour stripes; a stereo chirp / tone / burst / noise mix; a moving 640x360 H.264 + AAC clip; a multi-page text PDF; a unicode table with quoted delimiters; subtitles with markup past one hour; a project tree with permissions; a hostile zip-slip archive) and judges the output with code that did not write it. The tests are generated from `OperationRegistry` (`Core/Conformance/ConformanceGate.swift`): one `conformance.<family>` test per operation, plus `conformance.coverage`, which FAILS when an operation has no oracle.

Every run first passes the generic checks a conversion owes: the real format by the bytes (`FormatSniffer`: magic numbers and container boxes, never the extension), extension and bytes agree, a conversion to X wrote X, an independent reader decodes it (ImageIO, AVAudioFile or ffmpeg, AVAssetReader, PDFKit, `unzip -t`, `bsdtar`), it is not byte-identical to its input unless `OperationMeta.passthrough` declares `.remux` / `.identity` / `.conditional`, inputs are untouched, no `.part` files are left, the output is named after its input, progress stays in 0...1.

Then the operation's oracle (`ConformanceRegistry.shared.add(ConformanceOracle(...))`, matched by exact id or any predicate over `OperationMeta`; engines register at priority 100, Core's defaults at 0, the generic fallback at -100): pictures by PSNR / SSIM against the source flattened on white (lossless targets pixel-exact, alpha kept or flattened, EXIF orientation applied), audio by SNR after alignment (lossless targets sample-exact, duration within 20 ms), video by ffmpeg SSIM / PSNR on aligned frames plus frame count, fps, duration, sound kept and AVFoundation playback, PDF by word recall in order and page-render PSNR, documents by headings / lists / tables / bold read back with independent parsers and Apple's textutil, tables cell by cell, subtitle cues to the millisecond, archives member by member (bytes and permission bits), hostile archives refused without writing outside the destination. Lossy quality knobs must be monotonic (low versus high: smaller file and lower score) and the default quality must be as good as a reference encoder at the same file size (`ReferenceParity`: sips, cwebp, afconvert, LAME, libx264). The floors live in `ConformanceOracles` and `conformance.calibration` proves each one sits below what the reference encoder reaches on the same fixture. `conformance.harness` proves the suite catches the cheats it exists for (a PNG renamed to .jpg, a blank or mirrored picture, a quality slider that does nothing, a byte copy, an edited input).

An operation that cannot reach the bar on this Mac must be unavailable with an honest hint, never degraded. Example found by the suite: ffmpeg's built-in `vorbis` encoder reaches only 6 dB SNR on the fixture (and macOS decodes its streams wrongly), so Ogg needs libvorbis.

## 9. Budgets (release build)

Bundle <= 12 MB with no bundled third-party tools (now about 2 MB). Idle CPU average <= 0.1 percent over 60 s, zero periodic timers, idle footprint <= 70 MB, launch to ready <= 0.8 s. The wheel appears <= 80 ms after drag detection at the display refresh rate. Progress UI <= 10 Hz. Thumbnails through ImageIO with `kCGImageSourceThumbnailMaxPixelSize` and a size-capped `NSCache`; large files are streamed. After 200 jobs memory returns to within 10 MB of the start (history is capped; `JobRunner` keeps at most 40 finished jobs). Heavy work is off the main thread and cancellable within 200 ms. Logging is `os_log` at info level, never per frame. Measure with `ps`, `top -stats idlew`, `footprint`, `vmmap`, `sample`, `leaks`, `time -l`, `otool`, `size`.

## 10. Naming and credit

The name of the project this app was inspired by never appears in identifiers, UI strings, bundle names or file names; the credit line lives only in `README.md` and the About page (its exact text is in the README). All code is original Swift. HandBrake is a UX reference only (GPL: no code copied). yt-dlp (Unlicense) is invoked, never bundled; ffmpeg (GPL build here) is invoked, never bundled.
