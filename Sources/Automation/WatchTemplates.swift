import Foundation

// G. WATCH-FOLDER RECIPES shipped as one-click templates. ALL OFF BY DEFAULT and loop-safe (never reprocess own outputs). Enabling one creates a `WatchRule` with
// `templateID` set; disabling removes it. The user can edit the resulting rule in Settings > Folders like any other.

struct WatchTemplate: Identifiable, Sendable {
    var id: String
    var title: L10n
    var detail: L10n
    var symbol: String
    /// Folder the template watches (resolved at enable time: the screenshot location, ~/Downloads ...). The user may change it in the confirmation sheet.
    var defaultFolder: @Sendable () -> URL
    var recipe: Recipe
    /// The rule only reacts to files matching this (e.g. screenshots: names starting "Screenshot" / "Снимок экрана"; big movies: > 500 MB).
    var filter: WatchFilter
    /// Templates of one group replace each other (one folder, WebP or JPG, never both).
    var exclusiveGroup: String? = nil
    /// The drop folder is bound to a preset the person picks: `WatchTemplates.dropFolder(boundTo:)` fills the recipe; until then it cannot be enabled.
    var needsRecipe = false
    /// Results go to this subfolder of the watched folder (the watcher ignores it); nil = the global output rules.
    var outputSubfolder: String? = nil
    /// The template creates its folder when enabled (drop folders). Screenshot and Downloads folders already exist.
    var createsFolder = false
}

struct WatchFilter: Codable, Equatable, Sendable {
    var namePrefixes: [String] = []
    var extensions: [String] = []
    var minBytes: Int64? = nil
    var maxBytes: Int64? = nil

    var isEmpty: Bool { namePrefixes.isEmpty && extensions.isEmpty && minBytes == nil && maxBytes == nil }

    /// `size` nil = not known yet (the file may still be growing): the size limits are then not applied.
    func matches(name: String, size: Int64?) -> Bool {
        if !extensions.isEmpty {
            let ext = (name as NSString).pathExtension.lowercased()
            guard extensions.contains(where: { $0.lowercased() == ext }) else { return false }
        }
        if !namePrefixes.isEmpty {
            // NFC on both sides: a Cyrillic file name from the file system may be decomposed.
            let n = name.precomposedStringWithCanonicalMapping
            guard namePrefixes.contains(where: { n.range(of: $0.precomposedStringWithCanonicalMapping, options: [.anchored, .caseInsensitive]) != nil }) else { return false }
        }
        if let size {
            if let lo = minBytes, size < lo { return false }
            if let hi = maxBytes, size > hi { return false }
        }
        return true
    }
}

enum WatchTemplates {
    static let screenshotsWebP = "screenshots-webp"
    static let screenshotsJPG = "screenshots-jpg"
    static let heicToJPG = "heic-to-jpg"
    static let bigMovie = "big-mov-hevc"
    static let dropFolder = "drop-folder"

    /// Names macOS gives screenshots in the languages of the app (English, older macOS, Russian).
    static let screenshotPrefixes = ["Screenshot", "Screen Shot", "Снимок экрана", "Скриншот"]
    static let bigMovieBytes: Int64 = 500 * 1024 * 1024

    private static let imageExtensions = ["png", "jpg", "jpeg", "heic", "tiff", "tif"]

    /// Built-ins: "Screenshots -> WebP" / "Screenshots -> JPG" (the screenshot location read from `com.apple.screencapture`, fallback ~/Desktop), "Incoming HEIC -> JPG"
    /// (Downloads, where AirDrop and browsers put files), "Big .mov in Downloads -> HEVC" (smart.best, over 500 MB) and the "Drop folder" bound to any preset
    /// (use `dropFolder(boundTo:)`). Cheap value construction; folders are resolved only when a template is enabled.
    static var all: [WatchTemplate] { builtins }

