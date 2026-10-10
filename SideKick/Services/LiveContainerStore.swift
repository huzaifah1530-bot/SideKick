import Foundation

extension Notification.Name {
    static let sideKickLiveContainerDidChange = Notification.Name("SideKick.LiveContainerDidChange")
}

protocol LiveContainerDirectoryAccess: Sendable {
    func bookmark(for directory: URL) throws -> Data
    func scan(bookmark: Data, connectionID: UUID) throws -> (LiveContainerScan, Data?)
}

// Cancellation releases the caller immediately even if a file provider is stalled.
// The read worker owns its scope until it exits and can never publish late results.
private final class LiveContainerReadOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(LiveContainerScan, Data?), Error>?
    private var result: Result<(LiveContainerScan, Data?), Error>?
    private var worker: Task<Void, Never>?
    private var cancelProvider: (@Sendable () -> Void)?

    func begin(_ continuation: CheckedContinuation<(LiveContainerScan, Data?), Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func attach(_ worker: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished { self.worker = worker }
        lock.unlock()
        if finished { worker.cancel() }
    }
    func coordinateCancellation(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        let finished = result != nil
        if !finished { cancelProvider = callback }
        lock.unlock()
        if finished { callback() }
    }
    func finish(_ result: Result<(LiveContainerScan, Data?), Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        worker = nil
        cancelProvider = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
    func cancel() {
        lock.lock()
        let worker = self.worker
        let callback = cancelProvider
        lock.unlock()
        finish(.failure(CancellationError()))
        worker?.cancel()
        callback?()
    }
}

private enum LiveContainerReadContext {
    @TaskLocal static var operation: LiveContainerReadOperation?

    static func scan(access: any LiveContainerDirectoryAccess, bookmark: Data, id: UUID) async throws -> (LiveContainerScan, Data?) {
        let operation = LiveContainerReadOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.begin(continuation)
                let worker = Task.detached(priority: .utility) {
                    let result = Result {
                        try $operation.withValue(operation) {
                            try Task.checkCancellation()
                            return try access.scan(bookmark: bookmark, connectionID: id)
                        }
                    }
                    operation.finish(result)
                }
                operation.attach(worker)
            }
        } onCancel: { operation.cancel() }
    }
}

struct SystemLiveContainerDirectoryAccess: LiveContainerDirectoryAccess {
    func bookmark(for directory: URL) throws -> Data {
        #if os(Linux)
        return Data(directory.path.utf8)
        #else
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        return try directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    func scan(bookmark: Data, connectionID: UUID) throws -> (LiveContainerScan, Data?) {
        #if os(Linux)
        guard let path = String(data: bookmark, encoding: .utf8) else { throw LiveContainerError.accessRevoked }
        return (try LiveContainerScanner.scan(directory: URL(fileURLWithPath: path), connectionID: connectionID), nil)
        #else
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Local in-container URLs need no additional security scope; actual reads
        // determine whether the resolved resource is still accessible.
        var coordinationError: NSError?
        var result: Result<LiveContainerScan, Error>?
        let coordinator = NSFileCoordinator()
        LiveContainerReadContext.operation?.coordinateCancellation { coordinator.cancel() }
        try Task.checkCancellation()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try LiveContainerScanner.scan(directory: coordinated, connectionID: connectionID) }
        }
        try Task.checkCancellation()
        if let coordinationError { throw coordinationError }
        guard let result else { throw LiveContainerError.accessRevoked }
        let scan = try result.get()
        let renewed = stale ? try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return (scan, renewed)
        #endif
    }
}

