import Foundation

enum ActionsTests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("actions", "the Actions wheel keeps its fixed order and hides Share-less cases correctly") {
            let reg = OperationRegistry()
            reg.register(ActionsCatalog.operations())
            let file = [FileItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false)]
            try expectEqual(reg.entries(wheel: .actions, items: file).map(\.id),
                            ["action.copy", "action.move", "action.path", "action.terminal", "action.float", "action.share", "action.reveal", "action.openwith", "action.quicklook", "action.trash"])
            let folder = [FileItem(url: URL(fileURLWithPath: "/tmp/dir"), isDirectory: true)]
            try expect(reg.entries(wheel: .actions, items: folder).map(\.id).contains("action.copy"))
            try expect(reg.allOperations().allSatisfy { ($0 as? AppAction)?.meta.isAppAction ?? false })
        }
        // ACTIONS OWNER: copy / move into temp folders incl. conflicts and same-path skip, move across volumes keeps the source until verified, path styles, shelf de-duplication,
        // ResultActions.format golden tests, trash uses trashItem (never unlinks), every error is a calm ConversionError.message.
    }
}
