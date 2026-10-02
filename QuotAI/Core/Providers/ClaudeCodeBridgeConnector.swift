import Foundation

/// Paths and helper script for the Claude Code "bridge".
///
/// Claude Code documents a `statusLine` setting: it runs a user-configured command and pipes a JSON
/// document to its stdin. For Claude Pro/Max subscribers, that JSON contains `rate_limits.five_hour`,
/// `rate_limits.seven_day` (each with `used_percentage` and `resets_at`). The helper script below only
/// copies that JSON to a local file, which QuotAI reads. No credential is involved.
/// Source: https://code.claude.com/docs/en/statusline (checked 2026-09-24).
enum ClaudeBridge {
    static let directoryName = "QuotAI"
    static let dataFileName = "claude-code-status.json"
    static let scriptFileName = "quotai-claude-statusline.sh"

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static var defaultDataFileURL: URL { supportDirectory.appendingPathComponent(dataFileName) }
    static var defaultScriptURL: URL { supportDirectory.appendingPathComponent(scriptFileName) }

    /// The script is intentionally tiny and dependency-free (no jq, no python).
    static func scriptContents(dataFile: URL) -> String {
        let directory = dataFile.deletingLastPathComponent().path
        let file = dataFile.path
        return """
        #!/bin/sh
        # QuotAI bridge for Claude Code's statusLine.
        # Copies the JSON that Claude Code sends on stdin to a local file read by QuotAI.
        # It prints nothing, so it adds nothing to your status line.
        umask 077
        dir=\(shellQuote(directory))
        file=\(shellQuote(file))
        mkdir -p "$dir" || exit 0
        tmp="$file.$$"
        cat > "$tmp" && mv "$tmp" "$file"
        exit 0

        """
    }

    /// The settings.json snippet the user pastes into ~/.claude/settings.json (QuotAI never edits it).
    static func settingsSnippet(scriptURL: URL) -> String {
        let command = shellQuote(scriptURL.path)
        let object: [String: Any] = ["statusLine": ["type": "command", "command": command]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes the helper script (executable, owner-only write). Returns its URL.
    @discardableResult
    static func installScript(scriptURL: URL = defaultScriptURL, dataFile: URL = defaultDataFileURL) throws -> URL {
        let directory = scriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try scriptContents(dataFile: dataFile).write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    static func isScriptInstalled(scriptURL: URL = defaultScriptURL) -> Bool {
        FileManager.default.isExecutableFile(atPath: scriptURL.path)
    }
}

/// Reads the rate limits of a Claude Pro/Max subscription from the file written by the bridge script.
struct ClaudeCodeBridgeConnector: UsageConnector {
    let kind: ProviderKind = .claudeCode
    let fileURL: URL
    /// Beyond this age, the file is flagged as possibly outdated.
    var staleAfter: TimeInterval = 15 * 60
    var maxFileSize = 1_000_000

    struct Payload: Decodable {
        struct Window: Decodable {
            let usedPercentage: Double?
            let resetsAt: Double?
        }
        struct RateLimits: Decodable {
            let fiveHour: Window?
            let sevenDay: Window?
            let spendLimit: Window?
        }
        let rateLimits: RateLimits?
    }

    func fetch(_ context: FetchContext) async throws -> UsageSnapshot {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { throw ProviderError.bridgeNotInstalled }

        let attributes = try? manager.attributesOfItem(atPath: fileURL.path)
        if let size = attributes?[.size] as? Int, size > maxFileSize { throw ProviderError.unexpectedResponse }
        let modified = attributes?[.modificationDate] as? Date

        guard let data = try? Data(contentsOf: fileURL) else { throw ProviderError.unexpectedResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data) else { throw ProviderError.unexpectedResponse }

        guard let limits = payload.rateLimits else {
            throw ProviderError.noData(reason: "Claude Code sent no rate limits. They only appear for Claude Pro/Max subscribers, after the first response of a session.")
        }

        var metrics: [UsageMetric] = []
        var notes: [String] = []
        let windows: [(id: String, label: String, window: Payload.Window?)] = [
            ("five_hour", "Session limit (5 h)", limits.fiveHour),
            ("seven_day", "Weekly limit", limits.sevenDay),
            ("spend_limit", "Spend limit", limits.spendLimit)
        ]
        var expired = 0
        for entry in windows {
            guard let window = entry.window, let used = window.usedPercentage, used.isFinite else { continue }
            let resetsAt = window.resetsAt.map { Date(timeIntervalSince1970: $0) }
            if let resetsAt, resetsAt <= context.now {
                // The window has reset since the file was written: the old percentage is no longer valid.
                expired += 1
                continue
            }
            metrics.append(UsageMetric(id: entry.id, label: entry.label, value: used, limit: nil,
                                       format: .percent, resetsAt: resetsAt, source: .official))
        }

        if metrics.isEmpty {
            if expired > 0 {
                throw ProviderError.noData(reason: "The limit windows have reset since Claude Code last reported. Use Claude Code to get fresh values.")
            }
            throw ProviderError.noData(reason: "No usable limit found in Claude Code's data.")
        }
        if expired > 0 {
            notes.append("Some windows have reset since the last report and are hidden.")
        }
        if let modified, context.now.timeIntervalSince(modified) > staleAfter {
            notes.append("Last data received from Claude Code is more than \(Int(staleAfter / 60)) minutes old.")
        }
        return UsageSnapshot(fetchedAt: context.now, dataAsOf: modified, metrics: metrics, notes: notes)
    }
}
