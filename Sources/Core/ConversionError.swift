import Foundation

/// The one error type engines throw for expected failures. Every case has a localised, calm message
/// (what happened, what to do). Cancellation is NOT an error here: engines let `CancellationError` propagate.
enum ConversionError: LocalizedError, Sendable {
    /// Free-form localised message (use sparingly; prefer a specific case).
    case message(L10n)
    case unsupported(L10n)
    case toolMissing(Tool)
    case toolFailed(tool: String, code: Int32, detail: String)
    case cannotStart(tool: String, reason: String)
    case noOutput
    case noAudioTrack
    case noText
    case noSubtitles
    case unsafeArchivePath(String)
    case encryptedArchive
    case outputNotWritable(URL)
    case fileUnreadable(URL)
    case invalidOption(key: String, reason: L10n)
    case skippedExisting(URL)
    /// One file of a batch failed (name + message). The batch continues; see `OperationResult.failures`.
    case fileFailed(name: String, message: String)
    /// Every file of a batch failed.
    case aggregate([String])

    var errorDescription: String? {
        switch self {
        case .message(let m), .unsupported(let m):
            return m.text
        case .toolMissing(let t):
            return L("\(t.displayName) is not installed. \(t.installHint.text)",
                     "\(t.displayName) не установлен. \(t.installHint.text)")
        case .toolFailed(let tool, let code, let detail):
            let head = L("\(tool) failed with exit code \(code).", "\(tool) завершился с ошибкой (код \(code)).")
            return detail.isEmpty ? head : head + "\n" + detail
        case .cannotStart(let tool, let reason):
            return L("Cannot start \(tool): \(reason)", "Не удалось запустить \(tool): \(reason)")
        case .noOutput:
            return L("The conversion produced no output.", "Конвертация не создала выходных файлов.")
        case .noAudioTrack:
            return L("The file has no audio track.", "В файле нет звуковой дорожки.")
        case .noText:
            return L("No text was found in the file.", "В файле не найден текст.")
        case .noSubtitles:
            return L("The file contains no subtitles.", "В файле нет субтитров.")
        case .unsafeArchivePath(let p):
            return L("This archive contains unsafe paths and was not extracted (\(p)).",
                     "В архиве есть небезопасные пути, распаковка отменена (\(p)).")
        case .encryptedArchive:
            return L("This archive is password-protected.", "Архив защищён паролем.")
        case .outputNotWritable(let url):
            return L("Cannot write to \(url.path). Choose another output folder in Settings.",
                     "Нельзя записать в \(url.path). Выберите другую папку результатов в настройках.")
        case .fileUnreadable(let url):
            return L("Cannot read \(url.lastPathComponent).", "Не удалось прочитать \(url.lastPathComponent).")
        case .invalidOption(let key, let reason):
            return L("Option \(key): ", "Параметр \(key): ") + reason.text
        case .skippedExisting(let url):
            return L("\(url.lastPathComponent) already exists and was skipped.", "\(url.lastPathComponent) уже существует, файл пропущен.")
        case .fileFailed(let name, let message):
            return "\(name): \(message)"
        case .aggregate(let lines):
            return lines.joined(separator: "\n")
        }
    }

    /// Wraps any error into a user-presentable string (ConversionError, CocoaError, POSIX, ...).
    static func describe(_ error: Error) -> String {
        if let c = error as? ConversionError { return c.errorDescription ?? "\(c)" }
        if let c = error as? CocoaError {
            if c.code == .fileWriteNoPermission || c.code == .fileWriteVolumeReadOnly {
                return L("Cannot write to the target folder. Choose another output folder in Settings.",
                         "Нельзя записать в папку назначения. Выберите другую папку результатов в настройках.")
            }
            return L("File error: ", "Ошибка файла: ") + c.localizedDescription
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
