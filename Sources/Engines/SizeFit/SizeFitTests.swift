import Foundation

enum SizeFitTests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("sizefit", "Fit to size is offered for video, audio, image and PDF and asks the target on the quick path") {
            let reg = OperationRegistry()
            reg.register(FitCatalog.operations())
            for (file, id) in [("a.mp4", "fit.video"), ("a.mp3", "fit.audio"), ("a.heic", "fit.image"), ("a.pdf", "fit.pdf")] {
                let items = [FileItem(url: URL(fileURLWithPath: "/tmp/\(file)"), isDirectory: false)]
                try expectEqual(reg.entries(wheel: .tools, items: items).map(\.id), [id])
            }
            try expectEqual(try unwrap(reg.operation(id: "fit.video")).meta.quickPromptKeys, [FitKeys.target])
        }
        SizeFitPlannerTests.register()
        SizeFitContractTests.register()
    }
}
