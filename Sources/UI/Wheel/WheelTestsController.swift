import Foundation
import AppKit

// The window and the lifecycle, offscreen: the panel's properties, the drop view's coordinates, a click-mode wheel, a drag-mode wheel driven by watcher events, the drop path
// with a stubbed drag, the clipboard discard, the hotkeys with stubbed readers, and the download shortcut. Nothing here touches the real desktop: `offscreenForTesting` puts the panel
// 6000 pt off every display, takes no focus and plays no haptic.

/// A drag the tests can drop: a private pasteboard and a position.
final class StubDraggingInfo: NSObject, NSDraggingInfo {
    var draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard, location: NSPoint = .zero) { draggingPasteboard = pasteboard; draggingLocation = location }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

/// A convert operation that records what it was asked to do and produces nothing.
final class RecordingConvert: PerFileOperation, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        lock.withLock { _calls.append(item.name) }
        return []
    }
}

extension WheelTests {
    /// A private registry with four conversions that apply to PNG files.
    static func fakeRegistry() -> (registry: OperationRegistry, ops: [RecordingConvert]) {
        let r = OperationRegistry()
        let ops = ["jpg", "webp", "tiff", "gif"].map { fmt in
            RecordingConvert(meta: .convert("test.to.\(fmt)", .image, to: fmt, symbol: "photo", schema: "image.convert", inputs: ["png", "jpg", "gif"]))
        }
        r.register(ops)
        return (r, ops)
    }

    @MainActor
    static func testController(registry: OperationRegistry) -> WheelController {
        let c = WheelController()
        c.offscreenForTesting = true
        var b = WheelContentBuilder()
        b.registry = registry
        c.contentBuilder = { b }
        return c
    }

