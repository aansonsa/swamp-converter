import Foundation
import CoreGraphics

// Pure rules of the Studio window: which commands are available, what "Start" means, how a page selection becomes a range string, what a multi-selection of queue rows
// shows as "Mixed", how a queued job turns into a command line. No UI and no session: every function takes plain values so the self-tests can prove it.

// MARK: - Commands

/// Every command the window offers. Each one is a toolbar item, a menu command or a key (spec/handbrake.md 6.8).
enum StudioCommand: Hashable, Sendable {
    case addFiles, pasteLink, start, addToQueue, preview, searchOptions, presetMenu
    /// Cmd-1 ... Cmd-7: the n-th page of the inspector (1-based).
    case inspectorPage(Int)
    case playPause, stepBackward, stepForward, setIn, setOut
    case undoOption, redoOption
}

/// The few facts command availability depends on.
struct StudioCommandContext: Equatable, Sendable {
    var hasSources = false
    var sessionCanStart = false
    /// Jobs in the queue that wait for "Start Queue".
    var heldQueueCount = 0
    var activeJobCount = 0
    var hasSchema = false
    var pageCount = 0
    /// A video or audio file with a timeline is selected.
    var hasTimeline = false
    var canPreview = false
    var isModified = false
    var redoAvailable = false

    init(hasSources: Bool = false, sessionCanStart: Bool = false, heldQueueCount: Int = 0, activeJobCount: Int = 0, hasSchema: Bool = false, pageCount: Int = 0,
         hasTimeline: Bool = false, canPreview: Bool = false, isModified: Bool = false, redoAvailable: Bool = false) {
        self.hasSources = hasSources; self.sessionCanStart = sessionCanStart; self.heldQueueCount = heldQueueCount; self.activeJobCount = activeJobCount
        self.hasSchema = hasSchema; self.pageCount = pageCount; self.hasTimeline = hasTimeline; self.canPreview = canPreview
        self.isModified = isModified; self.redoAvailable = redoAvailable
    }
}

enum StudioCommands {
    /// How many inspector pages Cmd-1 ... Cmd-7 reach.
    static let maxPageShortcuts = 7

    static func isEnabled(_ command: StudioCommand, _ x: StudioCommandContext) -> Bool {
        switch command {
        case .addFiles, .pasteLink: return true
        case .start: return x.heldQueueCount > 0 || x.sessionCanStart
        case .addToQueue: return x.sessionCanStart
        case .preview: return x.canPreview
        case .searchOptions, .presetMenu: return x.hasSchema
        case .inspectorPage(let n): return x.hasSchema && n >= 1 && n <= min(x.pageCount, maxPageShortcuts)
        case .playPause, .stepBackward, .stepForward, .setIn, .setOut: return x.hasTimeline
        case .undoOption: return x.isModified
        case .redoOption: return x.redoAvailable
        }
    }

    /// Start runs what is in front of the person: the current work when it can start, the waiting queue only when there is nothing else to start. The queue outlives
    /// the window (and a relaunch holds every unfinished job), so "queue first" made Start run old jobs and leave the new files alone. The queue panel has its own Start.
    static func startRunsQueue(_ x: StudioCommandContext) -> Bool { x.heldQueueCount > 0 && !x.sessionCanStart }

    static func startTitle(_ x: StudioCommandContext) -> L10n {
        startRunsQueue(x) ? L10n("Start Queue", "Запустить очередь") : L10n("Start", "Начать")
    }

    static func title(_ command: StudioCommand) -> L10n {
        switch command {
        case .addFiles: return L10n("Add Files…", "Добавить файлы…")
        case .pasteLink: return L10n("Add a Link…", "Добавить ссылку…")
        case .start: return L10n("Start", "Начать")
        case .addToQueue: return L10n("Add to Queue", "В очередь")
        case .preview: return L10n("Refresh Preview", "Обновить просмотр")
        case .searchOptions: return L10n("Search Options", "Поиск параметров")
        case .presetMenu: return L10n("Presets", "Шаблоны")
        case .inspectorPage(let n): return L10n("Inspector Page \(n)", "Страница параметров \(n)")
        case .playPause: return L10n("Play or Pause", "Воспроизвести или остановить")
        case .stepBackward: return L10n("Step Back", "Шаг назад")
        case .stepForward: return L10n("Step Forward", "Шаг вперёд")
        case .setIn: return L10n("Set Start Here", "Начало здесь")
        case .setOut: return L10n("Set End Here", "Конец здесь")
        case .undoOption: return L10n("Undo Option Change", "Отменить изменение параметра")
        case .redoOption: return L10n("Redo Option Change", "Повторить изменение параметра")
        }
    }

    static func symbol(_ command: StudioCommand) -> String {
        switch command {
        case .addFiles: return "plus"
        case .pasteLink: return "link"
        case .start: return "play.fill"
        case .addToQueue: return "text.badge.plus"
        case .preview: return "eye"
        case .searchOptions: return "magnifyingglass"
        case .presetMenu: return "slider.horizontal.3"
        case .inspectorPage: return "sidebar.right"
        case .playPause: return "playpause"
        case .stepBackward: return "backward.frame"
        case .stepForward: return "forward.frame"
        case .setIn: return "arrow.right.to.line"
        case .setOut: return "arrow.left.to.line"
        case .undoOption: return "arrow.uturn.backward"
        case .redoOption: return "arrow.uturn.forward"
        }
    }
}

