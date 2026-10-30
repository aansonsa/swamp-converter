import Foundation

// Real copy / move into a temporary folder through the planner and the runner, with name clashes resolved by the conflict planner (no panels, no real Trash).

enum ActionsTransferTests {
    private static func makeSandbox() throws -> URL {
        let root = AppPaths.makeTempDirectory(purpose: "actions-transfer-test")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }

    /// The live file system, except that "Trash" moves the item into a folder inside the sandbox.
    private static func sandboxFS(trash: URL) -> TransferFS {
        var fs = TransferFS.live
        fs.trash = { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        return fs
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("actions", "copy into a folder keeps the original and writes identical bytes") {
            let root = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let src = root.appendingPathComponent("src/report.txt"), dest = root.appendingPathComponent("dest")
            try write("hello swamp", to: src)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let fs = sandboxFS(trash: root.appendingPathComponent("trash"))
            let plan = try await TransferPlanner.plan(mode: .copy, items: [FileItem(url: src, isDirectory: false)], folder: dest, resolver: { _ in ConflictAnswer(choice: .stop) }, fs: fs)
            try expectEqual(plan.steps.count, 1)
            try expectEqual(plan.steps[0].kind, .plain)
            let outcome = try await TransferRunner.runAsync(plan: plan.measured(), fs: fs)
            try expectEqual(outcome.outputs.count, 1)
            try expectEqual(read(dest.appendingPathComponent("report.txt")), "hello swamp")
            try expect(FileManager.default.fileExists(atPath: src.path), "the original must stay after a copy")
        }

        t.register("actions", "move removes the original and name clashes get a free (2) name via the planner") {
            let root = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let src = root.appendingPathComponent("src/a.txt"), dest = root.appendingPathComponent("dest")
            try write("new", to: src)
            try write("old", to: dest.appendingPathComponent("a.txt"))
            let fs = sandboxFS(trash: root.appendingPathComponent("trash"))
            var asked = 0
            let plan = try await TransferPlanner.plan(mode: .move, items: [FileItem(url: src, isDirectory: false)], folder: dest,
                                                      resolver: { info in asked += 1; try? expectEqual(info.name, "a.txt"); return ConflictAnswer(choice: .keepBoth) }, fs: fs)
            try expectEqual(asked, 1)
            try expectEqual(plan.steps.first?.kind, .keepBoth)
            try expectEqual(plan.steps.first?.destination, dest.appendingPathComponent("a (2).txt").path)
            _ = try await TransferRunner.runAsync(plan: plan.measured(), fs: fs)
            try expectEqual(read(dest.appendingPathComponent("a.txt")), "old")
            try expectEqual(read(dest.appendingPathComponent("a (2).txt")), "new")
            try expect(!FileManager.default.fileExists(atPath: src.path), "the original must be gone after a move")
        }

        t.register("actions", "replace sends the old item to the trash seam, skip and same-path leave things alone") {
            let root = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let dest = root.appendingPathComponent("dest"), trash = root.appendingPathComponent("trash")
            let a = root.appendingPathComponent("src/a.txt"), b = root.appendingPathComponent("src/b.txt")
            try write("A-new", to: a); try write("B-new", to: b)
            try write("A-old", to: dest.appendingPathComponent("a.txt")); try write("B-old", to: dest.appendingPathComponent("b.txt"))
            let fs = sandboxFS(trash: trash)
            let plan = try await TransferPlanner.plan(mode: .copy, items: [FileItem(url: a, isDirectory: false), FileItem(url: b, isDirectory: false)], folder: dest,
                                                      resolver: { info in ConflictAnswer(choice: info.name == "a.txt" ? .replace : .skip) }, fs: fs)
            try expectEqual(plan.steps.count, 1)
            try expectEqual(plan.skippedByChoice, [b.path])
            _ = try await TransferRunner.runAsync(plan: plan.measured(), fs: fs)
            try expectEqual(read(dest.appendingPathComponent("a.txt")), "A-new")
            try expectEqual(read(dest.appendingPathComponent("b.txt")), "B-old")
            try expectEqual(read(trash.appendingPathComponent("a.txt")), "A-old")
            // An item already in the target folder is skipped without asking anything.
            let same = try await TransferPlanner.plan(mode: .copy, items: [FileItem(url: dest.appendingPathComponent("b.txt"), isDirectory: false)], folder: dest,
                                                      resolver: { _ in ConflictAnswer(choice: .stop) }, fs: fs)
            try expect(same.isEmpty && same.skippedSamePath.count == 1 && !same.stopped)
        }

        t.register("actions", "a folder cannot be copied into itself") {
            let root = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = root.appendingPathComponent("f")
            try write("x", to: folder.appendingPathComponent("inner/x.txt"))
            do {
                _ = try await TransferPlanner.plan(mode: .copy, items: [FileItem(url: folder, isDirectory: true)], folder: folder.appendingPathComponent("inner"),
                                                   resolver: { _ in ConflictAnswer(choice: .stop) })
                throw TestFailure(message: "planning a copy into itself must throw", file: #fileID, line: #line)
            } catch is ConversionError {}
        }
    }
}
