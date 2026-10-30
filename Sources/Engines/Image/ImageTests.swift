import Foundation

/// Self-tests of the image module (suite "image"; conformance oracles are in suite "conformance.image").
/// Every option of both schemas is proven by a test that declares the oracle ids it covers (`proves:`); `oracleCoverage` fails when a schema field has no oracle
/// id, or its oracle id is proven by no test.
enum ImageTests {
    /// Oracle ids declared by the registered tests (filled at registration, before any test runs).
    nonisolated(unsafe) static var covered: Set<String> = []

    static func test(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
        covered.formUnion(proves)
        SelfTestRegistry.shared.register("image", name, requires: requires, timeout: timeout, body)
    }

    static func register() {
        registerCatalogue()
        ImageFormatTests.register()
        ImageGeometryTests.register()
        ImageColourTests.register()
        ImageLoaderTests.register()
        ImageOperationTests.register()
        ImagePDFTests.register()
        ImageStudioTests.register()
        ImageEncoderTests.register()
        ImageConformance.register()
        ImageHeicTests.register()
        registerOracleCoverage()
    }

    // MARK: Catalogue

    private static func registerCatalogue() {
        // Structural acceptance (spec/wheel.md 19.13): single JPG -> Convert wheel [PNG, WEBP, AVIF, HEIC, TIFF, ICO, PDF], Tools starts with Compress.
        test("wheel contents for a single JPG follow the catalogue order") {
            let reg = OperationRegistry()
            reg.register(ImageCatalog.operations())
            let items = [FileItem(url: URL(fileURLWithPath: "/tmp/a.jpg"), isDirectory: false)]
            let convert = reg.entries(wheel: .convert, items: items).map(\.id)
            try expectEqual(convert, ["image.to.png", "image.to.webp", "image.to.avif", "image.to.heic", "image.to.tiff", "image.to.ico", "image.to.pdf"])
            try expectEqual(reg.entries(wheel: .tools, items: items).first?.id, "image.compress")
            let two = items + [FileItem(url: URL(fileURLWithPath: "/tmp/b.png"), isDirectory: false)]
            try expect(reg.entries(wheel: .tools, items: two).map(\.id).contains("image.merge.pdf"), "merge needs two images")
            try expect(!reg.entries(wheel: .tools, items: items).map(\.id).contains("image.merge.pdf"), "merge hidden for one image")
        }
        test("the catalogue has the 18 image operations with unique ids and shared schemas") {
            let ops = ImageCatalog.operations()
            try expectEqual(ops.count, 18, "8 convert + 9 tools + merge (gif.to.* belong to the video module)")
            try expectEqual(Set(ops.map(\.meta.id)).count, ops.count, "ids must be unique")
            for op in ops {
                let schema = op.optionSchema(for: [])
                try expect(["image.convert", "image.pdf"].contains(schema.id), "\(op.meta.id) has schema \(schema.id)")
                try expectEqual(schema.id, op.meta.schemaID, "\(op.meta.id): meta.schemaID and the schema agree")
            }
        }
        test("RAW files are image inputs and RAW output defaults to JPEG, SVG to PNG") {
            for ext in ["cr3", "nef", "arw", "dng", "raf"] { try expect(Formats.imageAndRawInputs.contains(ext), "\(ext) is an image input") }
            try expectEqual(ImageFormat.sameFormat(forKey: "cr3"), "jpeg")
            try expectEqual(ImageFormat.sameFormat(forKey: "svg"), "png")
            try expectEqual(ImageFormat.sameFormat(forKey: "heic"), "heic")
            try expectEqual(ImageFormat.sameFormat(forKey: "jpg"), "jpeg")
        }
    }

    // MARK: Oracle coverage

    private static func registerOracleCoverage() {
        test("every schema field has an oracle id and every oracle id is proven by a test") {
            let items: [FileItem] = []
            let fields = ImageSchemas.convert(items: items).allFields + ImageSchemas.mergePDF(items: items).allFields
            try expect(fields.count > 40, "the schemas hold \(fields.count) fields")
            var missing: [String] = [], unproven: [String] = []
            for f in fields {
                if f.oracle.isEmpty { missing.append(f.key) } else if !covered.contains(f.oracle) { unproven.append("\(f.key) -> \(f.oracle)") }
            }
            try expect(missing.isEmpty, "fields without an oracle id: \(missing)")
            try expect(unproven.isEmpty, "oracle ids without a test: \(unproven)")
        }
    }
}
