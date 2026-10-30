import SwiftUI
import AppKit

// The JavaScript runtime row: YouTube needs deno, node, bun or quickjs for its full quality ladder. The app never installs one; it detects what exists (`JSRuntimeDetector`,
// the same finder the engine uses), says so, and when nothing is found explains why and shows the one command to copy. Detection starts a few short `--version` processes, so it
// runs once, off the main thread, when the row appears.

@MainActor
final class JSRuntimeProbe: ObservableObject {
    enum State: Equatable {
        case checking
        case found(kind: String, path: String, version: String?, meetsMinimum: Bool)
        case missing
    }

    @Published private(set) var state: State = .checking
    private var started = false

    init(state: State = .checking) {
        self.state = state
        started = state != .checking
    }

    /// Looks once (calling again does nothing until `refresh`).
    func start() async {
        guard !started else { return }
        started = true
        await probe()
    }

    func refresh() async {
        state = .checking
        await probe()
    }

    private func probe() async {
        let best = await Task.detached(priority: .utility) { JSRuntimeDetector.detectBest() }.value
        if let best {
            state = .found(kind: best.runtime.kind.rawValue, path: best.runtime.url.path, version: best.runtime.version, meetsMinimum: best.meetsMinimum)
        } else {
            state = .missing
        }
    }
}

struct JSRuntimeStatusView: View {
    @ObservedObject var probe: JSRuntimeProbe
    /// Draw as rows of a grouped form (Settings) instead of a stand-alone block (the install sheet).
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            switch probe.state {
            case .checking:
                HStack(spacing: DS.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text(L("Looking for a JavaScript runtime…", "Поиск JavaScript-движка…")).foregroundStyle(.secondary)
                }
            case .found(let kind, let path, let version, let ok):
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Image(systemName: ok ? StatusTone.success.symbol : StatusTone.warning.symbol)
                        .foregroundStyle(ok ? StatusTone.success.ink : StatusTone.warning.ink)
                        .accessibilityLabel(Text((ok ? StatusTone.success : StatusTone.warning).spokenName.text))
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(ok ? L("Found \(kind)\(version.map { " " + $0 } ?? "")", "Найден \(kind)\(version.map { " " + $0 } ?? "")")
                                : L("\(kind)\(version.map { " " + $0 } ?? "") is too old", "\(kind)\(version.map { " " + $0 } ?? "") слишком старый"))
                        Text(path).font(DS.Typo.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                }
                if !ok, let k = JSRuntime.Kind(rawValue: kind) {
                    Text(JSRuntimeAdvice.tooOld(k).text).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    CommandCopyRow(command: JSRuntimeAdvice.installCommand)
                }
            case .missing:
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Image(systemName: StatusTone.info.symbol).foregroundStyle(StatusTone.info.ink)
                        .accessibilityLabel(Text(StatusTone.info.spokenName.text))
                    Text(L("No JavaScript runtime found", "JavaScript-движок не найден"))
                }
                Text(JSRuntimeAdvice.explanation.text).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                CommandCopyRow(command: JSRuntimeAdvice.installCommand)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await probe.start() }
        .accessibilityElement(children: .contain)
    }
}

/// A command in monospace with a Copy button. The app never runs it.
struct CommandCopyRow: View {
    var command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Text(command).font(DS.Typo.mono).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            } label: {
                Label(copied ? L("Copied", "Скопировано") : L("Copy", "Копировать"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .secondaryButtonLook()
            .accessibilityLabel(Text(L("Copy the command", "Скопировать команду")))
        }
    }
}