// MARK: - When the queue is done

/// "When done": what happens after the queue ran. `reveal` and `notify` map onto the job rules of Core (`AfterFinish`); `sleep` is the Studio's own.
enum QueueWhenDone: String, CaseIterable, Identifiable, Sendable {
    case nothing, reveal, notify, sleep
    var id: String { rawValue }

    var title: L10n {
        switch self {
        case .nothing: return L10n("Do nothing", "Ничего не делать")
        case .reveal: return L10n("Show in Finder", "Показать в Finder")
        case .notify: return L10n("Send a notification", "Прислать уведомление")
        case .sleep: return L10n("Put the Mac to sleep", "Усыпить Mac")
        }
    }
    var symbol: String {
        switch self {
        case .nothing: return "circle.slash"
        case .reveal: return "folder"
        case .notify: return "bell"
        case .sleep: return "moon.zzz"
        }
    }
    /// The rule Core runs after each batch; sleeping is done by the Studio itself, so Core gets `.nothing` for it.
    var afterFinish: AfterFinish {
        switch self { case .nothing, .sleep: return .nothing; case .reveal: return .reveal; case .notify: return .notify }
    }
    /// Sleeping is only sensible when everything worked: a failed job keeps the Mac awake so the person sees the failure.
    static func shouldSleep(choice: QueueWhenDone, failed: Int, cancelled: Int, stillActive: Int) -> Bool {
        choice == .sleep && failed == 0 && cancelled == 0 && stillActive == 0
    }
}

// MARK: - Page selection <-> range text

