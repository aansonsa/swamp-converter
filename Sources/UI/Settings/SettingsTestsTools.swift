import Foundation

extension SettingsTests {
    /// A folder with a fake `ffmpeg` that prints a version line.
    private static func fakeToolFolder(_ fx: TestFixtures) throws -> URL {
        let dir = try fx.makeDirectory("bin")
        let script = dir.appendingPathComponent("ffmpeg")
        try "#!/bin/sh\necho 'ffmpeg version 9.9.9 Copyright (c) test'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return dir
    }

    static func registerToolTests(_ t: SelfTestRegistry) {
        t.register("settings.tools", "every listed tool says what it unlocks, and the install command is shown but never run") {
            for tool in ToolsCatalog.allListed {
                let u = ToolsCatalog.unlocks(tool)
                try expect(!u.en.isEmpty && !u.ru.isEmpty, "\(tool.rawValue) has no description")
                try expect(!tool.isBuiltIn, "\(tool.rawValue) is part of macOS and needs no row")
            }
            try expectEqual(ToolsCatalog.brewCommand(for: .ffmpeg), "brew install ffmpeg")
            try expectEqual(ToolsCatalog.brewCommand(for: .soffice), "brew install --cask libreoffice")
            try expectEqual(ToolsCatalog.brewCommand(for: .ytdlp), "brew install yt-dlp")
            try expect(ToolsCatalog.brewCommand(for: .sips) == nil)
            try expectEqual(Set(Tool.allCases.filter { !$0.isBuiltIn }).subtracting(ToolsCatalog.allListed).map(\.rawValue).sorted(), [], "every optional tool is listed")
            try expectEqual(ToolsPage.shortVersion("ffmpeg version 7.1.1 Copyright (c) 2000"), "7.1.1")
            try expectEqual(ToolsPage.shortVersion("pandoc 3.1.9"), "3.1.9")
            try expectEqual(ToolsPage.shortVersion("odd"), "odd")
        }
        t.register("settings.tools", "found tools show path, source and version; missing ones show as missing; Locate refuses what can't run") {
            let fx = TestFixtures(label: "tools-model"); defer { fx.cleanup() }
            let dir = try fakeToolFolder(fx)
            let locator = ToolLocator(roots: ToolSearchRoots(bundled: .none, userFolder: .none, wellKnown: [], extraDirectories: false, path: .folder(dir.path)))
            let settings = AppSettings(fileURL: fx.url("s.json"), autosave: false)
            let model = ToolsModel(locator: locator, settings: settings)
            let ff = model.row(.ffmpeg)
            try expect(ff.found && ff.path == dir.appendingPathComponent("ffmpeg").path && ff.source == .path)
            try expect(!model.row(.pandoc).found)
            try expectEqual(model.foundCount, 1)
            var waited = 0
            while model.row(.ffmpeg).version == nil && waited < 60 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
            try expectEqual(model.row(.ffmpeg).version, "ffmpeg version 9.9.9 Copyright (c) test")

            let plain = fx.url("notes.txt"); try "x".write(to: plain, atomically: true, encoding: .utf8)
            try expect(model.locate(.pandoc, at: plain) != nil, "a text file can't be a tool")
            try expect(model.locate(.pandoc, at: dir) != nil, "a folder can't be a tool")
            try expect(settings.data.toolPaths.isEmpty, "a refused file is not stored")
            try expect(model.locate(.pandoc, at: dir.appendingPathComponent("ffmpeg")) == nil)
            try expectEqual(settings.data.toolPaths["pandoc"], dir.appendingPathComponent("ffmpeg").path)
            model.clearOverride(.pandoc)
            try expect(settings.data.toolPaths.isEmpty)
        }
        t.register("settings.tools", "a chosen file that stopped working is reported, not silently used") {
            let fx = TestFixtures(label: "tools-override"); defer { fx.cleanup() }
            let locator = ToolLocator(roots: .empty)
            let settings = AppSettings(fileURL: fx.url("s.json"), autosave: false)
            settings.update { $0.toolPaths["pandoc"] = "/nonexistent/pandoc" }
            let model = ToolsModel(locator: locator, settings: settings)
            let row = model.row(.pandoc)
            try expect(!row.found && row.overrideRejected, "the override points nowhere")
        }
    }
}
