import SwitchCore
import Foundation

/// Claude 앱 상태를 흉내 내는 가짜 컨트롤러. 종료 요청 후 몇 번의 폴링 뒤에 종료되도록 조정할 수 있다.
final class FakeClaudeControl: ClaudeAppControlling {
    var running = false
    var pollsUntilQuit = 0
    var quitRequests = 0
    var launches = 0
    var refuseToQuit = false
    var onLaunch: (() -> Void)?

    func isClaudeAppRunning() -> Bool { running }

    func requestClaudeQuit() {
        quitRequests += 1
        if !refuseToQuit && pollsUntilQuit == 0 { running = false }
    }

    func launchClaude() throws {
        launches += 1
        running = true
        onLaunch?()
    }

    /// 매니저의 sleep 훅에서 호출되어 폴링 진행을 흉내 낸다.
    func tick() {
        guard running, !refuseToQuit else { return }
        if pollsUntilQuit > 0 {
            pollsUntilQuit -= 1
            if pollsUntilQuit == 0 { running = false }
        }
    }
}

final class FakeScanner: ProcessScanning {
    var processes: [RunningProcess] = []
    var holders: [RunningProcess] = []
    /// 각 스캔 호출 뒤 실행되어 경쟁 조건 등을 흉내 낸다.
    var afterScan: ((Int) -> Void)?
    private(set) var scanCount = 0

    func resetCount() { scanCount = 0 }

    func processes(underPaths prefixes: [String], excludingNames: Set<String>) -> [RunningProcess] {
        scanCount += 1
        defer { afterScan?(scanCount) }
        return processes.filter { !excludingNames.contains($0.name) }
    }

    func processesHoldingFiles(underPaths prefixes: [String], excludingNames: Set<String>) -> [RunningProcess] {
        holders
    }
}

struct Sandbox {
    let root: URL
    let paths: Paths
    let control = FakeClaudeControl()
    let scanner = FakeScanner()
    var clock: Date

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cam-test-\(UUID().uuidString)", isDirectory: true)
        let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        paths = Paths(appSupportDir: appSupport, claudeAppURL: root.appendingPathComponent("Claude.app"))
        clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    var fakeTrashDir: URL { root.appendingPathComponent("Trash", isDirectory: true) }

    func makeManager() -> ProfileManager {
        let control = self.control
        var now = clock
        let trashDir = fakeTrashDir
        let manager = ProfileManager(paths: paths, control: control, scanner: scanner, sleep: { seconds in
            now = now.addingTimeInterval(seconds)
            control.tick()
        }, now: { now }, trash: { url in
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let destination = trashDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
        manager.quitTimeout = 5
        return manager
    }

    /// 실제 Claude 폴더를 흉내 내는 일반 폴더를 만든다.
    func createLiveDirectory(files: [String: String]) throws {
        try FileManager.default.createDirectory(at: paths.liveLink, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (name, content) in files {
            try content.write(to: paths.liveLink.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: paths.liveLink.appendingPathComponent("Local Storage"), withIntermediateDirectories: false)
    }

    func readLive(_ name: String) -> String? {
        try? String(contentsOf: paths.liveLink.appendingPathComponent(name), encoding: .utf8)
    }

    func writeLive(_ name: String, _ content: String) throws {
        try content.write(to: paths.liveLink.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
