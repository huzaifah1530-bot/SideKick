import Foundation

/// Uses a session delegate so download progress arrives during the transfer.
/// The caller owns the returned temporary file and must remove it after importing.
///
/// Transfers run in a background `URLSession`, so iOS keeps downloading while SideKick is in
/// the background or the screen is locked. Background sessions follow redirects without asking
/// the delegate, so redirects are resolved first: that keeps a GitHub token from being sent on to
/// a different host (such as GitHub's file storage). Needs proper testing on long downloads.
final class ProgressFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (GitHubDownloadProgress) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    // These two values are only accessed on the session's serial delegate queue.
    private var fileURL: URL?
    private var fileError: Error?

    init(onProgress: @escaping @Sendable (GitHubDownloadProgress) -> Void) {
        self.onProgress = onProgress
    }

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        onProgress(GitHubDownloadProgress(bytesWritten: 0, totalBytesExpected: nil))
        let resolved = try await RedirectResolver.resolve(request)
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.background(
                    withIdentifier: "sidekick.download.\(UUID().uuidString)")
                configuration.isDiscretionary = false
                configuration.sessionSendsLaunchEvents = false
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: resolved)
                self.task = task
                task.resume()
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(GitHubDownloadProgress(bytesWritten: totalBytesWritten,
            totalBytesExpected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sidekick-github-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).ipa")
        do {
            // URLSession deletes `location` after this callback returns.
            try FileManager.default.moveItem(at: location, to: destination)
            fileURL = destination
        } catch { fileError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        let wasCancelled = cancelled
        lock.unlock()
        defer { session.finishTasksAndInvalidate() }
        let failure: Error? = wasCancelled ? CancellationError() : (error ?? fileError)
        if let failure {
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            continuation?.resume(throwing: failure)
        } else if let fileURL, let response = task.response {
            continuation?.resume(returning: (fileURL, response))
        } else {
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            continuation?.resume(throwing: URLError(.cannotCreateFile))
        }
    }
}

/// Follows up to five HTTPS redirects with HEAD requests, dropping Authorization whenever the
/// host changes, and returns the request for the final location.
private enum RedirectResolver {
    static func resolve(_ request: URLRequest) async throws -> URLRequest {
        var current = request
        let delegate = BlockRedirects()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        for _ in 0..<5 {
            var probe = current
            probe.httpMethod = "HEAD"
            let response: URLResponse
            do { (_, response) = try await session.data(for: probe) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Some hosts reject HEAD. Download the current URL directly instead.
                return current
            }
            guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: current.url)?.absoluteURL else {
                return current
            }
            guard next.scheme?.lowercased() == "https" else { throw URLError(.secureConnectionFailed) }
            var redirected = current
            redirected.url = next
            if next.host?.lowercased() != current.url?.host?.lowercased() {
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            current = redirected
        }
        return current
    }

    private final class BlockRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
