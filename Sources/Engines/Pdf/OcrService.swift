import Foundation
import CoreGraphics
@preconcurrency import Vision

// Text recognition with Vision (accurate level; the fast level has no Russian - spec trap 26). Loaded on first use only.
// Latvian, Lithuanian and Estonian are NOT supported by the macOS recogniser: Latvian text loses its diacritics (the UI says so).

/// One recognised line: text, box (normalised 0...1 of the picture, ORIGIN BOTTOM-LEFT as Vision reports it) and confidence.
struct OcrLine: Sendable, Equatable {
    var text: String
    var box: CGRect
    var confidence: Double
}

struct OcrResult: Sendable {
    var lines: [String]
    /// Mean confidence 0...1.
    var confidence: Double
    /// Recognised lines with their boxes, in reading order (top to bottom, left to right). Empty only for hand-made results.
    var observations: [OcrLine] = []
    var text: String { lines.joined(separator: "\n") }
}

struct OcrOptions: Sendable {
    /// BCP-47 ids; empty = system languages + en-US.
    var languages: [String] = []
    var accurate = true
    /// Let Vision detect the language itself (the listed languages stay as hints).
    var autoDetect = true
    var languageCorrection = true
}

/// What was handed to Vision for one recognition (the self-tests read it to prove that the options reach the recogniser).
struct OcrRequestInfo: Sendable, Equatable {
    var languages: [String]
    var accurate: Bool
    var autoDetect: Bool
    var correction: Bool
}

enum OcrService {
    /// The 30 languages of the accurate level on macOS 26 (checked against the live list at run time; spec/platform.md 4).
    static let knownLanguageCodes: [String] = [
        "en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR", "zh-Hans", "zh-Hant", "yue-Hans", "yue-Hant", "ko-KR", "ja-JP", "ru-RU", "uk-UA",
        "th-TH", "vi-VT", "ar-SA", "ars-SA", "tr-TR", "id-ID", "cs-CZ", "da-DK", "nl-NL", "no-NO", "nn-NO", "nb-NO", "ms-MY", "pl-PL", "ro-RO", "sv-SE"
    ]
    /// Languages the fast level can read.
    static let fastLanguageCodes: Set<String> = ["en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR"]

    private static let supportedCache = Locked<[String]?>(nil)
    private static let observer = Locked<(@Sendable (OcrRequestInfo) -> Void)?>(nil)

    /// Test seam: called with every request just before Vision runs it. Pass nil to remove.
    static func observeRequests(_ f: (@Sendable (OcrRequestInfo) -> Void)?) { observer.value = f }

    /// Vision text recognition. `languages` are BCP-47 ids from `recognitionLanguages` (empty = system languages + en-US).
    /// Accurate level by default; drops nothing silently (spec trap 26: diacritics). Honours Task cancellation.
    static func recognize(_ image: CGImage, languages: [String] = [], accurate: Bool = true) async throws -> OcrResult {
        try await recognize(image, options: OcrOptions(languages: languages, accurate: accurate))
    }

    static func recognize(_ image: CGImage, options: OcrOptions) async throws -> OcrResult {
        try Task.checkCancellation()
        guard !supportedIdentifiers().isEmpty else {
            throw ConversionError.message(L10n("Text recognition is not available on this Mac.", "Распознавание текста недоступно на этом Mac."))
        }
        let run = VisionRun()
        let qos: DispatchQoS.QoSClass = Task.currentPriority >= .userInitiated ? .userInitiated : (Task.currentPriority >= .medium ? .default : .utility)
        return try await run.recognize(image, options: options, qos: qos)
    }

    fileprivate static func notify(_ info: OcrRequestInfo) { observer.value?(info) }

    /// Languages Vision can recognise on this Mac (accurate level), BCP-47 ids with localised display names for pickers.
    static func supportedLanguages() -> [(id: String, name: String)] {
        supportedIdentifiers().map { ($0, displayName(for: $0)) }
    }

    /// Ids only; cached after the first call (which loads Vision).
    static func supportedIdentifiers() -> [String] {
        if let c = supportedCache.value { return c }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let list = (try? request.supportedRecognitionLanguages()) ?? []
        supportedCache.value = list
        return list
    }

    /// nil = not asked yet (Vision not loaded). The wheel uses this: it never loads Vision just to decide about a slice.
    static var knownAvailability: Bool? { supportedCache.value.map { !$0.isEmpty } }

    static func isSupported(_ id: String) -> Bool { supportedIdentifiers().contains(id) }

