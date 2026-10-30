import Foundation
import Darwin

// The model of "copy / move these items into that folder": what the person decides (conflicts), the plan that follows from it, and the file-system seam
// the executor works through. Planning is cheap and may ask questions; executing (ActionTransferRun.swift) never asks anything, so it can also run as a job.

enum TransferMode: String, Codable, Sendable {
    case copy, move
}

enum ConflictChoice: String, Sendable {
    case keepBoth, replace, skip, stop
}

struct ConflictAnswer: Sendable {
    var choice: ConflictChoice
    /// "Apply to all": the same choice for the remaining conflicts of this operation.
    var applyToAll = false
}

/// What the conflict alert needs to describe the clash, Finder style.
struct ConflictInfo: Sendable {
    var name: String
    var mode: TransferMode
    var folderName: String
    var sourceIsDirectory: Bool
    var existingIsDirectory: Bool
    var sourceSize: Int64?
    var existingSize: Int64?
    var sourceDate: Date?
    var existingDate: Date?
    /// More items follow, so "Apply to all" makes sense.
    var canApplyToAll: Bool
}

typealias ConflictResolver = @MainActor (ConflictInfo) async -> ConflictAnswer

/// One item of a plan. `destination` is the final path; for `.replace` it is the existing item that goes to the Trash first.
struct TransferStep: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The destination name is free.
        case plain
        /// The name was taken: `destination` is already the free "name (2)".
        case keepBoth
        /// The old item at `destination` moves to the Trash, the new one takes its place.
        case replace
    }

    var source: String
    var destination: String
    var isDirectory: Bool
    var kind: Kind
    /// Filled by `TransferPlan.measured()`; zero until then.
    var bytes: Int64 = 0

    var sourceURL: URL { URL(fileURLWithPath: source) }
    var destinationURL: URL { URL(fileURLWithPath: destination) }
}

struct TransferPlan: Codable, Equatable, Sendable {
    var mode: TransferMode
    var folder: String
    var steps: [TransferStep] = []
    /// Items that already live in the chosen folder.
    var skippedSamePath: [String] = []
    /// Items the person chose to skip in the conflict alert.
    var skippedByChoice: [String] = []
    /// The person pressed Stop: nothing is copied or moved.
    var stopped = false

    var folderURL: URL { URL(fileURLWithPath: folder) }
    var totalBytes: Int64 { steps.reduce(0) { $0 + $1.bytes } }
    var isEmpty: Bool { steps.isEmpty }
}

/// The file-system operations the transfer needs, as closures, so tests can force a "different volume", break a copy or watch what goes to the Trash
/// without touching the person's real Trash.
struct TransferFS: Sendable {
    var exists: @Sendable (URL) -> Bool
    var isDirectory: @Sendable (URL) -> Bool
    var isWritableFolder: @Sendable (URL) -> Bool
    var sameVolume: @Sendable (_ item: URL, _ folder: URL) -> Bool
    var sameFile: @Sendable (URL, URL) -> Bool
    var copy: @Sendable (_ src: URL, _ dst: URL, _ allowClone: Bool, _ progress: CopyEngine.Progress?) throws -> Void
    /// Atomic rename that never replaces an existing item.
    var rename: @Sendable (URL, URL) throws -> Void
    var trash: @Sendable (URL) throws -> Void
    /// Bytes and member count, to prove a copy is complete before the original is touched.
    var signature: @Sendable (URL) -> (bytes: Int64, files: Int)

    static let live = TransferFS(
        exists: { var st = stat(); return lstat($0.path, &st) == 0 },
        isDirectory: { var st = stat(); return stat($0.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR },
        isWritableFolder: { access($0.path, W_OK | X_OK) == 0 },
        sameVolume: { item, folder in
            var a = stat(), b = stat()
            guard lstat(item.path, &a) == 0, stat(folder.path, &b) == 0 else { return false }
            return a.st_dev == b.st_dev
        },
        sameFile: { x, y in
            var a = stat(), b = stat()
            guard lstat(x.path, &a) == 0, lstat(y.path, &b) == 0 else { return false }
            return a.st_dev == b.st_dev && a.st_ino == b.st_ino
        },
        copy: { try CopyEngine.copy(from: $0, to: $1, allowClone: $2, progress: $3) },
        rename: { src, dst in
            // RENAME_EXCL fails instead of replacing; volumes without it (exFAT) get the same guarantee from a check right before.
            var code = renamex_np(src.path, dst.path, UInt32(RENAME_EXCL))
            if code != 0, errno == ENOTSUP {
                var st = stat()
                if lstat(dst.path, &st) == 0 { throw CopyEngine.Failure.posix(EEXIST) }
                code = Darwin.rename(src.path, dst.path)
            }
            if code != 0 { throw CopyEngine.Failure.posix(errno) }
        },
        trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        signature: { let m = CopyEngine.measure($0); return (m.bytes, m.files) })
}

enum TransferNaming {
    /// `name (2).ext`, `name (3).ext` ... the first one that is neither on disk nor in `taken` (lower-cased paths of items planned in this batch).
    static func uniqueURL(in folder: URL, name: String, isDirectory: Bool, taken: Set<String> = [], exists: (URL) -> Bool) -> URL {
        let base = Formats.baseName(forName: name, isDirectory: isDirectory)
        let ext = isDirectory || base.count >= name.count ? "" : String(name.dropFirst(base.count + 1))
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            if !exists(candidate) && !taken.contains(candidate.path.lowercased()) { return candidate }
            n += 1
        }
    }