    private static let builtins: [WatchTemplate] = [
        WatchTemplate(id: screenshotsWebP, title: L10n("Screenshots to WebP", "Скриншоты в WebP"),
                      detail: L10n("New screenshots are converted to small WebP files next to the original.", "Новые скриншоты превращаются в лёгкие файлы WebP рядом с оригиналом."),
                      symbol: "camera.viewfinder", defaultFolder: { screenshotFolder() }, recipe: Recipe(operationID: "image.to.webp"),
                      filter: WatchFilter(namePrefixes: screenshotPrefixes, extensions: imageExtensions), exclusiveGroup: "screenshots"),
        WatchTemplate(id: screenshotsJPG, title: L10n("Screenshots to JPG", "Скриншоты в JPG"),
                      detail: L10n("New screenshots are converted to JPG next to the original.", "Новые скриншоты превращаются в JPG рядом с оригиналом."),
                      symbol: "camera.viewfinder", defaultFolder: { screenshotFolder() }, recipe: Recipe(operationID: "image.to.jpg"),
                      filter: WatchFilter(namePrefixes: screenshotPrefixes, extensions: imageExtensions), exclusiveGroup: "screenshots"),
        WatchTemplate(id: heicToJPG, title: L10n("Incoming HEIC to JPG", "Входящие HEIC в JPG"),
                      detail: L10n("HEIC photos that arrive in Downloads (AirDrop, mail, browsers) get a JPG copy that opens everywhere.",
                                   "HEIC-фото, попавшие в «Загрузки» (AirDrop, почта, браузеры), получают копию в JPG, которая открывается везде."),
                      symbol: "photo.badge.arrow.down", defaultFolder: { downloadsFolder() }, recipe: Recipe(operationID: "image.to.jpg"),
                      filter: WatchFilter(extensions: ["heic", "heif"])),
        WatchTemplate(id: bigMovie, title: L10n("Big movies to HEVC", "Большие фильмы в HEVC"),
                      detail: L10n("A .mov over 500 MB in Downloads is converted with Best for Apple: the same picture in a much smaller, compatible file.",
                                   "Файл .mov больше 500 МБ в «Загрузках» конвертируется как «Лучшее для Apple»: та же картинка в гораздо меньшем совместимом файле."),
                      symbol: "film", defaultFolder: { downloadsFolder() }, recipe: Recipe(operationID: "smart.best"),
                      filter: WatchFilter(extensions: ["mov"], minBytes: bigMovieBytes)),
        WatchTemplate(id: dropFolder, title: L10n("Drop folder", "Папка-приёмник"),
                      detail: L10n("Everything you put into this folder is processed with the preset you choose; results go to its Converted subfolder.",
                                   "Всё, что вы кладёте в эту папку, обрабатывается выбранным шаблоном; результаты попадают в подпапку «Converted»."),
                      symbol: "tray.and.arrow.down", defaultFolder: { dropFolderLocation() }, recipe: Recipe(operationID: ""),
                      filter: WatchFilter(), needsRecipe: true, outputSubfolder: "Converted", createsFolder: true)
    ]

    // MARK: Lookup

    static func template(id: String) -> WatchTemplate? { builtins.first { $0.id == id } }

    /// The file filter of a rule created from a template (nil for hand-made rules).
    static func filter(forTemplateID id: String?) -> WatchFilter? {
        guard let id, let t = template(id: id), !t.filter.isEmpty else { return nil }
        return t.filter
    }

    /// The drop-folder template bound to a recipe (a preset the person picked: `Recipe(operationID: preset.targetID, values: preset.values, presetID: preset.id)`).
    static func dropFolder(boundTo recipe: Recipe) -> WatchTemplate? {
        guard var t = template(id: dropFolder) else { return nil }
        t.recipe = recipe
        t.needsRecipe = false
        return t
    }

    // MARK: Folders

