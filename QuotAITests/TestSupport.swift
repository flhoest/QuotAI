import Foundation
@testable import QuotAI

/// HTTP stub: routes by URL path and records every request.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> HTTPResponse
    private let lock = NSLock()
    private var handler: Handler
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.lock(); recorded.append(request); let handler = handler; lock.unlock()
        return try handler(request)
    }

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(status: status, data: data, headers: headers)
    }
}

/// Scriptable connector for store tests.
final class FakeConnector: UsageConnector, @unchecked Sendable {
    let kind: ProviderKind
    private let lock = NSLock()
    private var results: [Result<UsageSnapshot, ProviderError>]
    private(set) var callCount = 0
    var delay: TimeInterval = 0
    private(set) var lastSecret: String?

    init(kind: ProviderKind, results: [Result<UsageSnapshot, ProviderError>]) {
        self.kind = kind
        self.results = results
    }

    func fetch(_ context: FetchContext) async throws -> UsageSnapshot {
        lock.lock()
        callCount += 1
        lastSecret = context.secret
        let result = results.count > 1 ? results.removeFirst() : results[0]
        let delay = self.delay
        lock.unlock()
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try result.get()
    }
}

enum Fixtures {
    /// 2026-09-24T12:00:00Z
    static let now = Date(timeIntervalSince1970: 1_790_251_200)

    static func snapshot(percent: Double = 42, at date: Date = now) -> UsageSnapshot {
        UsageSnapshot(fetchedAt: date, metrics: [
            UsageMetric(id: "five_hour", label: "Session", value: percent, limit: nil, format: .percent,
                        resetsAt: date.addingTimeInterval(3600), source: .official)
        ])
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuotAITests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
