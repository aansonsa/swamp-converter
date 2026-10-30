import SwiftUI
import AppKit

// The archive preview: the member tree with sizes, an "unsafe path" flag on every member that could escape the target folder, and (when the schema has a members field)
// checkboxes that choose what to extract. Reading the listing never extracts anything.

struct ArchiveNode: Identifiable, Equatable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var isUnsafe: Bool
    var isEncrypted: Bool
    /// nil for files (what `List(children:)` needs to show no disclosure triangle).
    var children: [ArchiveNode]?

    /// Paths of every file below this node (or the node itself).
    var filePaths: [String] {
        guard isDirectory else { return [path] }
        return (children ?? []).flatMap(\.filePaths)
    }
}

struct ArchiveListing: Equatable {
    var entries: [Entry]
    struct Entry: Equatable { var path: String; var isDirectory: Bool; var size: Int64; var isEncrypted = false }
}

enum ArchiveTree {
    /// An entry name that could write outside the folder it is extracted into: absolute, with a `..` component, a drive letter, a backslash-rooted or NUL-containing name.
    static func isUnsafe(_ path: String) -> Bool {
        if path.isEmpty || path.contains("\0") { return true }
        if path.hasPrefix("/") || path.hasPrefix("\\") || path.hasPrefix("~") { return true }
        if path.range(of: "^[A-Za-z]:", options: .regularExpression) != nil { return true }
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.contains("..")
    }

    /// Builds the nested tree from flat paths. Folders that only exist implicitly ("a/b.txt" without an "a/" entry) are created. Sorted folders first, then names, Finder-like.
    static func build(_ listing: ArchiveListing) -> [ArchiveNode] {
        final class Box { var node: ArchiveNode; var kids: [String: Box] = [:]; init(_ n: ArchiveNode) { node = n } }
        let root = Box(ArchiveNode(name: "", path: "", isDirectory: true, size: 0, isUnsafe: false, isEncrypted: false, children: []))
        for e in listing.entries {
            let comps = e.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !comps.isEmpty else { continue }
            var cur = root
            var acc = ""
            for (i, c) in comps.enumerated() {
                acc += (acc.isEmpty ? "" : "/") + c
                let last = i == comps.count - 1
                if let next = cur.kids[c] { cur = next }
                else {
                    let isDir = !last || e.isDirectory
                    let b = Box(ArchiveNode(name: c, path: acc, isDirectory: isDir, size: 0, isUnsafe: isUnsafe(acc) || (last && isUnsafe(e.path)), isEncrypted: false, children: isDir ? [] : nil))
                    cur.kids[c] = b; cur = b
                }
                if last && !e.isDirectory {
                    cur.node.size = e.size
                    cur.node.isEncrypted = e.isEncrypted
                    cur.node.isUnsafe = cur.node.isUnsafe || isUnsafe(e.path)
                }
            }
        }
        func finish(_ b: Box) -> ArchiveNode {
            var n = b.node
            guard n.isDirectory else { return n }
            let kids = b.kids.values.map(finish).sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return Util.naturalCompare($0.name, $1.name) == .orderedAscending
            }
            n.children = kids
            n.size = kids.reduce(0) { $0 + $1.size }
            n.isUnsafe = n.isUnsafe || kids.contains { $0.isUnsafe }
            n.isEncrypted = kids.contains { $0.isEncrypted }
            return n
        }
        return finish(root).children ?? []
    }

    static func unsafeCount(_ listing: ArchiveListing) -> Int { listing.entries.filter { isUnsafe($0.path) }.count }

    /// Parses one line of `bsdtar -tvf`: "-rw-r--r--  0 user group   1234 Oct 24 12:00 path/file". nil when the line has another shape.
    static func parseTarLine(_ line: String) -> ArchiveListing.Entry? {
        let pattern = #"^([-dlhpcbs])[-rwxsStT]{9}[@+.]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\w{3}\s+\d+\s+(?:\d{1,2}:\d{2}|\d{4})\s+(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), m.numberOfRanges == 4,
              let kind = Range(m.range(at: 1), in: line), let size = Range(m.range(at: 2), in: line), let name = Range(m.range(at: 3), in: line) else { return nil }
        var path = String(line[name])
        if line[kind] == "l", let arrow = path.range(of: " -> ") { path = String(path[..<arrow.lowerBound]) }
        if path.hasPrefix("./") { path.removeFirst(2) }
        let isDir = line[kind] == "d"
        if isDir, path.hasSuffix("/") { path.removeLast() }
        return ArchiveListing.Entry(path: path, isDirectory: isDir, size: Int64(line[size]) ?? 0)
    }
}

/// Which members the checkboxes select. The option holds the chosen file paths; empty means everything.
enum ArchiveSelection {
    /// The new stored list after the person toggles `node`. `all` is every file path of the archive; `stored` the current value (empty = all).
    static func toggled(node: ArchiveNode, stored: [String], all: [String]) -> [String] {
        let current = Set(stored.isEmpty ? all : stored)
        let files = Set(node.filePaths)
        let allOn = files.isSubset(of: current)
        let next = allOn ? current.subtracting(files) : current.union(files)
        if next.count == all.count { return [] }
        return all.filter { next.contains($0) }
    }

    static func isChecked(node: ArchiveNode, stored: [String]) -> Bool? {
        if stored.isEmpty { return true }
        let s = Set(stored), files = node.filePaths
        let on = files.filter { s.contains($0) }.count
        if on == 0 { return false }
        return on == files.count ? true : nil
    }
}

struct PreviewArchiveView: View {
    @ObservedObject var session: StudioSession
    var row: StudioSourceRow
    var bindings: PreviewBindings

