import Foundation

// Move to Trash. The Trash is the only way an item ever leaves the disk from here: `FileManager.trashItem`, never `removeItem`, so everything can be put back.

enum TrashService {
    /// More than five items, or any folder, is asked about first.
    static func needsConfirmation(_ items: [FileItem]) -> Bool { items.count > 5 || items.contains { $0.isDirectory } }

    @MainActor
    static func run(items: [FileItem], system: ActionsSystem? = nil) throws -> ActionResult {
        let system = system ?? ActionsSystem.current
        if needsConfirmation(items) {
            let ask = TrashConfirmation(itemCount: items.count, firstName: items[0].name, includesFolder: items.contains { $0.isDirectory })
            guard system.confirmTrash(ask) else { throw CancellationError() }
        }
        var moved = 0
        var failures: [String] = []
        for item in items {
            guard system.fs.exists(item.url) else {
                failures.append(L("\(item.name): it is no longer there.", "\(item.name): его больше нет на месте."))
                continue
            }
            do {
                try system.fs.trash(item.url)
                moved += 1
            } catch {
                failures.append("\(item.name): " + TransferErrors.describe(error, name: item.name, folder: item.parent.lastPathComponent))
            }
        }
        if moved == 0 {
            throw ConversionError.message(L10n(failures.joined(separator: " ")))
        }
        var en = moved == 1 ? "Moved to the Trash." : "Moved \(ActionText.items(moved).en) to the Trash."
        var ru = moved == 1 ? "Перемещено в Корзину." : "Перемещено в Корзину: \(ActionText.items(moved).ru)."
        if let first = failures.first { en += " " + first; ru += " " + first }
        return ActionResult(note: L10n(en, ru))
    }
}
