import Foundation

/// Finds the things a command line names: input files, operations, presets. Every failure is a usage error that says what was found instead.
@MainActor
enum CLIResolve {
    /// "http://...", "https://...", "www.x.y": a link, not a file.
    static func looksLikeLink(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.")
    }

    /// Absolute, existing inputs in the order given. Names may contain spaces, dots, unicode and a leading dash (after `--`).
    static func fileItems(_ paths: [String]) -> Result<[FileItem], CLIUsageError> {
        var items: [FileItem] = []
        for p in paths {
            if looksLikeLink(p) {
                return .failure(CLIUsageError(message: L("'\(p)' is a link. Use: swamp download <link>", "'\(p)' — это ссылка. Используйте: swamp download <ссылка>")))
            }
            let path = CLIOptionTyping.absolutePath(p)
            guard FileManager.default.fileExists(atPath: path) else {
                return .failure(CLIUsageError(message: L("No such file or folder: \(p)", "Нет такого файла или папки: \(p)")))
            }
            items.append(FileItem(url: URL(fileURLWithPath: path)))
        }
        return .success(items)
    }

    /// By operation id, then case-insensitively, then by target (schema) id, then, for conversions, by target format ("jpg").
    /// `items` makes the choice smarter (the first operation of a target that accepts the files).
    static func operation(_ key: String, items: [FileItem]?, env: CLIEnvironment) -> Result<Operation, CLIUsageError> {
        let all = env.registry.allOperations(settings: env.settings.data)
        if let op = env.registry.operation(id: key) { return .success(op) }
        let lower = key.lowercased()
        if let op = all.first(where: { $0.meta.id.lowercased() == lower }) { return .success(op) }
        let bySchema = all.filter { $0.meta.schemaID.lowercased() == lower && !$0.meta.isAppAction }
        if !bySchema.isEmpty {
            if let items, let fit = bySchema.first(where: { $0.appliesInStudio(items) }) { return .success(fit) }
            return .success(bySchema[0])
        }
        if let items, let fit = all.first(where: { $0.meta.wheel == .convert && $0.meta.targetFormat == lower && $0.appliesInStudio(items) }) { return .success(fit) }
        let names = Array(Set(all.map(\.meta.id) + all.map(\.meta.schemaID))).sorted()
        let near = CLISuggest.closest(key, among: names)
        let hint = near.isEmpty ? "" : " " + L("Did you mean: \(near.joined(separator: ", "))?", "Возможно: \(near.joined(separator: ", "))?")
        return .failure(CLIUsageError(message: L("Unknown operation '\(key)'.", "Неизвестная операция '\(key)'.") + hint + " " + L("List them with: swamp list-ops", "Список: swamp list-ops")))
    }

    /// By id, then by name (either language, ignoring case).
    static func preset(_ key: String, env: CLIEnvironment) -> Result<Preset, CLIUsageError> {
        let all = env.presets.all
        if let p = all.first(where: { $0.id == key }) { return .success(p) }
        let lower = key.lowercased()
        if let p = all.first(where: { $0.id.lowercased() == lower }) { return .success(p) }
        let named = all.filter { $0.name.en.lowercased() == lower || $0.name.ru.lowercased() == lower }
        if named.count == 1 { return .success(named[0]) }
        if named.count > 1 {
            return .failure(CLIUsageError(message: L("Several presets are called '\(key)'. Use the id: \(named.map(\.id).joined(separator: ", "))",
                                                      "Несколько шаблонов называются '\(key)'. Укажите id: \(named.map(\.id).joined(separator: ", "))")))
        }
        let near = CLISuggest.closest(key, among: all.map(\.id) + all.map(\.name.en))
        let hint = near.isEmpty ? "" : " " + L("Did you mean: \(near.joined(separator: ", "))?", "Возможно: \(near.joined(separator: ", "))?")
        return .failure(CLIUsageError(message: L("Unknown preset '\(key)'.", "Неизвестный шаблон '\(key)'.") + hint + " " + L("List them with: swamp presets list", "Список: swamp presets list")))
    }

    /// An existing folder or a path that can become one; a file in the way is a usage error.
    static func outputFolder(_ raw: String) -> Result<String, CLIUsageError> {
        let path = CLIOptionTyping.absolutePath(raw)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
            return .failure(CLIUsageError(message: L("--out must be a folder, but this is a file: \(raw)", "--out должен быть папкой, а это файл: \(raw)")))
        }
        return .success(path)
    }
}
