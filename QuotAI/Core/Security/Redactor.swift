import Foundation
import os

/// Masks anything that looks like a secret before text is logged or displayed.
enum Redactor {
    private static let patterns: [NSRegularExpression] = {
        let sources = [
            #"sk-[A-Za-z0-9_\-]{6,}"#,          // Anthropic (sk-ant-…), OpenAI (sk-…, sk-admin-…)
            #"AIza[0-9A-Za-z_\-]{10,}"#,        // Google keys
            #"(?i)bearer\s+[A-Za-z0-9._\-~+/=]+"#,
            #"(?i)(x-api-key|x-goog-api-key|authorization)\s*[:=]\s*\S+"#,
            #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.?[A-Za-z0-9_\-]*"# // JWT
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static let mask = "[redacted]"

    static func redact(_ text: String, knownSecrets: [String] = []) -> String {
        var result = text
        for secret in knownSecrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: mask)
        }
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: mask)
        }
        return result
    }
}

/// Application log. Every message goes through `Redactor`; response bodies are never logged.
enum AppLog {
    private static let logger = Logger(subsystem: "com.quotai.QuotAI", category: "app")

    static func info(_ message: String) {
        logger.info("\(Redactor.redact(message), privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(Redactor.redact(message), privacy: .public)")
    }
}