    @State private var nodes: [ArchiveNode] = []
    @State private var allFiles: [String] = []
    @State private var fileCount = 0
    @State private var totalBytes: Int64 = 0
    @State private var unsafe = 0
    @State private var error: String?
    @State private var loading = true
    @State private var truncated = false

    private static let limit = 20_000
    private var stored: [String] {
        guard let k = bindings.archiveMembersKey else { return [] }
        return (session.resolved?.values ?? session.values)[k]?.asList?.compactMap(\.asString) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                PreviewMessage(symbol: "archivebox", title: L("The archive can’t be read", "Не удаётся прочитать архив"), text: error)
            } else if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if unsafe > 0 {
                    InlineMessage(L("This archive contains unsafe paths. Extracting it will be refused.", "В архиве есть небезопасные пути. Распаковка будет отклонена."), tone: .error)
                        .padding(DS.Space.md)
                }
                List(nodes, children: \.children) { node in
                    ArchiveRowView(node: node, checked: bindings.archiveMembersKey == nil ? nil : .some(ArchiveSelection.isChecked(node: node, stored: stored)),
                                   onToggle: { toggle(node) })
                }
                .listStyle(.inset)
                .accessibilityLabel(Text(L("Archive contents", "Содержимое архива")))
            }
            Divider()
            PreviewControlBar {
                if !loading, error == nil {
                    InfoChip(Loc.plural(fileCount, enOne: "\(fileCount) file", enOther: "\(fileCount) files", ruOne: "\(fileCount) файл", ruFew: "\(fileCount) файла", ruMany: "\(fileCount) файлов"), symbol: "doc.on.doc")
                    InfoChip(Util.formatBytes(totalBytes), symbol: "scalemass")
                    if bindings.archiveMembersKey != nil { InfoChip(stored.isEmpty ? L("Extract everything", "Распаковать всё") : L("Extract \(stored.count) selected", "Распаковать выбранное: \(stored.count)"), symbol: "checklist") }
                    if truncated { Text(L("Only the first \(Self.limit) entries are shown.", "Показаны только первые \(Self.limit) элементов.")).font(DS.Typo.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: row.url) { await load() }
    }

    private func toggle(_ node: ArchiveNode) {
        guard let key = bindings.archiveMembersKey else { return }
        let next = ArchiveSelection.toggled(node: node, stored: stored, all: allFiles)
        session.set(key, next.isEmpty ? nil : .list(next.map { .string($0) }))
    }

    private func load() async {
        guard let url = row.url else { return }
        loading = true
        let result: Result<ArchiveListing, Error> = await Task.detached(priority: .userInitiated) { Self.list(url) }.value
        if Task.isCancelled { return }
        switch result {
        case .success(let listing):
            let capped = ArchiveListing(entries: Array(listing.entries.prefix(Self.limit)))
            truncated = listing.entries.count > Self.limit
            nodes = ArchiveTree.build(capped)
            allFiles = capped.entries.filter { !$0.isDirectory }.map(\.path)
            fileCount = listing.entries.filter { !$0.isDirectory }.count
            totalBytes = listing.entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) }
            unsafe = ArchiveTree.unsafeCount(listing)
            error = nil
        case .failure(let e):
            nodes = []; error = ConversionError.describe(e)
        }
        loading = false
    }

    /// Zip through the data module's central-directory reader, everything else through bsdtar's listing.
    nonisolated static func list(_ url: URL) -> Result<ArchiveListing, Error> {
        do {
            if url.pathExtension.lowercased() == "zip" {
                let entries = try ZipKit.list(url).map { ArchiveListing.Entry(path: $0.name, isDirectory: $0.isDirectory, size: $0.uncompressedSize, isEncrypted: $0.isEncrypted) }
                return .success(ArchiveListing(entries: entries))
            }
            return .success(try tarListing(url))
        } catch { return .failure(error) }
    }

    private nonisolated static func tarListing(_ url: URL) throws -> ArchiveListing {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        p.arguments = ["-tvf", url.path]
        ProcessSandbox.apply(to: p)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ConversionError.message(L10n("This archive can’t be listed. It may be damaged or use a format macOS does not read.", "Не удаётся получить список файлов архива. Он повреждён или в формате, который macOS не читает."))
        }
        let entries = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { ArchiveTree.parseTarLine(String($0)) }
        return ArchiveListing(entries: entries)
    }
}

struct ArchiveRowView: View {
    var node: ArchiveNode
    /// nil = no checkboxes; .some(nil) = mixed; .some(true/false).
    var checked: Bool??
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            if let state = checked {
                Button(action: onToggle) {
                    Image(systemName: state == true ? "checkmark.square.fill" : (state == nil ? "minus.square.fill" : "square")).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(node.name))
                .accessibilityValue(Text(state == true ? L("Selected", "Выбрано") : (state == nil ? L("Partly selected", "Выбрано частично") : L("Not selected", "Не выбрано"))))
            }
            Image(systemName: node.isDirectory ? "folder" : "doc").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            if node.isEncrypted { Image(systemName: "lock").foregroundStyle(.secondary).accessibilityLabel(Text(L("Encrypted", "Зашифровано"))) }
            if node.isUnsafe {
                Label(L("Unsafe path", "Небезопасный путь"), systemImage: "exclamationmark.triangle").font(DS.Typo.caption.weight(.medium)).foregroundStyle(StatusTone.error.ink)
            }
            Spacer(minLength: DS.Space.sm)
            Text(Util.formatBytes(node.size)).font(DS.Typo.numeric(DS.Typo.caption)).foregroundStyle(.secondary)
        }
    }
}
