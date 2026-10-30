import Foundation

// The shelf data side: de-duplication, pruning vanished files, and the shelves.json round trip on disk.

enum ActionsShelfTests {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("actions", "the shelf de-duplicates by path and letter case and reports how many were added") {
            let model = ShelfModel()
            let added = model.add([URL(fileURLWithPath: "/tmp/Shelf/A.png"), URL(fileURLWithPath: "/tmp/shelf/a.PNG"), URL(fileURLWithPath: "/tmp/Shelf/B.png")])
            try expectEqual(added, 2)
            try expectEqual(model.entries.count, 2)
            model.remove(urls: [URL(fileURLWithPath: "/tmp/shelf/b.png")])
            try expectEqual(model.entries.count, 1)
            try expectEqual(model.pruneVanished(exists: { _ in false }), 1)
            try expect(model.isEmpty && model.hadItems)
        }

        t.register("actions", "shelves are saved to disk and read back, vanished files are dropped") {
            let dir = AppPaths.makeTempDirectory(purpose: "actions-shelf-test")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let real = dir.appendingPathComponent("kept.txt")
            try Data("x".utf8).write(to: real)
            let store = ShelfStore(fileURL: dir.appendingPathComponent("shelves.json"))
            let id = UUID()
            store.save([StoredShelf(id: id, paths: [real.path, dir.appendingPathComponent("gone.txt").path], x: 10, y: 20)])
            let loaded = store.load()
            try expectEqual(loaded.count, 1)
            try expectEqual(loaded[0].id, id)
            try expectEqual(loaded[0].x, 10)
            let pruned = try unwrap(loaded[0].pruned(exists: { FileManager.default.fileExists(atPath: $0) }))
            try expectEqual(pruned.paths, [real.path])
            try expect(StoredShelf(id: id, paths: ["/nonexistent/zzz"]).pruned(exists: { FileManager.default.fileExists(atPath: $0) }) == nil)
            store.save([])
            try expect(!FileManager.default.fileExists(atPath: store.fileURL.path), "saving no shelves removes the file")
            try expect(store.load().isEmpty)
        }

        t.register("actions", "shelf placement stays on screen and steps away from an occupied spot") {
            let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
            let size = ShelfPlacement.size(rows: 3)
            let first = ShelfPlacement.frame(near: NSPoint(x: 400, y: 300), size: size, visible: visible, occupied: [])
            let second = ShelfPlacement.frame(near: NSPoint(x: 400, y: 300), size: size, visible: visible, occupied: [first])
            try expect(first != second)
            try expect(visible.contains(first) && visible.contains(second))
            let corner = ShelfPlacement.frame(near: NSPoint(x: 990, y: 790), size: size, visible: visible, occupied: [])
            try expect(visible.contains(corner))
        }
    }
}
