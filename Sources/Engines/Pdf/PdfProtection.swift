import Foundation
import PDFKit

/// Password protection and removal. Passwords live in memory for the job only: they are never logged, never part of an error message,
/// and their option fields are `persist = false` (never in presets or the queue file).
enum PdfProtection {
    /// Bits of `PDFAccessPermissions` (PDFDocument.h).
    private enum Bit {
        static let lowPrint: UInt = 1 << 0, highPrint: UInt = 1 << 1, changes: UInt = 1 << 2, assembly: UInt = 1 << 3
        static let copying: UInt = 1 << 4, accessibility: UInt = 1 << 5, commenting: UInt = 1 << 6, forms: UInt = 1 << 7
    }

    /// Permission mask of the three toggles. Screen readers always keep access to the text.
    static func permissionMask(print: Bool, copy: Bool, edit: Bool) -> UInt {
        var mask = Bit.accessibility
        if print { mask |= Bit.lowPrint | Bit.highPrint }
        if copy { mask |= Bit.copying }
        if edit { mask |= Bit.changes | Bit.assembly | Bit.commenting | Bit.forms }
        return mask
    }

    /// Encrypts `doc` into `output`. With only an open password the same word becomes the owner password; with only an owner password the file opens
    /// freely and the permissions apply.
    static func protect(_ doc: PDFDocument, openPassword: String, ownerPassword: String, allowPrint: Bool, allowCopy: Bool, allowEdit: Bool, to output: URL) throws {
        for (key, word) in [(PdfKeys.openPassword, openPassword), (PdfKeys.ownerPassword, ownerPassword)] where !isPlainASCII(word) {
            throw ConversionError.invalidOption(key: key, reason: asciiOnly)
        }
        let owner = ownerPassword.isEmpty ? openPassword : ownerPassword
        guard !owner.isEmpty else {
            throw ConversionError.invalidOption(key: PdfKeys.openPassword, reason: L10n("Enter a password to open the file or an owner password.",
                                                                                         "Введите пароль для открытия файла или пароль владельца."))
        }
        var options: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: owner,
                                                      .accessPermissionsOption: NSNumber(value: permissionMask(print: allowPrint, copy: allowCopy, edit: allowEdit))]
        if !openPassword.isEmpty { options[.userPasswordOption] = openPassword }
        try PdfDoc.write(doc, to: output, options: options)
    }

    /// PDF encryption of this generation stores passwords as single bytes and macOS refuses anything else (Cyrillic, accented letters, emoji): measured
    /// with PDFKit and Core Graphics, both fail to write. Opening files that use such passwords is not restricted.
    static func isPlainASCII(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E } }

    static let asciiOnly = L10n("PDF passwords can only use Latin letters, digits and common symbols (no Cyrillic or accented letters).",
                                "Пароль PDF может содержать только латинские буквы, цифры и обычные символы (без кириллицы и букв с диакритикой).")

    static let wrongPassword = L10n("The password is not correct.", "Пароль неверный.")

    /// Writes an unprotected copy. A file that opens without a password but restricts printing, copying or editing needs its owner password.
    static func unlock(source: URL, password: String, stripMeta: Bool, to output: URL) throws {
        guard let doc = PDFDocument(url: source) else {
            throw ConversionError.message(L10n("Cannot open PDF \(source.lastPathComponent): the file is damaged or is not a PDF.",
                                               "Не удалось открыть PDF \(source.lastPathComponent): файл повреждён или это не PDF."))
        }
        guard doc.isEncrypted else {
            throw ConversionError.message(L10n("\(source.lastPathComponent) has no password.", "У файла \(source.lastPathComponent) нет пароля."))
        }
        if doc.isLocked {
            guard !password.isEmpty else {
                throw ConversionError.invalidOption(key: PdfKeys.openPassword, reason: L10n("Enter the password of this file.", "Введите пароль этого файла."))
            }
            guard doc.unlock(withPassword: password) else { throw ConversionError.message(wrongPassword) }
        } else if !password.isEmpty {
            _ = doc.unlock(withPassword: password)    // may raise the access level to owner
        }
        let unrestricted = doc.allowsPrinting && doc.allowsCopying && doc.allowsDocumentChanges && doc.allowsDocumentAssembly
        if !unrestricted && doc.permissionsStatus != .owner {
            throw ConversionError.message(L10n("\(source.lastPathComponent) restricts printing, copying or editing. Enter its owner password to remove the restrictions.",
                                               "Файл \(source.lastPathComponent) ограничивает печать, копирование или правку. Введите пароль владельца, чтобы снять ограничения."))
        }
        guard doc.pageCount > 0 else { throw ConversionError.message(L10n("The PDF has no pages.", "В PDF нет страниц.")) }
        // Writing the opened document again would keep its encryption (PDFKit re-applies it), so the pages go into a fresh document.
        let plain = PdfDoc.plainCopy(of: doc)
        if stripMeta { PdfDoc.stripMetadata(plain) }
        try PdfDoc.write(plain, to: output)
        guard let check = PDFDocument(url: output), !check.isEncrypted else {
            throw ConversionError.message(L10n("Could not remove the password.", "Не удалось снять пароль."))
        }
    }
}
