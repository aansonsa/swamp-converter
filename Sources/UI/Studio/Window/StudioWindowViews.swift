import SwiftUI
import AppKit

/// Root of one Studio window: `NavigationSplitView { StudioSidebar } content: { centre } detail: { OptionFormView }`, toolbar via `.toolbar` (max 3 groups, every item also a menu command:
/// Cmd-O add files, Cmd-Return start, Cmd-Shift-Return add to queue, Cmd-F search options, Cmd-1...7 inspector pages, Cmd-Option-P preset menu, Space preview play, J K L scrub, I O set In / Out).
/// Glass lives on the control layer only (the toolbar and its popovers); the columns sit on system backgrounds.
struct StudioRootView: View {
    @StateObject private var model: StudioWindowModel

    /// A window around a session (the controller passes its own model through `init(model:)`).
    init(session: StudioSession) { _model = StateObject(wrappedValue: StudioWindowModel(session: session)) }
    init(model: StudioWindowModel) { _model = StateObject(wrappedValue: model) }

    var body: some View { StudioWindowContent(model: model) }
}

/// The three columns, the toolbar and the drop target. Separate from `StudioRootView` so snapshots and tests can hand it a model directly.
struct StudioWindowContent: View {
    @ObservedObject var model: StudioWindowModel
    /// Snapshots replace the inspector with a stand-in when the session has no schema (the form itself is studio-core's and has its own snapshots).
    var inspector: (() -> AnyView)?
    @State private var columns = NavigationSplitViewVisibility.all
    /// True while the sidebar is folded because the window is narrow (not because the person hid it): it comes back when the window is wide again.
    @State private var autoCollapsed = false
    /// Narrower than this, the three columns do not fit and the sidebar folds away.
    static let sidebarCollapseWidth: CGFloat = 1000

    init(model: StudioWindowModel, inspector: (() -> AnyView)? = nil) { self.model = model; self.inspector = inspector }

    private func adapt(to width: CGFloat) {
        if width < Self.sidebarCollapseWidth {
            if columns == .all { columns = .doubleColumn; autoCollapsed = true }
        } else if autoCollapsed {
            columns = .all; autoCollapsed = false
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            StudioSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
        } content: {
            StudioCentreView(model: model)
                .navigationSplitViewColumnWidth(min: 380, ideal: 600)
        } detail: {
            StudioInspectorColumn(model: model, inspector: inspector)
                .navigationSplitViewColumnWidth(min: 300, ideal: 344, max: 360)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { adapt(to: $0) }
        .navigationTitle(StudioWindowController.windowTitle)
        .toolbar { StudioToolbar(model: model) }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $model.isDropTargeted) { providers in
            model.ingest(providers: providers)
            return true
        }
        .overlay { if model.isDropTargeted { StudioDropOverlay() } }
        .sheet(isPresented: Binding(get: { model.linkDraft != nil }, set: { if !$0 { model.linkDraft = nil } })) { StudioLinkSheet(model: model) }
        .frame(minWidth: StudioWindowController.minimumSize.width, minHeight: StudioWindowController.minimumSize.height)
    }
}

// MARK: - Toolbar

/// Three groups: [Add Files], the preset pop-up with its Modified badge, and [Preview] [Add to Queue] [Start]. Start is the one prominent call to action and becomes
/// "Start Queue" while a queue is waiting. Every item is also a command of the Studio menu.
struct StudioToolbar: ToolbarContent {
    @ObservedObject var model: StudioWindowModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.perform(.addFiles) } label: {
                Label(L("Add Files", "Добавить файлы"), systemImage: StudioCommands.symbol(.addFiles))
            }
            .help(L("Add files or folders (Command-O)", "Добавить файлы или папки (Command-O)"))
        }
        ToolbarItem(placement: .principal) {
            PresetBar(session: model.session)
                .accessibilityIdentifier(StudioIdentifiers.presetBar)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.perform(.preview) } label: {
                Label(L("Preview", "Просмотр"), systemImage: StudioCommands.symbol(.preview))
            }
            .disabled(!model.isEnabled(.preview))
            .help(L("Refresh the preview (Command-R)", "Обновить просмотр (Command-R)"))
            Button { model.perform(.addToQueue) } label: {
                Label(L("Add to Queue", "В очередь"), systemImage: StudioCommands.symbol(.addToQueue))
            }
            .disabled(!model.isEnabled(.addToQueue))
            .help(L("Add to the queue without starting (Shift-Command-Return)", "Добавить в очередь без запуска (Shift-Command-Return)"))
            StudioStartButton(model: model)
        }
    }
}

/// The one prominent button of the window. While it is dimmed its tooltip says why (no file yet, a value out of range, a tool missing...).
struct StudioStartButton: View {
    @ObservedObject var model: StudioWindowModel

    private func helpText(_ ctx: StudioCommandContext) -> String {
        if !model.isEnabled(.start), let reason = model.session.startBlockReason { return reason.text }
        return StudioCommands.startRunsQueue(ctx) ? L("Start the queue (Command-Return)", "Запустить очередь (Command-Return)") : L("Start now (Command-Return)", "Начать сейчас (Command-Return)")
    }