    /// "Russian (Russia)" / "русский (Россия)" in the UI language.
    static func displayName(for id: String) -> String {
        let locale = Locale(identifier: Loc.shared.language == .ru ? "ru" : "en")
        let name = locale.localizedString(forIdentifier: id) ?? id
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// System languages that Vision knows, then en-US: ["ru-RU", "en-US"] on a Russian Mac, ["en-US"] on a Latvian one.
    static func defaultLanguages(preferred: [String] = Locale.preferredLanguages) -> [String] {
        var out: [String] = []
        for p in preferred {
            let lang = String(p.split(separator: "-").first ?? "")
            guard !lang.isEmpty else { continue }
            if let code = knownLanguageCodes.first(where: { $0.hasPrefix(lang + "-") }), !out.contains(code) { out.append(code) }
        }
        if !out.contains("en-US") { out.append("en-US") }
        return out
    }

    /// The languages to hand to Vision: the wanted ones that this Mac supports, else the defaults.
    static func usableLanguages(_ wanted: [String]) -> [String] {
        let supported = Set(supportedIdentifiers())
        let ok = wanted.filter { supported.contains($0) }
        if !ok.isEmpty { return ok }
        let d = defaultLanguages().filter { supported.contains($0) }
        return d.isEmpty ? Array(supported.prefix(1)) : d
    }
}

// MARK: - Vision run (cancellable without blocking the caller)

private final class VisionRun: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OcrResult, Error>?
    private var finished = false
    private var cancelled = false

    func recognize(_ image: CGImage, options: OcrOptions, qos: DispatchQoS.QoSClass) async throws -> OcrResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<OcrResult, Error>) in
                lock.lock()
                if cancelled { finished = true; lock.unlock(); c.resume(throwing: CancellationError()); return }
                continuation = c
                lock.unlock()
                DispatchQueue.global(qos: qos).async { [self] in
                    do { finish(.success(try Self.perform(image, options: options))) } catch { finish(.failure(error)) }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func finish(_ result: Result<OcrResult, Error>) {
        lock.lock()
        guard !finished, let c = continuation else { lock.unlock(); return }
        finished = true; continuation = nil
        lock.unlock()
        c.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        guard !finished, let c = continuation else { lock.unlock(); return }
        finished = true; continuation = nil
        lock.unlock()
        c.resume(throwing: CancellationError())
    }

    private static func perform(_ image: CGImage, options: OcrOptions) throws -> OcrResult {
        let request = VNRecognizeTextRequest()
        let langs = OcrService.usableLanguages(options.languages)
        // The fast level reads six Latin languages only: anything else needs the accurate level.
        let fastOK = !options.accurate && langs.allSatisfy { OcrService.fastLanguageCodes.contains($0) }
        request.recognitionLevel = fastOK ? .fast : .accurate
        request.recognitionLanguages = langs
        request.automaticallyDetectsLanguage = options.autoDetect
        request.usesLanguageCorrection = options.languageCorrection
        OcrService.notify(OcrRequestInfo(languages: langs, accurate: request.recognitionLevel == .accurate, autoDetect: options.autoDetect, correction: options.languageCorrection))
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var lines: [OcrLine] = []
        for obs in request.results ?? [] {
            guard let top = obs.topCandidates(1).first else { continue }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            lines.append(OcrLine(text: text, box: obs.boundingBox, confidence: Double(top.confidence)))
        }
        let rows = OcrLayout.rows(lines)
        let ordered = rows.flatMap { $0 }
        let mean = ordered.isEmpty ? 0 : ordered.map(\.confidence).reduce(0, +) / Double(ordered.count)
        return OcrResult(lines: rows.map { OcrLayout.text(ofRow: $0) }, confidence: mean, observations: ordered)
    }
}

// MARK: - Reading order

/// Observations are boxes in normalised bottom-left coordinates: sort into rows (top to bottom, tolerance by height), then left to right.
enum OcrLayout {
    static func rows(_ lines: [OcrLine]) -> [[OcrLine]] {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[OcrLine]] = []
        var rowMid: [CGFloat] = []
        var rowHeight: [CGFloat] = []
        for l in sorted {
            if let i = rows.indices.last(where: { abs(rowMid[$0] - l.box.midY) < 0.5 * min(rowHeight[$0], l.box.height) }) {
                rows[i].append(l)
                let n = CGFloat(rows[i].count)
                rowMid[i] = (rowMid[i] * (n - 1) + l.box.midY) / n
                rowHeight[i] = max(rowHeight[i], l.box.height)
            } else {
                rows.append([l]); rowMid.append(l.box.midY); rowHeight.append(l.box.height)
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    /// The segments of one row joined by a space, or by a tab when a wide gap suggests columns.
    static func text(ofRow row: [OcrLine]) -> String {
        var out = ""
        for (i, l) in row.enumerated() {
            if i > 0 {
                let gap = l.box.minX - row[i - 1].box.maxX
                out += gap > 1.5 * max(l.box.height, row[i - 1].box.height) ? "\t" : " "
            }
            out += l.text
        }
        return out
    }

    /// Paragraphs for Markdown: a vertical gap bigger than the line height starts a new one; hyphenated line ends are joined.
    static func paragraphs(_ rows: [[OcrLine]]) -> [String] {
        var out: [String] = []
        var current = ""
        var previous: [OcrLine]?
        for row in rows {
            let t = text(ofRow: row)
            if let p = previous {
                let h = max(row.map(\.box.height).max() ?? 0, p.map(\.box.height).max() ?? 0)
                let gap = (p.map(\.box.minY).min() ?? 0) - (row.map(\.box.maxY).max() ?? 0)
                if gap > 0.9 * h { out.append(current); current = t }
                else { current = PdfMarkdown.join(current, t) }
            } else { current = t }
            previous = row
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