    /// Hidden in-flight name `.base.8hex.part.ext` in the destination folder (the same shape `OutputPaths` uses, so watched folders ignore it).
    static func partURL(in folder: URL, for name: String, isDirectory: Bool) -> URL {
        let base = Formats.baseName(forName: name, isDirectory: isDirectory)
        let ext = isDirectory || base.count >= name.count ? "" : String(name.dropFirst(base.count + 1))
        return folder.appendingPathComponent(".\(base).\(Util.hex8()).part" + (ext.isEmpty ? "" : "." + ext))
    }
}

enum TransferPlanner {
    /// Decides, for every item, what happens in `folder`: plain copy, keep both, replace, skip. Asks `resolver` for each real clash (once for all when
    /// the person ticks "Apply to all"). Throws calm `ConversionError.message`s for impossible requests (into itself, read-only folder).
    @MainActor
    static func plan(mode: TransferMode, items: [FileItem], folder: URL, resolver: ConflictResolver, fs: TransferFS = .live) async throws -> TransferPlan {
        guard fs.isDirectory(folder) else {
            throw ConversionError.message(L10n("“\(folder.lastPathComponent)” is not a folder.", "«\(folder.lastPathComponent)» не является папкой."))
        }
        guard fs.isWritableFolder(folder) else { throw ConversionError.outputNotWritable(folder) }
        var plan = TransferPlan(mode: mode, folder: folder.path)
        var taken = Set<String>()
        var remembered: ConflictChoice?
        let folderPath = folder.resolvingSymlinksInPath().path

        for (index, item) in items.enumerated() {
            let target = folder.appendingPathComponent(item.name)
            if target.path == item.url.path || fs.sameFile(item.url, target) {
                plan.skippedSamePath.append(item.url.path)
                continue
            }
            let sourcePath = item.url.resolvingSymlinksInPath().path
            if item.isDirectory, folderPath == sourcePath || folderPath.hasPrefix(sourcePath + "/") {
                throw ConversionError.message(mode == .copy
                    ? L10n("“\(item.name)” cannot be copied into itself.", "«\(item.name)» нельзя скопировать в саму себя.")
                    : L10n("“\(item.name)” cannot be moved into itself.", "«\(item.name)» нельзя переместить в саму себя."))
            }
            let clashesOnDisk = fs.exists(target)
            let clashesInBatch = taken.contains(target.path.lowercased())
            guard clashesOnDisk || clashesInBatch else {
                taken.insert(target.path.lowercased())
                plan.steps.append(TransferStep(source: item.url.path, destination: target.path, isDirectory: item.isDirectory, kind: .plain))
                continue
            }
            if !clashesOnDisk {
                // Two dropped items share a name: nothing exists yet to replace, so both are kept.
                let free = TransferNaming.uniqueURL(in: folder, name: item.name, isDirectory: item.isDirectory, taken: taken, exists: fs.exists)
                taken.insert(free.path.lowercased())
                plan.steps.append(TransferStep(source: item.url.path, destination: free.path, isDirectory: item.isDirectory, kind: .keepBoth))
                continue
            }
            // The thing that would be replaced must not contain the source (moving "a/b" onto "a").
            if sourcePath.hasPrefix(target.resolvingSymlinksInPath().path + "/") {
                throw ConversionError.message(L10n("“\(item.name)” is inside the item it would replace.", "«\(item.name)» находится внутри элемента, который пришлось бы заменить."))
            }
            let choice: ConflictChoice
            if let remembered { choice = remembered } else {
                let answer = await resolver(conflictInfo(item, target: target, mode: mode, folder: folder, canApplyToAll: index < items.count - 1, fs: fs))
                choice = answer.choice
                if answer.applyToAll && answer.choice != .stop { remembered = answer.choice }
            }
            switch choice {
            case .stop:
                plan.stopped = true
                plan.steps = []
                return plan
            case .skip:
                plan.skippedByChoice.append(item.url.path)
            case .replace:
                taken.insert(target.path.lowercased())
                plan.steps.append(TransferStep(source: item.url.path, destination: target.path, isDirectory: item.isDirectory, kind: .replace))
            case .keepBoth:
                let free = TransferNaming.uniqueURL(in: folder, name: item.name, isDirectory: item.isDirectory, taken: taken, exists: fs.exists)
                taken.insert(free.path.lowercased())
                plan.steps.append(TransferStep(source: item.url.path, destination: free.path, isDirectory: item.isDirectory, kind: .keepBoth))
            }
        }
        return plan
    }

    private static func conflictInfo(_ item: FileItem, target: URL, mode: TransferMode, folder: URL, canApplyToAll: Bool, fs: TransferFS) -> ConflictInfo {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let existing = try? target.resourceValues(forKeys: keys)
        let source = try? item.url.resourceValues(forKeys: keys)
        return ConflictInfo(name: item.name, mode: mode, folderName: folder.lastPathComponent, sourceIsDirectory: item.isDirectory,
                            existingIsDirectory: existing?.isDirectory ?? false,
                            sourceSize: item.isDirectory ? nil : (source?.fileSize).map(Int64.init),
                            existingSize: (existing?.isDirectory ?? false) ? nil : (existing?.fileSize).map(Int64.init),
                            sourceDate: source?.contentModificationDate, existingDate: existing?.contentModificationDate, canApplyToAll: canApplyToAll)
    }
}

extension TransferPlan {
    /// The plan with every step's size filled in (walks folders, so it runs off the main actor).
    func measured() -> TransferPlan {
        var copy = self
        for i in copy.steps.indices { copy.steps[i].bytes = CopyEngine.measure(copy.steps[i].sourceURL).bytes }
        return copy
    }
}
