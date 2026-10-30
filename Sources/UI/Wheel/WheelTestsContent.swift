import Foundation
import AppKit

// What the ring shows: paging, dimmed sectors, the link wheel, the clipboard wheel, the repeat view, the hub summary in both languages, and the benchmark's thresholds.
// Content comes from a private registry so the tests do not move when an engine renames a label.

/// A convert operation that is dimmed with a hint (its tool is "missing").
final class DimmedConvert: PerFileOperation, @unchecked Sendable {
    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        .unavailable(reason: L10n("Needs ffmpeg, which is not installed. See Settings > Tools.", "Нужен ffmpeg, он не установлен. См. Настройки > Инструменты."), missing: [.ffmpeg])
    }
}

extension WheelTests {
    static func item(_ name: String) -> FileItem { FileItem(url: URL(fileURLWithPath: "/tmp/swamp-wheel-tests/\(name)"), isDirectory: false) }

    static func registerContent() {
        let t = SelfTestRegistry.shared
        t.register("wheel", "ring pages: up to eight sectors in one ring; more become seven plus More..., then the rest plus Back") {
            func content(count: Int) -> WheelContent {
                let r = OperationRegistry()
                for i in 0..<count {
                    r.register(PerFileOperation(meta: .make("test.op\(i)", .tools, .image, L10n("Op \(i)", "Оп \(i)"), symbol: "photo", schema: "image.convert", inputs: ["png"])))
                }
                var b = WheelContentBuilder()
                b.registry = r
                return b.fileContent(items: [item("a.png")], wheel: .tools)
            }
            try expect(content(count: 0).isEmpty)
            for n in [1, 3, 8] {
                let c = content(count: n)
                try expectEqual(c.pages.count, 1, "\(n) operations fit one ring"); try expectEqual(c.first.count, n); try expect(!c.hasMore)
            }
            let c9 = content(count: 9)
            try expectEqual(c9.pages.count, 2); try expectEqual(c9.pages[0].count, 8); try expectEqual(c9.pages[0].last?.role, .more)
            try expectEqual(c9.pages[1].last?.role, .back); try expectEqual(c9.pages[1].count, 3, "2 left over + Back")
            let c14 = content(count: 14)
            try expectEqual(c14.pages[0].count, 8); try expectEqual(c14.pages[1].count, 8)
            let ids = (c14.pages[0] + c14.pages[1]).compactMap(\.operationID)
            try expectEqual(ids.count, Set(ids).count, "no operation appears twice"); try expectEqual(ids.count, 14, "and none is lost")
            for sector in c14.pages.flatMap({ $0 }) { try expect(!sector.title.en.isEmpty && !sector.title.ru.isEmpty && !sector.symbol.isEmpty) }
        }
        t.register("wheel", "dimmed sectors keep their place, are not enabled and carry the hint; format tiles are recognised") {
            let r = OperationRegistry()
            r.register(PerFileOperation(meta: .convert("test.to.jpg", .image, to: "jpg", symbol: "photo", schema: "image.convert", inputs: ["png"])))
            r.register(DimmedConvert(meta: .convert("test.to.webp", .image, to: "webp", symbol: "photo", schema: "image.convert", inputs: ["png"])))
            r.register(PerFileOperation(meta: .make("test.shrink", .convert, .image, L10n("Shrink", "Уменьшить"), symbol: "arrow.down.right.and.arrow.up.left", schema: "image.convert", inputs: ["png"])))
            var b = WheelContentBuilder()
            b.registry = r
            let c = b.fileContent(items: [item("a.png")], wheel: .convert)
            try expectEqual(c.first.map(\.id), ["test.to.jpg", "test.to.webp", "test.shrink"], "catalogue order, dimmed one in place")
            try expect(c.first[0].enabled && !c.first[1].enabled && c.first[2].enabled)
            try expect(c.first[1].hint?.en.contains("ffmpeg") == true && c.first[1].hint?.ru.contains("ffmpeg") == true, "the hint says what to install, in both languages")
            try expect(c.first[0].isFormatTile && !c.first[2].isFormatTile, "JPG is a format tile, Shrink is not")
            try expect(WheelSector.isFormatLabel("TAR.GZ", wheel: .convert) && !WheelSector.isFormatLabel("Compress", wheel: .convert) && !WheelSector.isFormatLabel("JPG", wheel: .tools) && !WheelSector.isFormatLabel("1234567", wheel: .convert) && !WheelSector.isFormatLabel("1234", wheel: .convert))
        }
        t.register("wheel", "link wheel: the download modes, then Choose in Studio..., headed by the page title and host") {
            let r = OperationRegistry()
            r.register(LinkOperation(meta: .link("link.best", L10n("Best for Apple", "Лучшее для Apple"), symbol: "arrow.down.circle", schema: "link")))
            r.register(LinkOperation(meta: .link("link.audio.mp3", L10n("Audio MP3", "Аудио MP3"), symbol: "music.note", schema: "link")))
            var b = WheelContentBuilder()
            b.registry = r
            let link = LinkItem(url: URL(string: "https://www.example.com/watch?v=1")!, title: "From the link")
            let c = b.linkContent(links: [link], pageTitle: "From the tab")
            try expectEqual(c.wheel, .link); try expectEqual(c.first.map(\.id), ["link.best", "link.audio.mp3", "studio"])
            try expectEqual(c.first.last?.role, .studio); try expectEqual(c.linkHost, "example.com"); try expectEqual(c.linkTitle, "From the tab", "the tab title beats the link's own")
            try expectEqual(b.linkContent(links: [link]).linkTitle, "From the link", "without a tab title the link's title is used")
            try expectEqual(b.linkContent(links: [LinkItem(url: URL(string: "https://example.org/x")!)]).linkTitle, nil)
            let blocked = b.linkContent(links: [LinkItem(url: URL(string: "http://localhost/x")!)])
            try expect(blocked.first.map(\.id) == ["studio"], "a link that cannot be downloaded offers no download mode")
            try expect(WheelContentBuilder.studioSector.symbol == "slider.horizontal.3" && WheelContentBuilder.studioSector.title.en == "Choose in Studio…")
        }
        t.register("wheel", "clipboard wheel: the named operations that apply, in that order; the repeat view has one sector or an honest empty message") {
            let r = OperationRegistry()
            for fmt in ["jpg", "webp", "heic"] { r.register(PerFileOperation(meta: .convert("image.to.\(fmt)", .image, to: fmt, symbol: "photo", schema: "image.convert", inputs: ["png"]))) }
            r.register(PerFileOperation(meta: .make("image.compress", .tools, .image, L10n("Compress", "Сжать"), symbol: "arrow.down.right.and.arrow.up.left", schema: "image.convert", inputs: ["png"])))
            var b = WheelContentBuilder()
            b.registry = r
            let shot = item("Screenshot.png")
            let c = b.clipboardContent(item: shot, operationIDs: ["image.compress", "image.to.webp", "image.to.png", "action.copy", "image.to.jpg"])
            try expectEqual(c.first.map(\.id), ["image.compress", "image.to.webp", "image.to.jpg"], "unknown and non-applicable ids are skipped, order kept")
            let last = r.operation(id: "image.to.webp")
            let rep = b.repeatContent(last: last, wheel: .convert)
            try expect(rep.isRepeatView && rep.first.count == 1 && rep.first[0].role == .repeatLast && rep.first[0].enabled)
            let none = b.repeatContent(last: nil, wheel: .tools)
            try expect(none.isRepeatView && none.isEmpty && none.emptyMessage?.en == "Last action doesn’t fit")
            try expect(b.fileContent(items: [], wheel: .convert).isEmpty, "no files, no ring")
        }
        t.register("wheel", "hub summary: one name, counted kinds, three kinds and an ellipsis, Russian plurals") {
            Loc.shared.set(.english)
            defer { Loc.shared.set(.english) }
            try expectEqual(WheelInputSummary.make(files: [item("holiday.jpg")]).text, "holiday.jpg")
            let images = (0..<12).map { item("i\($0).png") }
            try expectEqual(WheelInputSummary.make(files: images).text, "12 images")
            let mixed = (0..<9).map { item("i\($0).png") } + [item("a.pdf"), item("b.pdf"), item("c.mp4")]
            try expectEqual(WheelInputSummary.make(files: mixed).text, "9 images \u{00B7} 2 PDFs \u{00B7} 1 video")
            let four = [item("a.png"), item("a.pdf"), item("a.mp4"), item("a.mp3")]
            try expect(WheelInputSummary.make(files: four).text.hasSuffix("\u{2026}"), "more than three kinds end in an ellipsis")
            try expectEqual(WheelInputSummary.make(files: [item("a.png"), item("b.png")]).count, 2)
            try expect(WheelInputSummary.make(files: []).text.isEmpty)
            Loc.shared.set(.russian)
            try expectEqual(WheelInputSummary.make(files: (0..<2).map { item("i\($0).png") }).text, "2 изображения")
            try expectEqual(WheelInputSummary.make(files: (0..<5).map { item("i\($0).png") }).text, "5 изображений")
            try expectEqual(WheelInputSummary.make(files: (0..<21).map { item("i\($0).png") }).text, "21 изображение")
            let links = WheelInputSummary.make(IncomingInput(links: [LinkItem(url: URL(string: "https://a.com/1")!), LinkItem(url: URL(string: "https://b.com/2")!)]))
            try expect(links.isLinks && links.text == "2 ссылки")
        }
        t.register("wheel", "snapshot registrations: the whole matrix is registered with light and dark, Russian and the accessibility variants") {
            WheelModule.registerSnapshots()                                  // idempotent: a name registers once
            let specs = SnapshotRegistry.shared.specs.filter { $0.name.hasPrefix("wheel.") }
            let names = Set(specs.map(\.name))
            for n in ["wheel.three-sectors", "wheel.eight-sectors", "wheel.twelve-sectors", "wheel.link-long-title", "wheel.clipboard", "wheel.disabled-hint", "wheel.page-two", "wheel.a11y",
                      "wheel.waiting", "wheel.repeat", "wheel.permission-explain"] {
                try expect(names.contains(n), "\(n) is registered")
            }
            try expect(!names.contains("wheel.placeholder"), "the placeholder is gone")
            for spec in specs where ["wheel.eight-sectors", "wheel.clipboard", "wheel.link-long-title"].contains(spec.name) {
                try expect(spec.variants.contains { $0.language == .ru } && spec.variants.contains { $0.dark }, "\(spec.name) covers Russian and dark")
            }
            try expect(SnapshotRegistry.shared.specs.first { $0.name == "wheel.a11y" }?.variants.count == SnapshotVariant.accessibility.count)
        }
    }
}
