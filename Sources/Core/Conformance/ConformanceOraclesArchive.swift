import Foundation

// Oracles for archives. The reference is the system's bsdtar: what the operation wrote is extracted with it and compared member by member (path, bytes,
// permission bits) with the tree that went in. Hostile archives (zip-slip) must be refused without writing outside the destination.

extension ConformanceOracles {
    @MainActor
    private static func extracted(_ archive: URL, _ run: ConformanceRun) throws -> (root: URL, entries: [TreeEntry]) {
        guard let ex = ArchiveFidelity.extractedTree(archive) else { throw run.fail("bsdtar cannot extract \(archive.lastPathComponent)") }
        return ex
    }

    static let archiveRepack = ConformanceOracle(
        id: "archive.repack", priority: 0,
        match: { m in m.wheel == .convert && ["zip", "tar", "tar.gz"].contains(m.targetFormat ?? "") && (m.inputs?.isDisjoint(with: Formats.archiveInputs) == false) },
        cases: { meta, fx in
            let target = meta.targetFormat ?? "zip"
            let key = target == "zip" ? "tar.gz" : "zip"
            guard let f = try await ConformanceInputs.file(key: key, fx: fx, name: "sample") else { return [] }
            return [ConformanceCase(label: key, inputs: [f])]
        },
        verify: { run in
            let out = try run.sole()
            let src = try extracted(run.input, run), dst = try extracted(out, run)
            defer { AppPaths.removeTemp(src.root); AppPaths.removeTemp(dst.root) }
            try expect(ArchiveFidelity.unsafeMemberNames(out).isEmpty, "the archive holds unsafe member names: \(ArchiveFidelity.unsafeMemberNames(out))")
            let diffs = ArchiveFidelity.differences(expected: src.entries, actual: dst.entries)
            try expect(diffs.isEmpty, "the repacked archive differs from the source: \(diffs.prefix(6))")
            run.note("\(dst.entries.filter { !$0.isDirectory }.count) files equal in name, bytes and permissions")
        },
        proves: "every member of the source archive again, same path, same bytes, same permission bits, no unsafe names")

    static let archiveExtract = ConformanceOracle(
        id: "archive.extract", priority: 10, match: { $0.id == "archive.extract" },
        cases: { _, fx in
            var cases: [ConformanceCase] = []
            if let zip = try await ConformanceInputs.file(key: "zip", fx: fx, name: "sample") { cases.append(ConformanceCase(label: "zip", inputs: [zip])) }
            if let tgz = try await ConformanceInputs.file(key: "tar.gz", fx: fx, name: "other") { cases.append(ConformanceCase(label: "tar.gz", inputs: [tgz])) }
            var hostile = ConformanceCase(label: "zip-slip", inputs: [try fx.hostileZip("hostile.zip")])
            hostile.expectsFailure = true
            cases.append(hostile)
            return cases
        },
        verify: { run in
            if run.testCase.expectsFailure {
                try expect(run.error != nil, "a ZIP with members that leave the destination must be refused")
                let stray = ConformanceRunner.regularFiles(under: run.fx.root).filter { $0.lastPathComponent.hasPrefix("evil") }
                try expect(stray.isEmpty, "a hostile member was written outside the destination: \(stray.map(\.path))")
                try expect(!FileManager.default.fileExists(atPath: "/tmp/swamp-evil-abs.txt"), "an absolute-path member was written to /tmp")
                run.note("refused: \(run.error ?? "")")
                return
            }
            guard let out = run.returned.first else { throw run.fail("nothing was extracted") }
            let src = try extracted(run.input, run)
            defer { AppPaths.removeTemp(src.root) }
            // A single top-level folder is moved into the destination as it is; several top-level entries get a folder named after the archive.
            let tops = Set(src.entries.map { $0.path.split(separator: "/").first.map(String.init) ?? "" })
            let expectedRoot = tops.count == 1 ? src.root.appendingPathComponent(tops.first!) : src.root
            let diffs = ArchiveFidelity.differences(expected: ArchiveFidelity.tree(expectedRoot), actual: ArchiveFidelity.tree(out))
            try expect(diffs.isEmpty, "the extracted tree differs from what bsdtar extracts: \(diffs.prefix(6))")
            run.note("equals bsdtar's extraction")
        },
        relaxed: [.nonEmpty: "archives hold empty files", .decodes: "members are arbitrary files", .sniffMatchesExtension: "members are arbitrary files"],
        proves: "the same files, bytes and permissions that bsdtar extracts; a ZIP with ../ or absolute members is refused and nothing is written outside the destination")

    static let packArchive = ConformanceOracle(
        id: "archive.pack", priority: 0,
        match: { $0.id.hasPrefix("pack.") && $0.wheel == .tools && $0.acceptsDirectories },
        cases: { _, fx in
            let tree = try fx.archiveSource("project")
            let note = try fx.base.text("note.txt", "Swamp note\nПривет, мир\n")
            return [ConformanceCase(label: "folder + file", inputs: [tree, note])]
        },
        verify: { run in
            let out = try run.sole()
            let ex = try extracted(out, run)
            defer { AppPaths.removeTemp(ex.root) }
            // The copies in the run folder are what was packed: the folder keeps its name as the root entry, the loose file goes in by name.
            let folder = run.inputs[0], file = run.inputs[1]
            let expected: [TreeEntry] = ArchiveFidelity.tree(folder).map { e in var x = e; x.path = folder.lastPathComponent + "/" + e.path; return x }
                + ArchiveFidelity.tree(file.deletingLastPathComponent()).filter { $0.path == file.lastPathComponent }
            let diffs = ArchiveFidelity.differences(expected: expected, actual: ex.entries)
            try expect(diffs.isEmpty, "the archive differs from the packed items: \(diffs.prefix(6))")
            try expect(ArchiveFidelity.unsafeMemberNames(out).isEmpty, "unsafe member names")
            run.note("\(ex.entries.filter { !$0.isDirectory }.count) files equal")
        },
        relaxed: [.namedAfterInput: "several items are packed as 'Archive'"],
        proves: "every packed file and folder is in the archive with the same bytes and permission bits")
}
