import Foundation

/// Candidate filter shared by the service and its tests (spec/appfeatures.md 5.2 plus the macOS additions).
enum WatchCandidate {
    /// Extensions of files that are still being written by a browser, a torrent client or an editor.
    static let transientExtensions: Set<String> = ["tmp", "temp", "part", "partial", "crdownload", "download", "opdownload", "!ut", "aria2", "lock", "icloud", "swp", "swx", "filepart"]
    /// Files the system and other platforms drop next to everything.
    static let ignoredNames: Set<String> = ["desktop.ini", "thumbs.db", ".ds_store", ".localized", "icon\r", "ehthumbs.db"]
    /// Folders that are single files for the user: their insides are never candidates.
    static let packageExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary", "imovielibrary", "fcpbundle", "download",
                                                 "xcodeproj", "xcworkspace", "rtfd", "pages", "numbers", "key", "sparsebundle", "logicx", "band", "tvlibrary"]

    // MARK: Names

    /// True for names that must never run: hidden (this includes AppleDouble `._*`, `.DS_Store`, iCloud placeholders and this app's own `.part` temp files), Office
    /// lock files `~$*`, `.part.` temp names, download-in-progress suffixes and a few system files. Pure: no file system access.
    static func isTransientName(_ name: String) -> Bool {
        if name.isEmpty || name.hasPrefix(".") || name.hasPrefix("~$") { return true }
        if OutputPaths.isInFlightName(name) { return true }
        let lower = name.lowercased()
        if lower.contains(".part.") || ignoredNames.contains(lower) { return true }
        return transientExtensions.contains((lower as NSString).pathExtension)
    }

    // MARK: Position

    /// `root` and the url must be symlink-free paths (`FolderWatcher.realPath`). A sibling with a common prefix (`watched-other`) is not inside.
    static func isInside(_ path: String, root: String, includeSubfolders: Bool) -> Bool {
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return false }
        let relative = path.dropFirst(prefix.count)
        if relative.isEmpty { return false }
        return includeSubfolders || !relative.contains("/")
    }

    /// Does any folder between the watched root and the file hide the file (a hidden folder such as `.Trash`, `.fseventsd`, `.TemporaryItems`, or a package)?
    static func hasHiddenOrPackageAncestor(_ path: String, root: String) -> Bool {
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return false }
        let comps = path.dropFirst(prefix.count).split(separator: "/").dropLast()
        for c in comps {
            if c.hasPrefix(".") { return true }
            if packageExtensions.contains((String(c).lowercased() as NSString).pathExtension) { return true }
        }
        return false
    }

    // MARK: Own outputs

    /// True for anything this app produced: the file itself, or a folder it produced above it (a pack or a page folder: its files are not registered one by one).
    /// Looking at ancestors stops at the watched root.
    static func isOwnOutput(_ url: URL, root: String? = nil, outputs: OwnOutputs = .shared) -> Bool {
        if outputs.contains(url) { return true }
        var dir = url.deletingLastPathComponent()
        var guardCount = 0
        while dir.path.count > 1, guardCount < 24 {
            if let root, dir.standardizedFileURL.path == root || dir.resolvingSymlinksInPath().path == root { break }
            if outputs.contains(dir) { return true }
            dir = dir.deletingLastPathComponent()
            guardCount += 1
        }
        return false
    }

    // MARK: Output location of a rule

    /// The rules a job of `rule` writes with: the rule's output folder wins over the recipe's own rules, which win over the global ones.
    static func effectiveOutput(of rule: WatchRule, settings: SettingsData) -> OutputRules {
        var rules = rule.recipe.output ?? settings.output
        if let dir = rule.outputDir, !dir.isEmpty { rules.dirMode = .custom; rules.customDir = dir }
        return rules
    }

    /// Folders inside (or equal to) the watched tree that hold this rule's results: the watcher must not react to them.
    static func ignoredFolders(for rule: WatchRule, settings: SettingsData) -> [URL] {
        let rules = effectiveOutput(of: rule, settings: settings)
        let root = URL(fileURLWithPath: rule.path, isDirectory: true)
        switch rules.dirMode {
        case .sameAsSource: return []
        case .custom:
            guard let c = rules.customDir, !c.isEmpty else { return [] }
            return [URL(fileURLWithPath: c, isDirectory: true)]
        case .subfolder:
            return [root.appendingPathComponent(Util.safeFileName(rules.subfolderName, fallback: "Converted"), isDirectory: true)]
        }
    }

    // MARK: The candidate decision

    /// True for files a rule may process: not hidden, not AppleDouble, not in-flight (`OutputPaths.isInFlightName`), not a download-in-progress suffix, not a package
    /// internal, not created by this app (`OwnOutputs`), not in the rule's own output folder, inside the rule's folder, matching the template filter, and a file the
    /// rule's operation accepts (a PNG never runs a "to PNG" rule, a PDF never runs an image rule). Directories never run.
    /// `size` nil = the file may still be growing: the size limits of the filter are applied only when it is known.
    static func isCandidate(_ url: URL, isDirectory: Bool, rule: WatchRule, size: Int64? = nil, registry: OperationRegistry = .shared,
                            settings: SettingsData = AppSettings.shared.data, outputs: OwnOutputs = .shared) -> Bool {
        if isDirectory { return false }
        let name = url.lastPathComponent
        if isTransientName(name) { return false }
        let root = FolderWatcher.realPath(URL(fileURLWithPath: rule.path, isDirectory: true))
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard isInside(path, root: root, includeSubfolders: rule.includeSubfolders) else { return false }
        if hasHiddenOrPackageAncestor(path, root: root) { return false }
        if isOwnOutput(url, root: root, outputs: outputs) { return false }
        for ignored in ignoredFolders(for: rule, settings: settings) {
            let real = FolderWatcher.realPath(ignored)
            if path.hasPrefix(real + "/") { return false }
        }
        // A named subfolder of results ("Converted") inside a recursive watch: nothing below a folder of that name is ever new input.
        let rules = effectiveOutput(of: rule, settings: settings)
        if rules.dirMode == .subfolder, rule.includeSubfolders {
            let sub = Util.safeFileName(rules.subfolderName, fallback: "Converted")
            let prefix = root + "/"
            if path.dropFirst(prefix.count).split(separator: "/").dropLast().contains(where: { $0 == Substring(sub) }) { return false }
        }
        if let filter = WatchTemplates.filter(forTemplateID: rule.templateID), !filter.matches(name: name, size: size) { return false }
        return acceptsInput(url, size: size, rule: rule, registry: registry)
    }

    /// The operation of the rule exists, is allowed unattended and applies to this file.
    static func acceptsInput(_ url: URL, size: Int64?, rule: WatchRule, registry: OperationRegistry = .shared) -> Bool {
        guard let op = operation(for: rule, registry: registry), !op.meta.isAppAction, !op.meta.acceptsLinks else { return false }
        let item = FileItem(url: url, isDirectory: false, size: size)
        return op.appliesTo([item])
    }

    static func operation(for rule: WatchRule, registry: OperationRegistry = .shared) -> Operation? {
        let id = rule.recipe.operationID
        guard !id.isEmpty else { return nil }
        return registry.operation(id: id) ?? registry.primaryOperation(forTarget: id)
    }
}
