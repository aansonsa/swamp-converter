import Foundation
import Darwin

// Streaming file copy for the Copy / Move actions. Nothing is read into memory: `clonefile(2)` first (instant on APFS, same volume), otherwise `copyfile(3)`
// chunk by chunk with a status callback that reports progress and can stop the copy within one chunk (about 1 MB), so cancelling a 50 GB copy is immediate.
// Folders are copied member by member so progress and cancellation work inside them too. Symlinks are copied as links, never followed.

enum CopyEngine {
    /// Receives the bytes copied so far for the whole item; return false to stop (the copy then throws `CancellationError`).
    typealias Progress = (_ bytesCopied: Int64) -> Bool

    enum Failure: Error, Equatable {
        case posix(Int32)
        case unsupportedFileType(String)
    }

    /// Copies `src` (file, folder or symlink) to the NOT yet existing `dst`. On any error or stop the partial `dst` is removed again.
    /// `allowClone` exists for tests that need real chunked copying on APFS.
    static func copy(from src: URL, to dst: URL, allowClone: Bool = true, progress: Progress? = nil) throws {
        var existing = stat()
        // Only ever remove what this call created: a destination that already exists is refused before anything is touched.
        guard lstat(dst.path, &existing) != 0 else { throw Failure.posix(EEXIST) }
        let state = Running(progress: progress)
        do {
            try copyNode(src.path, dst.path, allowClone: allowClone, state: state)
        } catch {
            removePartial(dst)
            throw error
        }
    }

    // MARK: Measuring

    /// Total size in bytes and member count of a file or folder (symlinks count as zero-size members). `stopAfter` ends the walk early once the total exceeds it,
    /// which is all the "run as a background job?" decision needs.
    static func measure(_ url: URL, stopAfter: Int64? = nil) -> (bytes: Int64, files: Int, exceeded: Bool) {
        var bytes: Int64 = 0
        var files = 0
        func add(_ u: URL) -> Bool {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true { bytes += Int64(v?.fileSize ?? 0) }
            files += 1
            if let stop = stopAfter, bytes > stop { return false }
            return true
        }
        let root = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if root?.isDirectory == true, root?.isSymbolicLink != true {
            if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) {
                for case let u as URL in e where !add(u) { return (bytes, files, true) }
            }
        } else if !add(url) {
            return (bytes, files, true)
        }
        return (bytes, files, false)
    }

    // MARK: Internals

    private final class Running {
        var done: Int64 = 0
        var cancelled = false
        let progress: Progress?
        init(progress: Progress?) { self.progress = progress }
        /// Reports `done + inFile`; false once the caller asked to stop.
        func report(inFile: Int64) -> Bool {
            guard let progress else { return true }
            if !progress(done + inFile) { cancelled = true }
            return !cancelled
        }
    }

    private static func removePartial(_ url: URL) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        try? FileManager.default.removeItem(at: url)   // our own partial output, created a moment ago
    }

    private static func copyNode(_ src: String, _ dst: String, allowClone: Bool, state: Running) throws {
        var st = stat()
        guard lstat(src, &st) == 0 else { throw Failure.posix(errno) }
        if allowClone, clonefile(src, dst, 0) == 0 {
            // A clone is complete at once: account for the whole item so the bar jumps to the end.
            _ = state.report(inFile: measuredSize(src, st))
            return
        }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: try copyDirectory(src, dst, state: state)
        case S_IFLNK: try copySymlink(src, dst)
        case S_IFREG: try copyRegular(src, dst, size: Int64(st.st_size), state: state)
        default: throw Failure.unsupportedFileType((src as NSString).lastPathComponent)
        }
    }

    private static func measuredSize(_ path: String, _ st: stat) -> Int64 {
        (st.st_mode & S_IFMT) == S_IFDIR ? measure(URL(fileURLWithPath: path)).bytes : Int64(st.st_size)
    }

    private static func copyDirectory(_ src: String, _ dst: String, state: Running) throws {
        let fm = FileManager.default
        do { try fm.createDirectory(atPath: dst, withIntermediateDirectories: false) } catch { throw Failure.posix(errno == 0 ? EIO : errno) }
        let names = try fm.contentsOfDirectory(atPath: src).sorted()
        for name in names {
            if state.cancelled { throw CancellationError() }
            try copyNode(src + "/" + name, dst + "/" + name, allowClone: false, state: state)
        }
        // Permissions, times, extended attributes and ACLs of the folder itself come last, so a read-only source folder does not block its own members.
        _ = copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_METADATA))
    }

    private static func copySymlink(_ src: String, _ dst: String) throws {
        let target: String
        do { target = try FileManager.default.destinationOfSymbolicLink(atPath: src) } catch { throw Failure.posix(EIO) }
        if symlink(target, dst) != 0 { throw Failure.posix(errno) }
    }

    private static func copyRegular(_ src: String, _ dst: String, size: Int64, state: Running) throws {
        let cb = Unmanaged.passUnretained(state).toOpaque()
        func attempt(_ flags: Int32) -> Int32 {
            guard let s = copyfile_state_alloc() else { return ENOMEM }
            defer { copyfile_state_free(s) }
            copyfile_state_set(s, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(statusCallback, to: UnsafeRawPointer.self))
            copyfile_state_set(s, UInt32(COPYFILE_STATE_STATUS_CTX), cb)
            return copyfile(src, dst, s, copyfile_flags_t(flags)) == 0 ? 0 : errno
        }
        var code = attempt(COPYFILE_ALL)
        if state.cancelled || code == ECANCELED { throw CancellationError() }
        if code == ENOTSUP || code == EPERM || code == EINVAL {
            // The destination volume (exFAT, SMB) refuses ACLs or extended attributes: copy data and basic attributes only.
            try? FileManager.default.removeItem(atPath: dst)
            code = attempt(COPYFILE_DATA | COPYFILE_STAT)
            if state.cancelled || code == ECANCELED { throw CancellationError() }
        }
        if code != 0 { throw Failure.posix(code) }
        state.done += size
        _ = state.report(inFile: 0)
    }

    /// copyfile(3) status callback: progress per chunk; QUIT as soon as the caller asked to stop.
    private static let statusCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
        guard let ctx else { return Int32(COPYFILE_CONTINUE) }
        let running = Unmanaged<Running>.fromOpaque(ctx).takeUnretainedValue()
        if running.cancelled { return Int32(COPYFILE_QUIT) }
        if what == Int32(COPYFILE_COPY_DATA), stage == Int32(COPYFILE_PROGRESS), let state {
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            if !running.report(inFile: Int64(copied)) { return Int32(COPYFILE_QUIT) }
        }
        return Int32(COPYFILE_CONTINUE)
    }
}

