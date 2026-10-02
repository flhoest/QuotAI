import Foundation

/// Finds the `codex` CLI executable. A GUI app launched from Finder/LaunchServices does not
/// inherit a Terminal's PATH (Homebrew, npm, etc. are typically missing from it), so a plain
/// `Process` + `env` lookup is not reliable here. This checks the process's own PATH first
/// (covers the case where QuotAI itself was launched from a shell), then a list of common
/// install locations for `codex` (covers the common GUI-launch case).
enum CodexCLILocator {
    static let commonInstallPaths: [String] = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex",
        NSHomeDirectory() + "/.local/bin/codex",
        NSHomeDirectory() + "/bin/codex",
        NSHomeDirectory() + "/.npm-global/bin/codex",
        NSHomeDirectory() + "/.codex/bin/codex"
    ]

    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                       fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        if let pathVariable = environment["PATH"] {
            for directory in pathVariable.split(separator: ":") where !directory.isEmpty {
                let candidate = String(directory) + "/codex"
                if fileExists(candidate) { return URL(fileURLWithPath: candidate) }
            }
        }
        for candidate in commonInstallPaths where fileExists(candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}