    var body: some View {
        let ctx = model.commandContext()
        Button { model.perform(.start) } label: {
            Label(StudioCommands.startTitle(ctx).text, systemImage: StudioCommands.startRunsQueue(ctx) ? "play.square.stack.fill" : "play.fill")
        }
        .buttonStyle(.brandProminent)
        .disabled(!model.isEnabled(.start))
        .help(helpText(ctx))
        .accessibilityLabel(Text(StudioCommands.startTitle(ctx).text))
    }
}

// MARK: - Inspector column

/// The trailing column: the target picker on top, then the generic option form of studio-core.
struct StudioInspectorColumn: View {
    @ObservedObject var model: StudioWindowModel
    var inspector: (() -> AnyView)?

    var body: some View {
        VStack(spacing: 0) {
            if !model.state.targets.isEmpty {
                StudioTargetPicker(model: model)
                Divider()
            }
            if let inspector {
                inspector()
            } else if model.state.hasSchema {
                OptionFormView(session: model.session)
            } else {
                EmptyStateView(symbol: "slider.horizontal.3", title: L("Options appear here", "Здесь появятся параметры"),
                               message: model.state.isEmpty ? L("Add a file to see everything you can set for it.", "Добавьте файл, чтобы увидеть все параметры для него.")
                                                            : L("Choose what to make from the file above.", "Выберите, что сделать из файла."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.Surface.window)
    }
}

/// "Make: Video": the target (format family) of the conversion. Targets that cannot run on this Mac stay in the list, dimmed, with the reason.
struct StudioTargetPicker: View {
    @ObservedObject var model: StudioWindowModel

    private var current: StudioTargetRow? { model.state.targets.first { $0.id == model.state.targetID } }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Text(L("Make", "Результат")).font(DS.Typo.callout).foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.sm)
            if model.state.targets.count > 1 {
                Menu {
                    ForEach(StudioTargetPicker.grouped(model.state.targets), id: \.family) { group in
                        Section(group.family.title.text) {
                            ForEach(group.rows) { row in
                                Button { model.session.selectTarget(row.id) } label: {
                                    Label(row.title, systemImage: row.id == model.state.targetID ? "checkmark" : row.symbol)
                                }
                                .disabled(row.unavailableReason != nil)
                            }
                        }
                    }
                } label: {
                    Label(current?.title ?? L("Choose…", "Выбрать…"), systemImage: current?.symbol ?? "square.dashed")
                }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityLabel(Text(L("Result type", "Тип результата")))
            } else {
                Label(current?.title ?? model.state.targets.first?.title ?? "", systemImage: current?.symbol ?? "square.dashed").font(DS.Typo.callout)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
    }

    struct Group { var family: OperationFamily; var rows: [StudioTargetRow] }

    /// Targets grouped by family in first-seen order.
    static func grouped(_ rows: [StudioTargetRow]) -> [Group] {
        var order: [OperationFamily] = [], map: [OperationFamily: [StudioTargetRow]] = [:]
        for r in rows { if map[r.family] == nil { order.append(r.family) }; map[r.family, default: []].append(r) }
        return order.map { Group(family: $0, rows: map[$0] ?? []) }
    }
}

// MARK: - Drop overlay and empty state

/// While files are dragged over the window: a quiet tinted outline, no fill. The Swamp Pink ring is the signature of "drop here".
struct StudioDropOverlay: View {
    @Environment(\.a11y) private var a11y

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .strokeBorder(Brand.pink, lineWidth: a11y.increaseContrast ? 3 : 2)
            .padding(DS.Space.sm)
            .background(Brand.pink.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
    }
}

/// The centre column of an empty Studio: the wordmark, one calm sentence and the two ways in.
struct StudioEmptyState: View {
    @ObservedObject var model: StudioWindowModel

    var body: some View {
        EmptyStateView(symbol: "square.and.arrow.down", title: L("Drop files here", "Перетащите файлы сюда"),
                       message: L("Add files, a folder or a link. Then set anything about the result, or just press Start.",
                                  "Добавьте файлы, папку или ссылку. Затем настройте любую мелочь результата или просто нажмите «Начать»."),
                       showsWordmark: true) {
            HStack(spacing: DS.Space.md) {
                Button { model.perform(.addFiles) } label: { Label(StudioCommands.title(.addFiles).text, systemImage: "plus") }
                    .secondaryButtonLook()
                Button { model.perform(.pasteLink) } label: { Label(StudioCommands.title(.pasteLink).text, systemImage: "link") }
                    .secondaryButtonLook()
            }
        }
    }
}

/// A calm one-line note with a dismiss button (never a modal alert).
struct StudioNoticeBar: View {
    var text: String
    var onDismiss: () -> Void

    var body: some View {
        InlineMessage(text, tone: .info, onDismiss: onDismiss)
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.sm)
    }
}
