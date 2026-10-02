import Foundation

/// One round trip to the `codex` CLI's local JSON-RPC protocol: handshake, then
/// `account/rateLimits/read`. Returns the raw `result` object of that response as `Data`,
/// for the caller to decode into typed metrics.
protocol CodexAppServerSession: Sendable {
    func fetchRateLimits(timeout: TimeInterval) async throws -> Data
}

/// Spawns `codex app-server`, speaks newline-delimited JSON-RPC 2.0 over its stdio, and always
/// terminates the process afterwards. The wire format (no `Content-Length` framing, one JSON
/// object per line) and the `account/rateLimits/read` method were verified with a live call
/// against the installed `codex` CLI; see `ProviderDescriptor.codex` for the caveat that this
/// protocol has no public documentation page and may change on a codex CLI update.
struct ProcessCodexAppServerSession: CodexAppServerSession {
    let executableURL: URL
    var clientVersion: String = "1.0"

    func fetchRateLimits(timeout: TimeInterval) async throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Without a termination handler (or a call to waitUntilExit), Foundation may leave the
        // process as a zombie until QuotAI itself exits.
        process.terminationHandler = { _ in }

        do {
            try process.run()
        } catch {
            throw ProviderError.noData(reason: "Could not launch the codex CLI at \(executableURL.path). Reinstall it and make sure it runs from a terminal.")
        }
        defer { if process.isRunning { process.terminate() } }

        let queue = LineQueue()
        let readHandle = stdout.fileHandleForReading
        let readerThread = Thread {
            var buffer = Data()
            let newline = UInt8(ascii: "\n")
            while true {
                let chunk = readHandle.availableData
                if chunk.isEmpty { queue.finish(); return }
                buffer.append(chunk)
                while let index = buffer.firstIndex(of: newline) {
                    let line = buffer.subdata(in: buffer.startIndex..<index)
                    buffer.removeSubrange(buffer.startIndex...index)
                    queue.push(line)
                }
            }
        }
        readerThread.name = "QuotAI.CodexAppServer.Reader"
        readerThread.start()

        func writeLine(_ string: String) throws {
            var data = Data(string.utf8)
            data.append(UInt8(ascii: "\n"))
            do {
                try stdin.fileHandleForWriting.write(contentsOf: data)
            } catch {
                throw ProviderError.unexpectedResponse
            }
        }

        let deadline = Date().addingTimeInterval(timeout)

        // 1) Handshake: initialize (request) then initialized (notification, no id, no reply).
        try writeLine(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"QuotAI","version":"\#(clientVersion)"}}}"#)
        _ = try await Self.awaitResult(forId: 1, queue: queue, deadline: deadline)
        try writeLine(#"{"method":"initialized","params":null}"#)

        // 2) The call we actually want.
        try writeLine(#"{"id":2,"method":"account/rateLimits/read","params":null}"#)
        return try await Self.awaitResult(forId: 2, queue: queue, deadline: deadline)
    }

    /// Reads lines until one whose `"id"` matches `target`, skipping notifications and replies
    /// to other in-flight requests (the app-server interleaves both on the same stream).
    private static func awaitResult(forId target: Int, queue: LineQueue, deadline: Date) async throws -> Data {
        while true {
            if Date() >= deadline { throw ProviderError.timeout }
            guard let outer = queue.pop() else {
                try await Task.sleep(nanoseconds: 20_000_000)
                try Task.checkCancellation()
                continue
            }
            guard let line = outer else {
                throw ProviderError.unexpectedResponse  // stdout closed before we got our answer
            }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue  // not a parseable JSON object; skip rather than fail the whole call
            }
            guard let id = object["id"] as? Int, id == target else {
                continue  // a notification, or the reply to a different request
            }
            if let result = object["result"] as? [String: Any] {
                return try JSONSerialization.data(withJSONObject: result)
            }
            if let error = object["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "unknown error"
                if message.localizedCaseInsensitiveContains("auth") || message.localizedCaseInsensitiveContains("log in")
                    || message.localizedCaseInsensitiveContains("login") {
                    throw ProviderError.unauthorized(hint: "Run `codex login` in a terminal, then refresh.")
                }
                throw ProviderError.unexpectedResponse
            }
            throw ProviderError.unexpectedResponse
        }
    }
}

/// Thread-safe line buffer bridging the blocking reader thread into async code.
private final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    private var isFinished = false

    func push(_ line: Data) { lock.lock(); lines.append(line); lock.unlock() }
    func finish() { lock.lock(); isFinished = true; lock.unlock() }

    /// `nil` = nothing available yet; `.some(nil)` = stream ended; `.some(line)` = a line is ready.
    func pop() -> Data?? {
        lock.lock(); defer { lock.unlock() }
        if !lines.isEmpty { return .some(lines.removeFirst()) }
        return isFinished ? .some(nil) : nil
    }
}
