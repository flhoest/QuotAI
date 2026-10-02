import SwiftUI
import AppKit

@main
struct QuotAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("QuotAI", systemImage: "gauge.with.dots.needle.50percent") {
            MenuBarContent(environment: AppEnvironment.shared)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when this process is hosting XCTest — whether launched by Xcode (which sets
    /// `XCTestConfigurationFilePath`) or by `xcodebuild test` on the command line, which instead
    /// injects the XCTest bundle via `TEST_HOST`/`BUNDLE_LOADER` without that env var. Checking
    /// for the `XCTestCase` class actually being loaded in the process catches both: tests must
    /// never trigger real scheduling, real network/subprocess calls, or writes under
    /// `~/Library/Application Support/QuotAI`.
    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isRunningUnderXCTest { return }
        // Accessory app: no Dock icon, no main menu bar (also set through LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in AppEnvironment.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
