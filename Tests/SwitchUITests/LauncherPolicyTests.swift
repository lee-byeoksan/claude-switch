import SwitchUI
import XCTest

final class LauncherPolicyTests: XCTestCase {
    func testShowsPanelAtStartWhenClaudeNotRunning() {
        var policy = LauncherPolicy()
        XCTAssertEqual(policy.handle(.appStarted(claudeRunning: false)), [.showPanel])
        var running = LauncherPolicy()
        XCTAssertEqual(running.handle(.appStarted(claudeRunning: true)), [])
    }

    func testClaudeLaunchHidesVisiblePanelOnly() {
        var policy = LauncherPolicy()
        XCTAssertEqual(policy.handle(.claudeLaunched), [])
        _ = policy.handle(.reopenRequested)
        XCTAssertEqual(policy.handle(.claudeLaunched), [.hidePanel])
    }

    func testLaunchDuringSwitchKeepsPanel() {
        var policy = LauncherPolicy()
        _ = policy.handle(.serviceInvoked)
        _ = policy.handle(.switchStarted)
        XCTAssertEqual(policy.handle(.claudeLaunched), [])
        _ = policy.handle(.switchFinished)
        XCTAssertEqual(policy.handle(.claudeLaunched), [.hidePanel])
    }

    func testPanelClosedByUserThenLaunchDoesNotHideAgain() {
        var policy = LauncherPolicy()
        _ = policy.handle(.serviceInvoked)
        _ = policy.handle(.panelClosedByUser)
        XCTAssertEqual(policy.handle(.claudeLaunched), [])
    }
}
