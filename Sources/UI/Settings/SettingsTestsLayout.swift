import Foundation
import AppKit

extension SettingsTests {
    @MainActor
    private static func makeModel(count: Int, fx: TestFixtures) -> (LayoutEditorModel, WheelLayout) {
        let layout = WheelLayout(fileURL: fx.url("layout.json"), autosave: false)
        let model = LayoutEditorModel(layout: layout, registry: SettingsFixtures.registry(convertCount: count), settings: { SettingsData() })
        model.profile = .image
        return (model, layout)
    }

    static func registerLayoutTests(_ t: SelfTestRegistry) {
        t.register("settings.layout", "moving rows follows List.onMove semantics") {
            let ids = ["a", "b", "c", "d"]
            try expectEqual(LayoutEditorModel.moved(ids, from: IndexSet(integer: 0), to: 3), ["b", "c", "a", "d"])
            try expectEqual(LayoutEditorModel.moved(ids, from: IndexSet(integer: 0), to: 4), ["b", "c", "d", "a"])
            try expectEqual(LayoutEditorModel.moved(ids, from: IndexSet(integer: 2), to: 0), ["c", "a", "b", "d"])
            try expectEqual(LayoutEditorModel.moved(ids, from: IndexSet(integer: 0), to: 2), ["b", "a", "c", "d"])
            try expectEqual(LayoutEditorModel.moved(ids, from: IndexSet([0, 1]), to: 4), ["c", "d", "a", "b"])
            try expectEqual(LayoutEditorModel.moved(ids, from: IndexSet(integer: 1), to: 1), ids, "dropping a row on itself changes nothing")
            try expectEqual(LayoutEditorModel.moved(ids, from: IndexSet(integer: 9), to: 0), ids, "a stale index is ignored")
        }
        t.register("settings.layout", "dropping a row onto another (the scrollable editor's drag) takes that row's place, both directions") {
            let fx = TestFixtures(label: "layout-drop-onto"); defer { fx.cleanup() }
            let (model, _) = makeModel(count: 6, fx: fx)
            model.move(id: "fake.0", onto: "fake.3")
            try expectEqual(model.rows().prefix(4).map(\.id), ["fake.1", "fake.2", "fake.3", "fake.0"], "dragged down: lands just after the target")
            model.move(id: "fake.0", onto: "fake.1")
            try expectEqual(model.rows().prefix(4).map(\.id), ["fake.0", "fake.1", "fake.2", "fake.3"], "dragged up: takes the target's place")
            model.move(id: "fake.2", onto: "fake.2")
            try expectEqual(model.rows().prefix(4).map(\.id), ["fake.0", "fake.1", "fake.2", "fake.3"], "onto itself changes nothing")
            model.move(id: "fake.2", onto: "no.such.row")
            try expectEqual(model.rows().prefix(4).map(\.id), ["fake.0", "fake.1", "fake.2", "fake.3"], "an unknown target is ignored")
        }
        t.register("settings.layout", "rows map onto the 7 + 8 slots of the ring and the rest is Studio only") {
            let fx = TestFixtures(label: "layout-slots"); defer { fx.cleanup() }
            let (model, _) = makeModel(count: 20, fx: fx)
            let rows = model.rows()
            try expectEqual(rows.count, 20)
            try expectEqual(rows.prefix(7).map(\.slot), (0..<7).map { LayoutSlot.ring($0) })
            try expectEqual(rows[7].slot, .more(0)); try expectEqual(rows[14].slot, .more(7))
            try expectEqual(rows[15].slot, .studioOnly); try expectEqual(rows[19].slot, .studioOnly)
            for n in [1, 5, 8] { try expectEqual(LayoutEditorModel.slot(forVisibleIndex: n - 1, of: n), .ring(n - 1), "n = \(n)") }
            try expectEqual(LayoutEditorModel.slot(forVisibleIndex: 7, of: 9), .more(0), "a ninth operation turns slot 8 into More")
            try expectEqual(LayoutEditorModel.slot(forVisibleIndex: 6, of: 9), .ring(6))
            // The editor agrees with what the wheel would draw from the same layout.
            let pages = model.layout.pages(model.layout.arrange(model.operations(wheel: .convert, profile: .image).map { OperationEntry(operation: $0, availability: .available) },
                                                                wheel: .convert, profile: .image))
            try expectEqual(pages.primary.count, 7); try expectEqual(pages.secondary.count, 8); try expectEqual(pages.dropped, 5)
        }
        t.register("settings.layout", "dragging, stepping, hiding, starring and resetting write WheelLayout and the wheel order follows") {
            let fx = TestFixtures(label: "layout-edit"); defer { fx.cleanup() }
            let (model, layout) = makeModel(count: 10, fx: fx)
            try expectEqual(model.rows().first?.id, "fake.0")
            model.move(from: IndexSet(integer: 3), to: 0)
            try expectEqual(model.rows().prefix(4).map(\.id), ["fake.3", "fake.0", "fake.1", "fake.2"])
            model.move(id: "fake.3", .down)
            try expectEqual(model.rows().prefix(3).map(\.id), ["fake.0", "fake.3", "fake.1"])
            model.move(id: "fake.3", .top); try expectEqual(model.rows().first?.id, "fake.3")
            model.move(id: "fake.3", .bottom); try expectEqual(model.rows().last?.id, "fake.3")
            model.move(id: "fake.0", .up); try expectEqual(model.rows().first?.id, "fake.0", "up at the top does nothing")
            try expect(layout.data.order[WheelLayout.key(.convert, .image)] != nil, "the order is stored")

            model.setHidden(true, id: "fake.5")
            let rows = model.rows()
            try expect(rows.last?.id == "fake.5" && rows.last?.hidden == true && rows.last?.slot == .hidden, "hidden rows go last and dimmed")
            try expectEqual(model.visibleCount(wheel: .convert, profile: .image), 9)
            try expect(layout.isHidden("fake.5", wheel: .convert, profile: .image))
            model.setHidden(false, id: "fake.5")
            try expectEqual(model.visibleCount(wheel: .convert, profile: .image), 10)

            model.toggleFavorite(id: "fake.7")
            try expect(model.rows().first { $0.id == "fake.7" }?.favorite == true && layout.isFavorite("fake.7"))
            model.setHidden(true, id: "fake.7")
            try expect(!layout.isFavorite("fake.7"), "hiding un-stars (WheelLayout rule)")

            model.resetCurrent()
            try expectEqual(model.rows().map(\.id), (0..<10).map { "fake.\($0)" }, "reset brings the catalogue order back")
            model.toggleFavorite(id: "fake.2"); model.resetAll()
            try expect(layout.data.favorites.isEmpty && layout.data.order.isEmpty && layout.data.hidden.isEmpty)
        }
        t.register("settings.layout", "the preview ring puts favourites on the axes of an 8-slot ring and keeps More last") {
            let fx = TestFixtures(label: "layout-ring"); defer { fx.cleanup() }
            let (model, _) = makeModel(count: 8, fx: fx)
            model.toggleFavorite(id: "fake.5")
            let ring = model.previewRing()
            try expectEqual(ring.count, 8)
            try expectEqual(ring[0].id, "fake.5", "the first favourite takes the top spot")
            try expect(ring[0].favorite)
            let (big, _) = makeModel(count: 12, fx: fx)
            let ring2 = big.previewRing()
            try expectEqual(ring2.count, 8); try expect(ring2.last?.isMore == true, "More is the last slot")
            try expectEqual(ring2.prefix(7).map(\.id), (0..<7).map { "fake.\($0)" })
        }
        t.register("settings.layout", "wheel and kind selection: the link wheel has one kind, kinds without operations are empty") {
            let fx = TestFixtures(label: "layout-kinds"); defer { fx.cleanup() }
            let (model, _) = makeModel(count: 3, fx: fx)
            try expectEqual(LayoutEditorModel.profiles(for: .link), [.link])
            try expect(!LayoutEditorModel.profiles(for: .convert).contains(.link))
            model.wheel = .link
            try expectEqual(model.profile, .link)
            model.wheel = .tools
            try expect(model.profile != .link, "leaving the link wheel leaves the link kind")
            try expectEqual(model.operations(wheel: .tools, profile: .image).count, 0, "fakes sit on the Convert wheel")
            try expectEqual(model.operations(wheel: .convert, profile: .video).count, 0, "fakes take images only")
            try expectEqual(model.operations(wheel: .convert, profile: .image).count, 3)
            try expectEqual(model.rows(wheel: .convert, profile: .pdf).count, 0)
        }
    }
}