/// Calm, localised sentences for the failures a copy or move can run into.
enum TransferErrors {
    static func describe(_ error: Error, name: String, folder: String) -> String {
        if let f = error as? CopyEngine.Failure {
            switch f {
            case .posix(let code): return describe(posix: code, name: name, folder: folder)
            case .unsupportedFileType:
                return L("“\(name)” is a special file (a socket or device) and cannot be copied.", "«\(name)» - специальный файл (сокет или устройство), его нельзя скопировать.")
            }
        }
        if let c = error as? CocoaError {
            switch c.code {
            case .fileWriteOutOfSpace: return describe(posix: ENOSPC, name: name, folder: folder)
            case .fileWriteNoPermission, .fileWriteVolumeReadOnly: return describe(posix: EACCES, name: name, folder: folder)
            case .fileNoSuchFile, .fileReadNoSuchFile: return describe(posix: ENOENT, name: name, folder: folder)
            default: break
            }
        }
        return ConversionError.describe(error)
    }

    static func describe(posix code: Int32, name: String, folder: String) -> String {
        switch code {
        case ENOSPC, EDQUOT:
            return L("There is not enough free space in “\(folder)” for “\(name)”.", "В «\(folder)» недостаточно места для «\(name)».")
        case EACCES, EPERM:
            return L("“\(name)” could not be written to “\(folder)”: no permission. Choose another folder or change its permissions.",
                     "«\(name)» нельзя записать в «\(folder)»: нет доступа. Выберите другую папку или измените права доступа.")
        case EROFS:
            return L("“\(folder)” is read-only.", "Папка «\(folder)» доступна только для чтения.")
        case ENOENT:
            return L("“\(name)” is no longer there.", "«\(name)» больше нет на месте.")
        case ENAMETOOLONG:
            return L("The name “\(name)” is too long for “\(folder)”.", "Имя «\(name)» слишком длинное для «\(folder)».")
        case EXDEV:
            return L("“\(name)” cannot be moved between these locations.", "«\(name)» нельзя переместить между этими местами.")
        default:
            return L("“\(name)” could not be copied (error \(code)).", "«\(name)» не удалось скопировать (ошибка \(code)).")
        }
    }
}
