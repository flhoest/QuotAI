import XCTest
@testable import QuotAI

/// Regression test for a real bug: `xcodebuild test` hosts QuotAITests inside a genuinely launched
/// QuotAI.app (TEST_HOST/BUNDLE_LOADER), so `applicationDidFinishLaunching` runs for real. The
/// original guard only checked `XCTestConfigurationFilePath`, which Xcode.app sets but the
/// `xcodebuild` CLI's hosted-app launch does not — so every `xcodebuild test` run actually started
/// scheduling, spawned the real `codex` CLI, and wrote to the user's real
/// `~/Library/Application Support/QuotAI`. This asserts the detection that fixed it.
final class AppDelegateTests: XCTestCase {
    func testDetectsItIsRunningUnderXCTest() {
        // This assertion is only meaningful because it runs inside XCTest itself: if the
        // detection ever regresses, this is the test that must fail.
        XCTAssertTrue(AppDelegate.isRunningUnderXCTest)
    }
}