/// The PDF page strip and the "Pages" field are two views of one value. `rangeString` writes the field text; `indices` reads it back.
enum PageSelection {
    /// "all" for an empty or complete selection, otherwise "1-3, 5, 8-" (a run that reaches the last page is written open: "8-").
    static func rangeString(_ indices: Set<Int>, pageCount: Int) -> String {
        let valid = indices.filter { $0 >= 0 && $0 < pageCount }.sorted()
        if valid.isEmpty || valid.count == pageCount { return "all" }
        var parts: [String] = []
        var i = 0
        while i < valid.count {
            var j = i
            while j + 1 < valid.count && valid[j + 1] == valid[j] + 1 { j += 1 }
            let lo = valid[i] + 1, hi = valid[j] + 1
            if lo == hi { parts.append("\(lo)") }
            else if hi == pageCount { parts.append("\(lo)-") }
            else { parts.append("\(lo)-\(hi)") }
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    /// The selected pages for a range text; "all" or empty selects every page. nil for text the field would reject.
    static func indices(from text: String, pageCount: Int) -> Set<Int>? {
        guard pageCount > 0, let list = PageRange.parse(text, pageCount: pageCount) else { return nil }
        return Set(list)
    }

    /// Click semantics of the strip: a plain click selects just that page, Command toggles it, Shift extends from `anchor`.
    static func toggled(_ current: Set<Int>, page: Int, anchor: Int?, command: Bool, shift: Bool, pageCount: Int) -> Set<Int> {
        guard page >= 0, page < pageCount else { return current }
        if shift, let a = anchor { return current.union(min(a, page)...max(a, page)) }
        if command { var s = current; if s.contains(page) { s.remove(page) } else { s.insert(page) }; return s }
        return [page]
    }
}

// MARK: - Mixed values across several queue rows

enum QueueBulkEdit {
    enum Common: Equatable {
        case same(OptionValue?)
        case mixed
        var isMixed: Bool { self == .mixed }
    }

    /// The value of `key` shared by every set, or `.mixed` when they differ.
    static func common(key: String, in sets: [OptionValues]) -> Common {
        guard let first = sets.first else { return .same(nil) }
        let v = first[key]
        for s in sets.dropFirst() where !same(s[key], v) { return .mixed }
        return .same(v)
    }

    private static func same(_ a: OptionValue?, _ b: OptionValue?) -> Bool {
        if a == b { return true }
        guard let a, let b, isNumber(a), isNumber(b), let x = a.asDouble, let y = b.asDouble else { return false }
        return abs(x - y) < 1e-9
    }

    private static func isNumber(_ v: OptionValue) -> Bool { if case .int = v { return true }; if case .double = v { return true }; return false }

    /// Writes ONLY the touched keys on top of one job's own overrides; everything the person did not touch stays as that job had it.
    static func apply(_ touched: OptionValues, to overrides: OptionValues) -> OptionValues { overrides.overlaying(touched) }

    /// Rows can be edited together only when they run the same target (the same option pages).
    static func canEditTogether(schemaIDs: [String]) -> Bool { Set(schemaIDs).count == 1 && !schemaIDs.isEmpty }
}

// MARK: - Reordering the queue list

enum QueueReorder {
    /// Moves inside the displayed list with the same semantics as `onMove`, returning the new id order. Only the ids in `movable` may move; anything else is a no-op.
    static func reordered(_ ids: [UUID], movingOffsets source: IndexSet, to destination: Int, movable: Set<UUID>) -> [UUID] {
        let moving = source.sorted().compactMap { ids[safe: $0] }
        guard !moving.isEmpty, moving.allSatisfy({ movable.contains($0) }) else { return ids }
        var list = ids
        for i in source.sorted().reversed() { list.remove(at: i) }
        let shift = source.filter { $0 < destination }.count
        list.insert(contentsOf: moving, at: max(0, min(list.count, destination - shift)))
        return list
    }
}

// MARK: - Copy as command line

/// "Copy Command": the job as a `swamp` command (the app's own CLI), shell-quoted, so a recipe tuned in the Studio can run from a script.
enum StudioCommandLine {
    /// POSIX single quoting: safe words stay bare, everything else is wrapped and embedded quotes are escaped.
    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:,+@%").contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `value` of `--set key=value`; nil for values the CLI cannot express (track rows).
    static func valueString(_ v: OptionValue) -> String? {
        switch v {
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(d)
        case .string(let s): return s
        case .list(let items):
            let parts = items.compactMap { valueString($0) }
            return parts.count == items.count ? parts.joined(separator: ",") : nil
        case .rows: return nil
        }
    }

    static func command(operationID: String, files: [URL], values: OptionValues, outputDirectory: String? = nil) -> String {
        var parts = ["swamp", "convert"] + files.map { quote($0.path) }
        parts += ["--op", quote(operationID)]
        for key in values.keys {
            if let v = values[key], let s = valueString(v) { parts += ["--set", quote("\(key)=\(s)")] }
        }
        if let dir = outputDirectory, !dir.isEmpty { parts += ["--out", quote(dir)] }
        return parts.joined(separator: " ")
    }

    /// Keys of a job's overrides that the command line cannot carry (shown as a calm note next to the copied text).
    static func unsupportedKeys(in values: OptionValues) -> [String] { values.keys.filter { values[$0].flatMap(valueString) == nil } }
}

// MARK: - Window frame text

enum StudioFrameStore {
    /// `NSStringFromRect` text -> a frame that is at least `minSize` and intersects one of `screens`; nil when the text is unusable (the window then opens centred).
    static func restoredFrame(from text: String?, minSize: CGSize, screens: [CGRect]) -> CGRect? {
        guard let text, !text.isEmpty else { return nil }
        let r = NSRectFromString(text)
        guard r.width.isFinite, r.height.isFinite, r.width >= 100, r.height >= 100 else { return nil }
        var frame = r
        frame.size.width = max(frame.width, minSize.width)
        frame.size.height = max(frame.height, minSize.height)
        // At least a quarter of the window must be visible on some screen (a display that was unplugged leaves the frame off screen).
        let visible = screens.contains { s in
            let i = s.intersection(frame)
            return !i.isNull && i.width * i.height >= frame.width * frame.height * 0.25
        }
        return visible ? frame : nil
    }
}

// MARK: - Queue summaries

enum QueueSummaryText {
    /// "2 of 12 failed: disk full / unsupported codec": the first two distinct reasons, then "and more".
    static func failureSummary(failed: Int, total: Int, reasons: [String]) -> String? {
        guard failed > 0, total > 0 else { return nil }
        var distinct: [String] = []
        for r in reasons.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !r.isEmpty && !distinct.contains(r) { distinct.append(r) }
        let head = L("\(failed) of \(total) failed", "Не удалось: \(failed) из \(total)")
        guard !distinct.isEmpty else { return head }
        let shown = distinct.prefix(2).map { $0.split(separator: "\n").first.map(String.init) ?? $0 }.joined(separator: " / ")
        return head + ": " + shown + (distinct.count > 2 ? L(" and more", " и другое") : "")
    }

    /// "3 waiting, 1 running" for the header of the panel.
    static func counts(_ q: QueueSnapshot) -> String {
        var parts: [String] = []
        if q.running > 0 { parts.append(L("\(q.running) running", "выполняется: \(q.running)")) }
        if q.paused > 0 { parts.append(L("\(q.paused) paused", "на паузе: \(q.paused)")) }
        let waiting = q.held + q.waiting
        if waiting > 0 { parts.append(L("\(waiting) waiting", "ожидает: \(waiting)")) }
        if q.done > 0 { parts.append(L("\(q.done) done", "готово: \(q.done)")) }
        if q.failed > 0 { parts.append(L("\(q.failed) failed", "ошибок: \(q.failed)")) }
        return parts.isEmpty ? L("The queue is empty", "Очередь пуста") : parts.joined(separator: ", ")
    }
}

/// What "Remove" keeps so it can be undone: enough to put the job back where it was.
struct RemovedJobSnapshot: Equatable {
    var operationID: String
    var items: [FileItem]
    var links: [LinkItem]
    var overrides: OptionValues
    var outputRules: OutputRules?
    var index: Int
    var title: String
}
