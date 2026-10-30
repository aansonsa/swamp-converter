import Foundation
import AppKit

// Small pure pieces behind the download sheet: the playlist item list ("1,3,5-7"), the three-way mode choice, readiness (consent, tool) and the clipboard reader.

/// "1,3,5-7" from a set of 1-based playlist positions; "" (= the whole list) when everything is selected; nil when nothing is.
enum PlaylistSpec {
    static func make(selection: Set<Int>, indices all: [Int]) -> String? {
        let chosen = selection.intersection(all).sorted()
        if chosen.isEmpty { return nil }
        if chosen.count == all.count { return "" }
        var parts: [String] = []
        var start = chosen[0], prev = chosen[0]
        func flush() { parts.append(start == prev ? "\(start)" : "\(start)-\(prev)") }
        for n in chosen.dropFirst() {
            if n == prev + 1 { prev = n; continue }
            flush(); start = n; prev = n
        }
        flush()
        return parts.joined(separator: ",")
    }
}

/// What the person picks in the segmented control. Audio carries its own format row below; the first three are the Smart module's modes.
enum DownloadModeChoice: String, CaseIterable, Identifiable, Sendable {
    case best, maximum, universal, audio
    var id: String { rawValue }

    init(_ mode: DownloadMode) {
        switch mode {
        case .bestForApple: self = .best
        case .maximum: self = .maximum
        case .universal: self = .universal
        case .audioM4A, .audioMP3: self = .audio
        }
    }

    var title: L10n {
        switch self {
        case .best: return SmartMode.bestForApple.title
        case .maximum: return SmartMode.maximum.title
        case .universal: return SmartMode.universal.title
        case .audio: return L10n("Audio only", "Только звук")
        }
    }

    /// The short explanation under the control (`SmartMode.explanation`: one text for the sheet, the wheel and the Studio).
    var explanation: L10n {
        switch self {
        case .best: return SmartMode.bestForApple.explanation
        case .maximum: return SmartMode.maximum.explanation
        case .universal: return SmartMode.universal.explanation
        case .audio: return L10n("Sound only, in the format chosen below.", "Только звук в выбранном ниже формате.")
        }
    }

    func mode(audioFormat: DownloadAudioFormat) -> DownloadMode {
        switch self {
        case .best: return .bestForApple
        case .maximum: return .maximum
        case .universal: return .universal
        case .audio: return audioFormat == .mp3 ? .audioMP3 : .audioM4A
        }
    }

    /// What follows the download by default for this choice.
    func defaultAfter(settingsAfter: AfterDownload) -> AfterDownload {
        switch self {
        case .best: return settingsAfter
        case .maximum, .audio: return .keepOriginal
        case .universal: return .universal
        }
    }
}

extension DownloadAudioFormat {
    var title: String {
        switch self {
        case .m4a: return "M4A (AAC)"
        case .mp3: return "MP3"
        case .opus: return "Opus"
        case .flac: return "FLAC"
        }
    }
    var detail: L10n {
        switch self {
        case .m4a: return L10n("Plays everywhere on Apple devices", "Играет на всех устройствах Apple")
        case .mp3: return L10n("Plays on anything", "Играет везде")
        case .opus: return L10n("Small files, excellent sound", "Маленькие файлы, отличный звук")
        case .flac: return L10n("Lossless, large files", "Без потерь, большие файлы")
        }
    }
    static let choices: [DownloadAudioFormat] = [.m4a, .mp3, .opus, .flac]
}

enum DownloadReadiness: Equatable, Sendable { case ready, consentDeclined, installDeclined }

/// Consent first, then the tool: the same two questions `DownloadService.start` asks, asked BEFORE an info fetch so no process starts without them.
@MainActor
enum DownloadFlow {
    static func ensureReady(service: DownloadService? = nil) async -> DownloadReadiness {
        let service = service ?? .shared
        if !NetworkGate.settingsProvider().downloader.consentGiven {
            guard let ask = service.hooks.requestConsent, await ask(), NetworkGate.settingsProvider().downloader.consentGiven else { return .consentDeclined }
        }
        if !ToolLocator.shared.has(.ytdlp) {
            guard let offer = service.hooks.offerInstall, await offer(), ToolLocator.shared.has(.ytdlp) else { return .installDeclined }
        }
        return .ready
    }
}

/// Looks at the clipboard ONCE, when the sheet opens. The pasteboard has no change notification and this app uses no timers, so this is never repeated on its own.
@MainActor
enum ClipboardLinkReader {
    /// Test hook: replaces the pasteboard.
    nonisolated(unsafe) static var override: (@MainActor () -> String?)?

    static func currentText() -> String? {
        if let override { return override() }
        let pb = NSPasteboard.general
        if pb.accessBehavior == .alwaysDeny { return nil }
        return pb.string(forType: .string)
    }

    /// The first downloadable link on the clipboard, if any.
    static func link() -> LinkItem? {
        guard let text = currentText(), text.count < 20_000 else { return nil }
        guard var item = LinkParsing.downloadableLinks(in: text, source: "clipboard").first else { return nil }
        item.sourceName = "clipboard"
        return item
    }
}