actor LiveContainerStore {
    static let shared = LiveContainerStore()
    private let fileURL: URL
    private let access: any LiveContainerDirectoryAccess
    private var scans: [UUID: UUID] = [:]
    private var links: [UUID: UUID] = [:]
    private var accessRevisions: [UUID: UUID] = [:]

    init(fileURL: URL? = nil, access: any LiveContainerDirectoryAccess = SystemLiveContainerDirectoryAccess()) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? support.appendingPathComponent("LiveContainer/state.json")
        self.access = access
    }

    func snapshot() throws -> LiveContainerState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LiveContainerState() }
        let state = try JSONDecoder().decode(LiveContainerState.self, from: Data(contentsOf: fileURL))
        guard state.schemaVersion == 1 else { throw LiveContainerError.unsupportedSchema }
        return state
    }

    @discardableResult
    func link(directory: URL, name: String, scheme: String, storageKind: LiveContainerStorageKind, replacing id: UUID? = nil) async throws -> LiveContainerConnection {
        _ = try LiveContainerLaunch.url(scheme: scheme)
        let access = self.access
        let connectionID = id ?? UUID()
        let generation = UUID()
        links[connectionID] = generation
        defer { if links[connectionID] == generation { links[connectionID] = nil } }
        let bookmark = try access.bookmark(for: directory)
        // Validate before accepting access or replacing a working connection.
        let (scan, renewed) = try await LiveContainerReadContext.scan(access: access, bookmark: bookmark, id: connectionID)
        try Task.checkCancellation()
        guard links[connectionID] == generation else { throw CancellationError() }
        var state = try snapshot()
        let old = state.connections.first { $0.id == connectionID }
        // Reconnect intentionally preserves the connection identity and associations.
        // Changing to another directory uses a new connection ID in the UI.
        var connection = LiveContainerConnection(id: connectionID, name: name.isEmpty ? "LiveContainer" : name,
            scheme: scheme.lowercased(), storageKind: storageKind, bookmark: renewed ?? bookmark,
            lastSuccessfulScan: .now, error: nil, warnings: scan.warnings)
        if storageKind == .snapshot { connection.warnings.insert("This is an exported snapshot. It does not prove which version is currently installed.", at: 0) }
        state.connections.removeAll { $0.id == connectionID }
        state.connections.append(connection)
        merge(scan, into: &state, connectionID: connectionID)
        if old != nil { scans[connectionID] = nil }
        try save(state)
        accessRevisions[connectionID] = UUID()
        return connection
    }

    func rescan(_ id: UUID) async throws {
        guard scans[id] == nil else { throw LiveContainerError.busy }
        let state = try snapshot()
        guard let connection = state.connections.first(where: { $0.id == id }), let bookmark = connection.bookmark else {
            throw LiveContainerError.disconnected
        }
        let generation = UUID()
        scans[id] = generation
        defer { if scans[id] == generation { scans[id] = nil } }
        let access = self.access
        do {
            let (scan, renewed) = try await LiveContainerReadContext.scan(access: access, bookmark: bookmark, id: id)
            try Task.checkCancellation()
            var current = try snapshot()
            guard scans[id] == generation,
                  let index = current.connections.firstIndex(where: { $0.id == id && $0.bookmark == bookmark }) else { return }
            current.connections[index].bookmark = renewed ?? bookmark
            current.connections[index].lastSuccessfulScan = .now
            current.connections[index].error = nil
            current.connections[index].warnings = scan.warnings
            if connection.storageKind == .snapshot { current.connections[index].warnings.insert("Exported snapshot; installed versions are not verified.", at: 0) }
            merge(scan, into: &current, connectionID: id)
            try save(current)
        } catch {
            if !(error is CancellationError), scans[id] == generation {
                var current = try snapshot()
                if let index = current.connections.firstIndex(where: { $0.id == id && $0.bookmark == bookmark }) {
                    current.connections[index].error = error.localizedDescription
                    try save(current)
                }
            }
            throw error
        }
    }

    func disconnect(_ id: UUID) throws {
        var state = try snapshot()
        guard let index = state.connections.firstIndex(where: { $0.id == id }) else { return }
        state.connections[index].bookmark = nil
        state.connections[index].error = nil
        scans[id] = nil
        links[id] = nil
        try save(state)
        accessRevisions[id] = UUID()
    }

    @discardableResult
    func forget(_ id: UUID) throws -> [String] {
        var state = try snapshot()
        let ids = state.apps.filter { $0.connectionID == id }.map(\.id)
        state.connections.removeAll { $0.id == id }
        state.apps.removeAll { $0.connectionID == id }
        scans[id] = nil
        links[id] = nil
        try save(state)
        accessRevisions[id] = UUID()
        return ids
    }

    func launchURL(for guestID: String) async throws -> URL {
        let before = try snapshot()
        guard let guest = before.apps.first(where: { $0.id == guestID }) else { throw LiveContainerError.guestMissing }
        guard let connection = before.connections.first(where: { $0.id == guest.connectionID }),
              let bookmark = connection.bookmark else { throw LiveContainerError.disconnected }
        guard connection.storageKind != .snapshot else { throw LiveContainerError.guestMissing }
        let accessRevision = accessRevisions[connection.id]
        // Launch validates local files independently of background catalogue scans.
        // It neither waits for a repository check nor takes its scan ownership.
        let (scan, _) = try await LiveContainerReadContext.scan(access: access, bookmark: bookmark, id: connection.id)
        try Task.checkCancellation()
        let state = try snapshot()
        // Access may have been disconnected, forgotten, or replaced during the read.
        guard state.apps.contains(where: { $0.id == guestID }),
              let linked = state.connections.first(where: { $0.id == connection.id }),
              linked.isConnected, accessRevisions[connection.id] == accessRevision,
              linked.scheme == connection.scheme,
              linked.storageKind == connection.storageKind, links[connection.id] == nil else {
            throw LiveContainerError.disconnected
        }
        guard let current = scan.apps.first(where: { $0.id == guestID }),
              current.isAvailable, current.warning == nil else { throw LiveContainerError.guestMissing }
        return try LiveContainerLaunch.url(scheme: connection.scheme, folder: current.folder)
    }

    private func merge(_ scan: LiveContainerScan, into state: inout LiveContainerState, connectionID: UUID) {
        let found = Set(scan.apps.map(\.id))
        let failed = Set(scan.failedFolders)
        for index in state.apps.indices where state.apps[index].connectionID == connectionID && !found.contains(state.apps[index].id) {
            state.apps[index].isAvailable = false
            state.apps[index].warning = failed.contains(state.apps[index].folder) ? "This bundle could not be read. Previous metadata is retained." : "Not found in the last complete scan."
        }
        for app in scan.apps {
            if let index = state.apps.firstIndex(where: { $0.id == app.id }) { state.apps[index] = app }
            else { state.apps.append(app) }
        }
    }

    private func save(_ state: LiveContainerState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: .sideKickLiveContainerDidChange, object: nil)
    }
}
