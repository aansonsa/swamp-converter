import Foundation

// The default network layer of the yt-dlp installer. Only `YtDlpToolManager` uses it, only after `NetworkGate.authorize`, and only for the
// official GitHub release files. It is deliberately small and strict:
//   * https only (tests pass `allowedSchemes` with "file" to exercise the code path without a network)
//   * redirects are followed only to github.com / githubusercontent.com over https
//   * ephemeral session: no cookies, no credentials, no cache; HTTP errors become calm messages

struct URLSessionDownloaderHTTP: DownloaderHTTP {
    var allowedSchemes: Set<String> = ["https"]
    var requestTimeout: TimeInterval = 30
    /// Largest in-memory response (the checksum file is a few hundred bytes).
    var maxDataBytes = 4_000_000

    static func isAllowedHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "github.com" || h.hasSuffix(".github.com") || h == "githubusercontent.com" || h.hasSuffix(".githubusercontent.com")
    }

    private func check(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            throw ConversionError.message(L10n("Only secure (https) addresses are allowed here.", "Здесь разрешены только защищённые адреса (https)."))
        }
        if scheme != "file", !Self.isAllowedHost(url.host) {
            throw ConversionError.message(L10n("Only the official yt-dlp release on GitHub can be used.", "Можно использовать только официальный релиз yt-dlp на GitHub."))
        }
    }

    private func makeSession(delegate: URLSessionDelegate?) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = requestTimeout
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": "SwampConverter/1.0 (yt-dlp installer)"]
        return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }

    private func validate(_ response: URLResponse?) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConversionError.message(L10n("The server answered with error \(http.statusCode). Try again later.",
                                               "Сервер ответил ошибкой \(http.statusCode). Повторите позже."))
        }
    }

    func data(from url: URL) async throws -> Data {
        try check(url)
        let guardDelegate = RedirectGuard()
        let session = makeSession(delegate: guardDelegate)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            try validate(response)
            guard data.count <= maxDataBytes else {
                throw ConversionError.message(L10n("The answer was unexpectedly large and was ignored.", "Ответ неожиданно большой и был проигнорирован."))
            }
            return data
        } catch let e as URLError where e.code == .cancelled && !Task.isCancelled {
            throw ConversionError.message(guardDelegate.refusal)
        }
    }

    func finalURL(of url: URL) async throws -> URL {
        try check(url)
        let session = makeSession(delegate: RedirectGuard())
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        try validate(response)
        return response.url ?? url
    }

    func download(from url: URL, to destination: URL, progress: @Sendable (Double) -> Void) async throws {
        try check(url)
        let job = DownloadJob(destination: destination)
        let session = makeSession(delegate: job)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        job.task = task
        try await withoutActuallyEscaping(progress) { escapable in
            job.progress = escapable
            defer { job.progress = nil }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    job.continuation = c
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }
    }
}

/// Refuses redirects that leave the official GitHub hosts or drop to plain http.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _refused = false
    var refusal: L10n {
        L10n("The download was redirected to an address that is not allowed and was stopped.", "Загрузка была перенаправлена на недопустимый адрес и остановлена.")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if request.url?.scheme?.lowercased() == "https", URLSessionDownloaderHTTP.isAllowedHost(request.url?.host) {
            completionHandler(request)
        } else {
            lock.lock(); _refused = true; lock.unlock()
            completionHandler(nil)
        }
    }
}

/// One `URLSessionDownloadTask` whose result is moved to `destination` inside the delegate callback (the temporary file vanishes afterwards).
private final class DownloadJob: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    var progress: (@Sendable (Double) -> Void)?
    var continuation: CheckedContinuation<Void, Error>?
    var task: URLSessionDownloadTask?
    private let lock = NSLock()
    private var failure: Error?
    private let redirects = RedirectGuard()

    init(destination: URL) { self.destination = destination }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            setFailure(ConversionError.message(L10n("The server answered with error \(http.statusCode). Try again later.",
                                                    "Сервер ответил ошибкой \(http.statusCode). Повторите позже.")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            setFailure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = continuation; continuation = nil
        let f = failure
        lock.unlock()
        if let error {
            if (error as? URLError)?.code == .cancelled { c?.resume(throwing: CancellationError()) } else { c?.resume(throwing: error) }
        } else if let f {
            c?.resume(throwing: f)
        } else if let http = task.response as? HTTPURLResponse, (300..<400).contains(http.statusCode) {
            c?.resume(throwing: ConversionError.message(redirects.refusal))
        } else {
            c?.resume()
        }
    }

    private func setFailure(_ e: Error) { lock.lock(); failure = e; lock.unlock() }
}
