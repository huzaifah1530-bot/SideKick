import Foundation

/// Uses a session delegate so download progress arrives during the transfer.
/// The caller owns the returned temporary file and must remove it after importing.
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
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                self.task = task
                task.resume()
                lock.unlock()
                onProgress(GitHubDownloadProgress(bytesWritten: 0, totalBytesExpected: nil))
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

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else { completionHandler(nil); return }
        var redirected = request
        if request.url?.host?.lowercased() != task.originalRequest?.url?.host?.lowercased() {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
}
