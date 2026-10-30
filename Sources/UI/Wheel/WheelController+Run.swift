import Foundation
import AppKit
import Combine

// What a chosen sector starts. Files go through `QuickRun.shared.run(...)` (the one quick path), links through `DownloadService` (consent, tool check, duplicate guard),
// "Customise..." opens the Studio. The wheel is already closed when any of this runs.

/// What the run needs from the session that is about to be reset by `close()`.
struct WheelRunContext {
    var isLink = false
    /// Clipboard wheel: put the finished result back on the clipboard ("Paste as file").
    var pasteBack = false
    var wheel: WheelKind = .convert
}

extension WheelController {
    func makeRunContext(model: WheelModel) -> WheelRunContext {
        WheelRunContext(isLink: session.isLink, pasteBack: session.clipboardItem != nil && model.pasteBack, wheel: session.wheel)
    }

    func execute(_ action: WheelAction, context: WheelRunContext, input: IncomingInput) async {
        switch action {
        case .run(let sector): await run(sector, context: context, input: input)
        case .customise(let sector): openStudio(for: sector, input: input)
        case .customiseLast(let sector): openStudio(for: sector, input: input)
        case .switchPage, .cancel: break
        }
    }

    // MARK: Run

    func run(_ sector: WheelSector, context: WheelRunContext, input: IncomingInput) async {
        Haptics.tick(.generic, enabled: AppSettings.shared.data.hapticsEnabled && !offscreenForTesting)
        switch sector.role {
        case .operation(let id):
            if context.isLink || (input.files.isEmpty && !input.links.isEmpty) {
                await startDownloads(operationID: id, links: input.links, origin: input.origin)
            } else {
                await startFiles(operationID: id, input: input, pasteBack: context.pasteBack)
            }
        case .repeatLast:
            let outcome = await QuickRun.shared.repeatLast(items: input.files, origin: input.origin)
            report(outcome, pasteBack: context.pasteBack)
        case .studio:
            openStudio(for: sector, input: input)
        case .more, .back:
            break
        }
    }

    private func startFiles(operationID id: String, input: IncomingInput, pasteBack: Bool) async {
        guard !input.files.isEmpty else {
            toast(L10n("Nothing was received. Drag the files again.", "Ничего не получено. Перетащите файлы ещё раз."), severity: .warning, symbol: "exclamationmark.triangle")
            return
        }
        guard QuickRun.shared.registry.operation(id: id) != nil else {
            toast(L10n("This action is not available.", "Это действие недоступно."), severity: .warning, symbol: "exclamationmark.triangle")
            return
        }
        let outcome = await QuickRun.shared.run(operationID: id, items: input.files, origin: input.origin)
        report(outcome, pasteBack: pasteBack)
    }

    /// Link wheel: the sector's operation id names the download mode; `DownloadService` asks for consent / the tool and shows its own toast.
    private func startDownloads(operationID id: String, links: [LinkItem], origin: JobOrigin) async {
        let mode = DownloadMode.allCases.first { DownloadCatalog.operationID(for: $0) == id }
        for link in links {
            let outcome = await DownloadService.shared.start(link: link, mode: mode, origin: origin)
            if case .failed(let message) = outcome { toast(L10n(message, message), severity: .error, symbol: "exclamationmark.octagon") }
        }
    }

    private func report(_ outcome: QuickRun.Outcome, pasteBack: Bool) {
        switch outcome {
        case .started(let job):
            if pasteBack { watchForPasteBack(job) }
        case .notApplicable:
            toast(L10n("This action does not apply to these files.", "Это действие не подходит к этим файлам."), severity: .warning, symbol: "exclamationmark.triangle")
        case .performedAction, .cancelled, .unavailable, .failed:
            break                                                      // QuickRun already told the person (toast) where there was something to tell
        }
    }

    // MARK: Studio

    func openStudio(for sector: WheelSector?, input: IncomingInput) {
        StudioWindowController.shared.show(input: input, target: nil, operationID: sector?.operationID)
    }

    // MARK: Paste as file

    /// Clipboard wheel with "paste back": when the job finishes, its result goes onto the clipboard as a file (and as picture bytes for pictures).
    private func watchForPasteBack(_ job: Job) {
        let id = job.id
        jobWatchers[id] = job.$state.sink { [weak self] state in
            guard state.isFinished else { return }
            Task { @MainActor in
                guard let self else { return }
                self.jobWatchers[id] = nil
                if state == .done, ClipboardSource.put(results: job.outputs) {
                    self.toast(L10n("Result copied. Paste it with Command-V.", "Результат скопирован. Вставьте его через Command-V."), symbol: "doc.on.clipboard")
                }
            }
        }
    }
}
