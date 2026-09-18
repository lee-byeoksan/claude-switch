import SwitchCore
import AppKit

/// NSRunningApplication과 NSWorkspace를 사용한 실제 구현.
struct WorkspaceClaudeControl: ClaudeAppControlling {
    let paths: Paths

    private var runningApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Paths.claudeBundleIdentifier)
    }

    func isClaudeAppRunning() -> Bool {
        runningApps.contains { !$0.isTerminated }
    }

    func requestClaudeQuit() {
        // AppleEvent quit. 강제 종료가 아니므로 Claude가 확인 대화상자를 띄울 수 있다.
        for app in runningApps { app.terminate() }
    }

    func launchClaude() throws {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.claudeBundleIdentifier) ?? paths.claudeAppURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            failure = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
        if let failure { throw failure }
    }
}

/// 테스트 모드용. 실제 Claude를 건드리지 않는다.
struct NoopClaudeControl: ClaudeAppControlling {
    func isClaudeAppRunning() -> Bool { false }
    func requestClaudeQuit() {}
    func launchClaude() throws { NSLog("[test-mode] launchClaude ignored") }
}

struct NoopProcessScanner: ProcessScanning {
    func processes(underPaths prefixes: [String], excludingNames: Set<String>) -> [RunningProcess] { [] }
    func processesHoldingFiles(underPaths prefixes: [String], excludingNames: Set<String>) -> [RunningProcess] { [] }
}
