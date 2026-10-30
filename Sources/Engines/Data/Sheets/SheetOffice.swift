import Foundation

// LibreOffice (soffice) as an OPTIONAL helper of the sheet family: it reads Excel files the native BIFF8 reader gives up on, and it renders PDFs that keep the look of an
// XLSX / XLS / ODS (fonts, colours, widths). Every run uses its own throw-away profile folder, so it never touches the user's LibreOffice settings and two runs never fight
// over a lock. Nothing here is required: without LibreOffice the native routes are used.

enum SheetOffice {
    struct Result {
        var file: URL
        /// Temp folder holding the profile and the output; the caller removes it with `AppPaths.removeTemp`.
        var workDirectory: URL
    }

    static var isAvailable: Bool { ToolLocator.shared.has(.soffice) }

    static func arguments(profile: URL, outDir: URL, input: URL, target: String) -> [String] {
        ["--headless", "--norestore", "--nolockcheck", "--nodefault", "--nofirststartwizard",
         "-env:UserInstallation=" + profile.absoluteString, "--convert-to", target, "--outdir", outDir.path, input.path]
    }

    private static func prepare(_ input: URL, target: String) -> (work: URL, profile: URL, out: URL, expected: URL) {
        let work = AppPaths.makeTempDirectory(purpose: "office")
        let profile = work.appendingPathComponent("profile", isDirectory: true)
        let out = work.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let base = input.deletingPathExtension().lastPathComponent
        return (work, profile, out, out.appendingPathComponent("\(base).\(target)"))
    }

    /// Blocking conversion for the readers (they are synchronous). Returns nil when LibreOffice is missing or produced nothing.
    static func convertSync(_ input: URL, to target: String, timeout: TimeInterval = 120) -> URL? {
        guard let soffice = ToolLocator.shared.url(.soffice) else { return nil }
        let p = prepare(input, target: target)
        _ = SyncProcess.run(soffice, arguments(profile: p.profile, outDir: p.out, input: input, target: target), timeout: timeout)
        if FileManager.default.fileExists(atPath: p.expected.path) { return p.expected }
        AppPaths.removeTemp(p.work)
        return nil
    }

    /// Cancellable conversion inside a job (the process joins the job's pause / cancel set).
    static func convert(_ input: URL, to target: String, ctx: OperationContext) async throws -> Result {
        let soffice = try ctx.tools.require(.soffice)
        let p = prepare(input, target: target)
        do {
            try await ctx.runProcess(soffice, arguments(profile: p.profile, outDir: p.out, input: input, target: target), allowNonZeroExit: true)
            guard FileManager.default.fileExists(atPath: p.expected.path) else {
                throw ConversionError.message(L10n("LibreOffice could not convert the file. Is it intact and not password-protected?",
                                                   "LibreOffice не удалось конвертировать файл. Возможно, он повреждён или защищён паролем."))
            }
            return Result(file: p.expected, workDirectory: p.work)
        } catch {
            AppPaths.removeTemp(p.work)
            throw error
        }
    }
}
