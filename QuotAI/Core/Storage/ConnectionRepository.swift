import Foundation

/// Persists non-sensitive connection settings (never secrets) as JSON in Application Support.
protocol ConnectionRepository: Sendable {
    func load() -> [Connection]?
    func save(_ connections: [Connection])
}

struct FileConnectionRepository: ConnectionRepository {
    let fileURL: URL

    init(directory: URL = ClaudeBridge.supportDirectory) {
        fileURL = directory.appendingPathComponent("connections.json")
    }

    func load() -> [Connection]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([Connection].self, from: data)
    }

    func save(_ connections: [Connection]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(connections) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        AtomicFileWrite.write(data, to: fileURL)
    }
}

/// A resilient stand-in for `Data.write(options: .atomic)`, which can transiently fail (ENOENT
/// on its own temp file) under heavy concurrent filesystem load in the sandboxed temp directory —
/// observed in this project's own test runs. These are best-effort local cache writes with no
/// caller-visible error contract, so one quiet retry is safe and avoids a rare, environmental flake.
enum AtomicFileWrite {
    static func write(_ data: Data, to url: URL, retries: Int = 2) {
        var lastError: Error?
        for attempt in 0...retries {
            do {
                try data.write(to: url, options: .atomic)
                return
            } catch {
                lastError = error
                if attempt < retries { Thread.sleep(forTimeInterval: 0.02) }
            }
        }
        AppLog.error("Local cache write failed after retries: \(String(describing: lastError))")
    }
}

/// Local cache of the last successful snapshots, so the UI has something to show at launch or offline.
protocol SnapshotCache: Sendable {
    func load() -> [UUID: UsageSnapshot]
    func save(_ snapshots: [UUID: UsageSnapshot])
}

struct FileSnapshotCache: SnapshotCache {
    let fileURL: URL

    init(directory: URL = ClaudeBridge.supportDirectory) {
        fileURL = directory.appendingPathComponent("snapshot-cache.json")
    }

    func load() -> [UUID: UsageSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: UsageSnapshot].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    func save(_ snapshots: [UUID: UsageSnapshot]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodable = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.uuidString, $0.value) })
        guard let data = try? encoder.encode(encodable) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        AtomicFileWrite.write(data, to: fileURL)
    }
}

final class InMemoryConnectionRepository: ConnectionRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Connection]?
    init(_ initial: [Connection]? = nil) { stored = initial }
    func load() -> [Connection]? { lock.lock(); defer { lock.unlock() }; return stored }
    func save(_ connections: [Connection]) { lock.lock(); stored = connections; lock.unlock() }
}

final class InMemorySnapshotCache: SnapshotCache, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: UsageSnapshot] = [:]
    func load() -> [UUID: UsageSnapshot] { lock.lock(); defer { lock.unlock() }; return stored }
    func save(_ snapshots: [UUID: UsageSnapshot]) { lock.lock(); stored = snapshots; lock.unlock() }
}