    @MainActor
    static func privatePasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("app.swampconverter.test.\(UUID().uuidString)")) }

    /// Messages posted after the one with `id` (`MessageCenter.recent` is capped, so counts are not comparable).
    @MainActor
    static func lastMessageID() -> UUID? { MessageCenter.shared.recent.last?.id }

    @MainActor
    static func messages(after id: UUID?) -> [UserMessage] {
        let all = MessageCenter.shared.recent
        guard let id, let i = all.firstIndex(where: { $0.id == id }) else { return all }
        return Array(all[(i + 1)...])
    }

    @MainActor
    static func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    static func registerController() {
        let t = SelfTestRegistry.shared
        t.register("wheel", "panel: borderless, non-activating, above menus, on every Space, transparent and shadowless; key only in click mode; registered for every drag type") {
            let p = WheelPanel()
            try expect(p.styleMask.contains(.borderless) && p.styleMask.contains(.nonactivatingPanel), "style mask")
            try expectEqual(p.level, .popUpMenu)
            for b: NSWindow.CollectionBehavior in [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] { try expect(p.collectionBehavior.contains(b), "behaviour \(b)") }
            try expect(!p.hasShadow && !p.isOpaque && p.backgroundColor == .clear && !p.isReleasedWhenClosed && p.isFloatingPanel && !p.hidesOnDeactivate, "transparent floating panel")
            try expect(!p.canBecomeKey && !p.canBecomeMain, "drag mode never takes the keyboard")
            p.allowsKey = true
            try expect(p.canBecomeKey && !p.canBecomeMain, "click mode may become key")
            let v = WheelDropView()
            p.contentView = v
            let wanted: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            for type in wanted { try expect(v.registeredDraggedTypes.contains(type), "registered for \(type.rawValue)") }
            p.setFrame(NSRect(x: -6000, y: -6000, width: 408, height: 408), display: false)
            let centre = v.wheelPoint(fromWindow: NSPoint(x: 204, y: 204))
            try expect(abs(centre.x) < 0.001 && abs(centre.y) < 0.001, "the window centre is the wheel centre")
            let top = v.wheelPoint(fromWindow: NSPoint(x: 204, y: 400))
            try expect(abs(top.x) < 0.001 && top.y > 190, "up is up (y grows upwards)")
            try expect(v.hitTest(NSPoint(x: 100, y: 100)) === v, "the drop view takes the pointer; the hosted ring is click-through")
        }
        t.register("wheel", "click mode: opens offscreen on the first useful wheel, owns its monitors, answers the keyboard and closes cleanly (twice)") {
            let fx = TestFixtures(label: "wheel-click")
            defer { fx.cleanup() }
            let png = FileItem(url: try fx.png("a.png"))
            let (registry, _) = fakeRegistry()
            let c = testController(registry: registry)
            try expectEqual(c.activeMonitorCount, 0, "idle: no monitors")
            c.present(IncomingInput(files: [png], origin: .hotkey), anchor: NSPoint(x: 800, y: 500))
            try expect(c.isVisible); try expectEqual(c.session.mode, .click); try expectEqual(c.session.wheel, .convert)
            try expectEqual(c.model?.sectors.count, 4); try expectEqual(c.model?.highlight, 0, "click mode starts on the first sector")
            try expectEqual(c.panel?.frame.origin.x, -6000); try expect(c.panel?.frame.size.width == c.model?.geometry.panelSide)
            try expectEqual(c.activeMonitorCount, 4, "mouse-down (global + local), global Esc, local keys")
            c.apply(.next); try expectEqual(c.model?.highlight, 1)
            c.apply(.previous); c.apply(.previous); try expectEqual(c.model?.highlight, 3, "wraps")
            c.apply(.tab(backwards: false)); try expectEqual(c.session.wheel, .tools, "no second page: Tab turns to the next wheel")
            c.apply(.repeatView); try expect(c.session.isRepeat && c.model?.content.isRepeatView == true)
            c.apply(.repeatView); try expect(!c.session.isRepeat)
            c.apply(.close)
            try expect(!c.isVisible && c.model == nil && c.panel?.isVisible == false); try expectEqual(c.activeMonitorCount, 0, "no monitor outlives the wheel")
            c.close(); c.close()
            try expect(!c.isVisible, "close is idempotent")
            c.present(IncomingInput(files: [png]), wheel: .tools)
            try expectEqual(c.session.wheel, .tools, "an explicit wheel is honoured")
            c.present(IncomingInput(files: [png]), wheel: .convert)
            try expectEqual(c.activeMonitorCount, 4, "a second present replaces the first without leaking its monitors")
            c.close()
            Loc.shared.set(.english)
            let before = lastMessageID()
            c.present(IncomingInput())
            let said = messages(after: before)
            try expect(!c.isVisible && said.count == 1 && said[0].text.contains("Nothing to convert"), "an empty input gives a calm message")
        }
        t.register("wheel", "drag mode: watcher events open, switch, repeat and close the wheel; a finished drag closes it after the grace period unless the drag moves again") {
            let fx = TestFixtures(label: "wheel-drag")
            defer { fx.cleanup() }
            let png = try fx.png("a.png")
            let pb = privatePasteboard()
            pb.clearContents(); pb.writeObjects([png as NSURL])
            let (registry, _) = fakeRegistry()
            let c = testController(registry: registry)
            c.dragPasteboard = { pb }
            c.handleDragEvent(.dragBegan)
            try expect(c.panel != nil && !c.isVisible, "the window is prepared at drag start, shown only on a gesture")
            c.handleDragEvent(.modifierTap(.convert))
            try expect(c.isVisible); try expectEqual(c.session.mode, .drag); try expectEqual(c.model?.presentation, .drag)
            try expectEqual(c.model?.highlight, -1, "the cursor starts in the hub: nothing is highlighted"); try expectEqual(c.activeMonitorCount, 2)
            try expectEqual(c.panel?.allowsKey, false, "a drag wheel never takes the keyboard")
            c.handleDragEvent(.modifierTap(.tools)); try expectEqual(c.session.wheel, .tools)
            c.handleDragEvent(.modifierTap(.tools)); try expect(c.session.isRepeat, "the same key again shows the repeat view")
            c.handleDragEvent(.modifierTap(.convert)); try expect(!c.session.isRepeat && c.session.wheel == .convert, "another key switches wheel and leaves the repeat view")
            c.handleDragEvent(.escape); try expect(!c.isVisible, "Esc closes")
            c.handleDragEvent(.shake); try expect(c.isVisible && c.session.wheel == .convert, "shake opens the first wheel")
            c.handleDragEvent(.shake); try expectEqual(c.activeMonitorCount, 2, "a second shake changes nothing")
            c.handleDragEvent(.dragEnded)
            c.dragMoved()
            try? await Task.sleep(nanoseconds: 700_000_000)
            try expect(c.isVisible, "a drag that moved again cancels the grace period")
            c.handleDragEvent(.dragEnded)
            try? await Task.sleep(nanoseconds: 700_000_000)
            try expect(!c.isVisible && c.activeMonitorCount == 0, "the finished drag closes the wheel after the grace period")
            // Nothing readable yet: the wheel says so; a link drag opens the link wheel.
            let empty = privatePasteboard(); empty.clearContents()
            c.dragPasteboard = { empty }
            c.handleDragEvent(.shake)
            try expect(c.model?.waitingForItems == true && c.model?.hubContent().detail == L("Drag a file here", "Перетащите файл сюда"))
            c.close()
            let web = privatePasteboard(); web.clearContents(); web.writeObjects([URL(string: "https://example.com/video")! as NSURL])
            c.dragPasteboard = { web }
            c.handleDragEvent(.modifierTap(.tools))
            try expect(c.session.isLink && c.model?.isLinkWheel == true, "a dragged web address opens the link wheel whatever key was tapped")
            c.handleDragEvent(.modifierTap(.convert)); try expect(c.session.wheel == .link, "the link wheel does not switch")
            c.close()
        }
        t.register("wheel", "drop: a drop on a sector materialises the files, runs the operation through QuickRun and closes; the hub, a dimmed sector and an instant drop do not run") {
            let fx = TestFixtures(label: "wheel-drop")
            defer { fx.cleanup() }
            let png = try fx.png("photo.png")
            let pb = privatePasteboard()
            pb.clearContents(); pb.writeObjects([png as NSURL])
            let (registry, ops) = fakeRegistry()
            let runner = JobRunner(persistence: false, registry: registry, settings: AppSettings.shared)
            let savedRegistry = QuickRun.shared.registry, savedProvider = QuickRun.shared.runnerProvider
            QuickRun.shared.registry = registry
            QuickRun.shared.runnerProvider = { runner }
            defer { QuickRun.shared.registry = savedRegistry; QuickRun.shared.runnerProvider = savedProvider }
            let c = testController(registry: registry)
            c.dragPasteboard = { pb }
            c.handleDragEvent(.shake)
            guard let model = c.model else { throw TestFailure(message: "no wheel", file: #fileID, line: #line) }
            let info = StubDraggingInfo(pasteboard: pb)
            try expect(!c.performDrop(info, at: model.geometry.labelCenter(of: 0)), "a drop the instant the wheel opens is ignored")
            model.openedAt -= 1
            try expect(!c.performDrop(info, at: .zero), "the hub cancels (the files slide back)")
            try expect(!c.performDrop(info, at: CGPoint(x: 900, y: 900)), "outside cancels")
            try expect(c.isVisible && !c.session.consumed, "nothing ran, the wheel waits for draggingEnded")
            try expect(ops.allSatisfy { $0.calls.isEmpty })
            try expect(c.performDrop(info, at: model.geometry.labelCenter(of: 0)), "a drop on the first sector is accepted")
            let ran = await waitUntil { ops.contains { !$0.calls.isEmpty } }
            try expect(ran, "QuickRun started the operation")
            try expectEqual(ops.flatMap(\.calls), ["photo.png"], "with the dropped file")
            let closed = await waitUntil { !c.isVisible }
            try expect(closed && c.activeMonitorCount == 0, "the wheel closed after the drop")
            // draggingEnded after the drop is harmless.
            c.dragFinished(); c.dragFinished()
        }
        t.register("wheel", "clipboard wheel: an image saved for the wheel is deleted when the wheel closes unused and kept once a choice was made") {
            let fx = TestFixtures(label: "wheel-clip")
            defer { fx.cleanup() }
            let source = try Data(contentsOf: try fx.png("clip.png"))
            let folder = try fx.makeDirectory("incoming")
            let (registry, _) = fakeRegistry()
            let c = testController(registry: registry)
            @MainActor func clipboardItem() throws -> FileItem {
                let pb = privatePasteboard()
                pb.clearContents(); pb.setData(source, forType: .png)
                guard case .image(let item) = ClipboardSource.read(pasteboard: pb, incomingFolder: folder) else { throw TestFailure(message: "expected an image", file: #fileID, line: #line) }
                return item
            }
            let unused = try clipboardItem()
            c.presentClipboard(image: unused, anchor: NSPoint(x: 600, y: 400))
            try expect(c.isVisible && c.session.clipboardItem == unused && c.model?.pasteBackAvailable == true && c.model?.reachableWheels.isEmpty == true)
            try expect(FileManager.default.fileExists(atPath: unused.url.path))
            c.close()
            try expect(!FileManager.default.fileExists(atPath: unused.url.path), "closed without a choice: the stray screenshot is gone")
            let used = try clipboardItem()
            c.presentClipboard(image: used)
            c.apply(.togglePasteBack); try expect(c.model?.pasteBack == false)
            c.session.consumed = true
            c.close()
            try expect(FileManager.default.fileExists(atPath: used.url.path), "a chosen screenshot stays")
            let replaced = try clipboardItem()
            c.presentClipboard(image: replaced)
            c.present(IncomingInput(files: [FileItem(url: try fx.png("b.png"))]))
            try expect(!FileManager.default.fileExists(atPath: replaced.url.path), "replacing the wheel counts as closing it")
            c.close()
        }
        t.register("wheel", "menu clipboard wheel: copied files and links open their wheel with the clipboard origin, a screenshot only when offered, an empty clipboard gives a message") {
            Loc.shared.set(.english)
            let fx = TestFixtures(label: "wheel-menuclip")
            defer { fx.cleanup() }
            let png = FileItem(url: try fx.png("m.png"))
            let shot = FileItem(url: try fx.png("shot.png"))
            let (registry, _) = fakeRegistry()
            let c = testController(registry: registry)
            var resolver = WheelHotkeyResolver()
            let anchor = NSPoint(x: 500, y: 400)
            resolver.clipboard = { .files([png]) }
            c.hotkeyResolver = resolver
            c.presentClipboardWheel(anchor: anchor)
            try expect(c.isVisible && c.session.input.origin == .clipboard && c.session.input.files.count == 1, "copied files open the file wheel")
            c.close()
            resolver.clipboard = { .links([LinkItem(url: URL(string: "https://example.com/watch?v=1")!)]) }
            c.hotkeyResolver = resolver
            c.presentClipboardWheel(anchor: anchor)
            try expect(c.isVisible && c.session.isLink && c.session.input.origin == .clipboard, "a copied link opens the link wheel")
            c.close()
            // A picture: offered -> the clipboard wheel; not offered -> the file is discarded (only files this type created are removed, so this one stays) and a message appears.
            let offered = AppSettings.shared.data.offerClipboardImage
            defer { AppSettings.shared.update { $0.offerClipboardImage = offered } }
            resolver.clipboard = { .image(shot) }
            c.hotkeyResolver = resolver
            AppSettings.shared.update { $0.offerClipboardImage = true }
            c.presentClipboardWheel(anchor: anchor)
            try expect(c.isVisible && c.session.clipboardItem == shot, "an offered picture opens the clipboard wheel")
            c.close()
            AppSettings.shared.update { $0.offerClipboardImage = false }
            let before = lastMessageID()
            c.presentClipboardWheel(anchor: anchor)
            try expect(!c.isVisible, "a picture that is not offered opens nothing")
            try expect(messages(after: before).contains { $0.text.hasPrefix("Copy a file") }, "and says what to copy")
            // Empty: a calm message, no wheel.
            resolver.clipboard = { .empty }
            c.hotkeyResolver = resolver
            let beforeEmpty = lastMessageID()
            c.presentClipboardWheel(anchor: anchor)
            try expect(!c.isVisible && messages(after: beforeEmpty).contains { $0.text.hasPrefix("Copy a file") }, "an empty clipboard gives a message")
        }
        t.register("wheel", "hotkey: the wheel opens from stubbed readers, a second press closes it, a permission step asks first, nothing found gives a message") {
            Loc.shared.set(.english)
            let fx = TestFixtures(label: "wheel-hot")
            defer { fx.cleanup() }
            let png = FileItem(url: try fx.png("h.png"))
            let (registry, _) = fakeRegistry()
            let c = testController(registry: registry)
            var front: String? = "com.apple.finder"
            c.frontmostBundleID = { front }
            var resolver = WheelHotkeyResolver()
            resolver.finder = { .files([png]) }
            resolver.clipboard = { .empty }
            resolver.browser = { _ in BrowserLinkResult(link: LinkItem(url: URL(string: "https://example.com/watch?v=7")!), pageTitle: "A video page", source: .activeTab, problem: nil) }
            c.hotkeyResolver = resolver
            await c.presentForHotkey()
            try expect(c.isVisible && c.session.input.origin == .hotkey && c.session.input.files.count == 1 && c.session.mode == .click, "Finder files open the file wheel")
            await c.presentForHotkey()
            try expect(!c.isVisible, "the shortcut again closes the wheel")
            front = BrowserKind.safari.bundleID
            await c.presentForHotkey()
            try expect(c.isVisible && c.session.isLink && c.model?.hubContent().title == "A video page", "a browser in front opens the link wheel headed by the page title")
            c.close()
            var prompts: [WheelPermissionKind] = []
            WheelPermissionPrompt.shared.stub = { prompts.append($0); return .notNow }
            defer { WheelPermissionPrompt.shared.stub = nil }
            resolver.finder = { .needsExplanation }
            c.hotkeyResolver = resolver
            front = "com.apple.finder"
            await c.presentForHotkey()
            try expect(!c.isVisible && prompts == [.explainFinder], "the explanation comes first; \"Not now\" ends it quietly")
            resolver.finder = { .denied }
            c.hotkeyResolver = resolver
            await c.presentForHotkey()
            try expect(!c.isVisible && prompts.last == .deniedFinder, "a refusal offers the way back")
            resolver.finder = { .empty }
            c.hotkeyResolver = resolver
            let before = lastMessageID()
            await c.presentForHotkey()
            try expect(!c.isVisible && messages(after: before).count == 1, "nothing to act on: one calm message")
        }
        t.register("wheel", "download shortcut: the page link goes to the download service without a wheel; failures and missing links become messages") {
            Loc.shared.set(.english)
            let (registry, _) = fakeRegistry()
            let c = testController(registry: registry)
            c.frontmostBundleID = { BrowserKind.safari.bundleID }
            c.confirmsDownloadItself = { false }
            let link = URL(string: "https://example.com/watch?v=9")!
            let started = Box<[LinkItem]>([])
            c.startDownload = { l in
                started.value.append(l)
                return .started(Job(batchID: UUID(), operationID: "link.best", title: l.displayTitle, items: [], links: [l], overrides: OptionValues(), outputRules: nil, origin: .hotkey, mode: .quick, held: false))
            }
            c.linkReader = stubReader(script: .text("\(link.absoluteString)\nA fine video"))
            var before = lastMessageID()
            await c.downloadCurrentPageNow()
            try expectEqual(started.value.count, 1); try expectEqual(started.value.first?.title, "A fine video", "the page title travels with the link")
            try expect(!c.isVisible, "no wheel for the download shortcut")
            var said = messages(after: before)
            try expect(said.count == 1 && said[0].text == "Download started: A fine video", "one confirmation: \(said.map(\.text))")
            c.confirmsDownloadItself = { true }
            before = lastMessageID()
            await c.downloadCurrentPageNow()
            try expect(messages(after: before).isEmpty, "the download-ui module confirms by itself when it is installed")
            c.startDownload = { _ in .failed("The tool is broken.") }
            before = lastMessageID()
            await c.downloadCurrentPageNow()
            said = messages(after: before)
            try expect(said.count == 1 && said[0].text == "The tool is broken." && said[0].severity == .error, "a failure is reported with its reason")
            c.startDownload = { _ in .needsConsent }
            before = lastMessageID()
            await c.downloadCurrentPageNow()
            try expect(messages(after: before).isEmpty, "a declined consent sheet is not an error")
            c.linkReader = stubReader(script: .text("__swamp_no_window__"))
            before = lastMessageID()
            await c.downloadCurrentPageNow()
            said = messages(after: before)
            try expect(said.count == 1 && said[0].text.contains("no open window"), "no window: a calm message")
            started.value = []
            c.linkReader = stubReader(automation: .notDetermined, explained: false)
            WheelPermissionPrompt.shared.stub = { _ in .notNow }
            defer { WheelPermissionPrompt.shared.stub = nil }
            await c.downloadCurrentPageNow()
            try expect(started.value.isEmpty, "the first use shows the explanation and stops when the person says Not now")
        }
        t.register("wheel", "download shortcut in a browser that cannot share its tab (Dia): a clipboard link opens the link wheel instead of downloading blind") {
            Loc.shared.set(.english)
            let (registry, _) = fakeRegistry()
            let c = testController(registry: registry)
            defer { c.close() }
            c.confirmsDownloadItself = { false }
            let started = Box<[LinkItem]>([])
            c.startDownload = { l in started.value.append(l); return .needsConsent }
            c.frontmostBundleID = { BrowserKind.dia.bundleID }
            c.linkReader = stubReader(clipboard: "https://old.example.com/copied-long-ago")
            await c.downloadCurrentPageNow()
            try expect(started.value.isEmpty, "nothing downloads without the person seeing which link it is")
            try expect(c.isVisible, "the link wheel opens to confirm the clipboard link")
            c.close()
            c.frontmostBundleID = { "com.apple.mail" }
            c.linkReader = stubReader(clipboard: "https://example.com/watch?v=7")
            await c.downloadCurrentPageNow()
            try expectEqual(started.value.count, 1, "outside a browser a copied link is the person's plain intent and still downloads at once")
            try expect(!c.isVisible)
        }
        t.register("wheel", "start and stop: the gesture and the hotkeys follow the settings; pausing disarms only the gesture; stopping removes everything") {
            let saved = AppSettings.shared.data
            defer { AppSettings.shared.update { $0 = saved }; HotkeyManager.shared.unregisterAll(); DragWatcher.shared.stop() }
            let c = WheelController()
            c.offscreenForTesting = true
            HotkeyManager.shared.registerOverride = { _ in 0 }
            defer { HotkeyManager.shared.registerOverride = nil }
            c.start()
            try expect(DragWatcher.shared.isRunning && !DragWatcher.shared.isSuspended)
            try expect(HotkeyManager.shared.wheel?.effective != nil && HotkeyManager.shared.download?.effective != nil, "both shortcuts registered")
            try expectEqual(DragWatcher.shared.sampleCount, 0, "idle: nothing sampled")
            c.setPaused(true)
            try expect(c.isPaused && DragWatcher.shared.isSuspended && AppSettings.shared.data.gesturesPaused)
            try expect(HotkeyManager.shared.wheel?.effective != nil, "the hotkey keeps working while the gesture is paused")
            c.setPaused(false)
            try expect(!c.isPaused && !DragWatcher.shared.isSuspended)
            AppSettings.shared.update { $0.hotkey.enabled = false }
            c.applySettings()
            try expect(HotkeyManager.shared.wheel == nil, "a disabled shortcut is unregistered")
            c.stop()
            try expect(!DragWatcher.shared.isRunning && HotkeyManager.shared.wheel == nil && !c.isVisible)
        }
    }
}