    /// The folder macOS writes screenshots to: `defaults read com.apple.screencapture location`, else ~/Desktop. (Read through CFPreferences: no process is started.)
    static func screenshotFolder() -> URL {
        let value = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        return screenshotFolder(preference: value)
    }

    /// Pure part of `screenshotFolder()`: tilde expanded, relative or empty values fall back to the Desktop.
    static func screenshotFolder(preference: String?) -> URL {
        if let raw = preference?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true) }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    static func downloadsFolder() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    static func dropFolderLocation() -> URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Swamp Drop Folder", isDirectory: true)
    }

    // MARK: Availability

    /// Can this Mac run the template's operation right now? (WebP needs cwebp, for instance.) The Settings page shows the reason next to the switch.
    static func availability(of template: WatchTemplate, registry: OperationRegistry = .shared, tools: ToolLocator = .shared) -> OperationAvailability {
        guard !template.recipe.operationID.isEmpty,
              let op = registry.operation(id: template.recipe.operationID) ?? registry.primaryOperation(forTarget: template.recipe.operationID) else {
            return .unavailable(reason: L10n("The operation of this template is not available.", "Операция этого шаблона недоступна."), missing: [])
        }
        let sample = FileItem(url: URL(fileURLWithPath: "/sample." + (template.filter.extensions.first ?? "png")), isDirectory: false)
        return op.availability(for: [sample], tools: tools)
    }

    // MARK: Enable / disable

    /// Creates the rule for a template and stores it in the settings (the watch service reacts to the change by itself; this does not start anything else).
    /// nil when it is already present (for the drop folder: a rule for the same folder), when the template still needs a preset, or when the folder cannot be created.
    /// Templates of the same exclusive group replace each other.
    @MainActor
    @discardableResult
    static func enable(_ template: WatchTemplate, folder: URL?, settings: AppSettings = .shared) -> WatchRule? {
        guard !template.needsRecipe, !template.recipe.operationID.isEmpty else { return nil }
        let target = (folder ?? template.defaultFolder()).standardizedFileURL
        let existing = settings.data.watchRules
        if template.exclusiveGroup == nil {
            if template.id == dropFolder {
                if existing.contains(where: { $0.templateID == template.id && FolderWatcher.realPath(URL(fileURLWithPath: $0.path)) == FolderWatcher.realPath(target) }) { return nil }
            } else if existing.contains(where: { $0.templateID == template.id }) { return nil }
        } else if existing.contains(where: { $0.templateID == template.id }) { return nil }

        if template.createsFolder {
            do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) } catch { return nil }
        }
        var rule = WatchRule(path: target.path, recipe: template.recipe)
        rule.templateID = template.id
        rule.enabled = true
        if let sub = template.outputSubfolder { rule.outputDir = target.appendingPathComponent(sub, isDirectory: true).path }
        let group = template.exclusiveGroup
        let groupIDs = group == nil ? Set<String>() : Set(builtins.filter { $0.exclusiveGroup == group && $0.id != template.id }.map(\.id))
        settings.update { s in
            s.watchRules.removeAll { $0.templateID.map(groupIDs.contains) ?? false }
            s.watchRules.append(rule)
        }
        return rule
    }

    /// Removes every rule created from the template (all drop folders, for the drop template).
    @MainActor
    static func disable(templateID: String, settings: AppSettings = .shared) {
        settings.update { $0.watchRules.removeAll { $0.templateID == templateID } }
    }

    /// Removes the rule of one folder (several drop folders may exist).
    @MainActor
    static func disable(templateID: String, folder: URL, settings: AppSettings = .shared) {
        let real = FolderWatcher.realPath(folder)
        settings.update { $0.watchRules.removeAll { $0.templateID == templateID && FolderWatcher.realPath(URL(fileURLWithPath: $0.path)) == real } }
    }

    @MainActor
    static func isEnabled(templateID: String, settings: AppSettings = .shared) -> Bool {
        settings.data.watchRules.contains { $0.templateID == templateID }
    }
}
