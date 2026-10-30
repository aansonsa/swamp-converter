import Foundation

/// Registers one self-test of the data module (see `DataTests.test`).
func dataTest(_ suite: String, _ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
    DataTests.test(suite, name, proves: proves, requires: requires, timeout: timeout, body)
}

/// Shared registration helper of the data module's self-tests. `proves:` lists the oracle ids of schema fields the test demonstrates; `DataTests.registerOracleCoverage`
/// fails when a schema field has no oracle id or its oracle id is proven by no test (same convention as the image module).
enum DataTests {
    /// Oracle ids declared by the registered tests (filled at registration, before any test runs).
    nonisolated(unsafe) static var covered: Set<String> = []

    static func test(_ suite: String, _ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
        covered.formUnion(proves)
        SelfTestRegistry.shared.register(suite, name, requires: requires, timeout: timeout, body)
    }

    static func register() {
        registerCatalogue()
        DataTestsZip.register()
        DataTestsText.register()
        DataTestsCSV.register()
        DataTestsSheets.register()
        DataTestsSubs.register()
        DataTestsTar.register()
        DataTestsArchives.register()
        DataTestsExtract.register()
        DataTestsHostile.register()
        DataTestsMisc.register()
        DataConformance.register()
        registerOracleCoverage()
    }

    // MARK: Catalogue

    private static func registerCatalogue() {
        test("data", "wheel contents: CSV, SRT, ZIP and folders") {
            let reg = OperationRegistry()
            reg.register(SheetCatalog.operations()); reg.register(SubsCatalog.operations()); reg.register(ArchiveCatalog.operations())
            let csv = [FileItem(url: URL(fileURLWithPath: "/tmp/a.csv"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: csv).map(\.id), ["sheet.to.xlsx", "sheet.to.tsv", "sheet.to.ods", "sheet.to.pdf"])
            let srt = [FileItem(url: URL(fileURLWithPath: "/tmp/a.srt"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: srt).map(\.id), ["subs.to.vtt", "subs.to.txt"])
            let zip = [FileItem(url: URL(fileURLWithPath: "/tmp/a.zip"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .convert, items: zip).map(\.id), ["archive.extract", "archive.to.tar", "archive.to.tar.gz"])
            let folder = [FileItem(url: URL(fileURLWithPath: "/tmp/dir"), isDirectory: true)]
            try expectEqual(reg.entries(wheel: .convert, items: folder).count, 0)
            try expectEqual(reg.entries(wheel: .tools, items: folder).map(\.id), ["pack.zip", "pack.tar.gz"])
        }
    }

    // MARK: Oracle coverage

    private static func registerOracleCoverage() {
        test("data", "every schema field has an oracle id and every oracle id is proven by a test") {
            let items: [FileItem] = []
            let schemas: [(String, OptionSchema)] = [("sheet.convert", SheetSchemas.convert(items: items)),
                                                      ("subs.convert", SubsSchemas.convert(items: items)),
                                                      ("archive.extract", ArchiveSchemas.extract(items: items)),
                                                      ("archive.pack", ArchiveSchemas.pack(items: items))]
            var missing: [String] = [], unproven: [String] = []
            var total = 0
            for (name, schema) in schemas {
                try expect(!schema.allFields.isEmpty, "\(name) has fields")
                for f in schema.allFields {
                    total += 1
                    if f.oracle.isEmpty { missing.append("\(name): \(f.key)") } else if !covered.contains(f.oracle) { unproven.append("\(name): \(f.key) -> \(f.oracle)") }
                }
            }
            try expect(total > 40, "the four schemas hold \(total) fields")
            try expect(missing.isEmpty, "fields without an oracle id: \(missing)")
            try expect(unproven.isEmpty, "oracle ids without a test: \(unproven)")
        }
    }
}
