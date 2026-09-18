import SwitchCore
import AppKit
import SwitchUI

// 진단용: 메뉴 앱을 띄우지 않고 Claude 관련 프로세스와 경로 상태만 출력한다.
if CommandLine.arguments.contains("--scan") {
    let paths = Paths.standard()
    let manager = ProfileManager(paths: paths, control: NoopClaudeControl(), scanner: LibprocScanner())
    print("Claude Switch \(AppVersion.text)")
    print("Claude 경로: \(paths.liveLink.path)")
    if let status = try? manager.status() {
        print("상태: \(status.layout.description)")
        print("등록 프로필: \(status.manifest.registered.map(\.name))")
    }
    let running = manager.runningClaudeProcesses()
    print("실행 중인 Claude 관련 프로세스: \(running.count)")
    for process in running {
        print("  pid \(process.pid)  \(process.path)")
    }
    let holders = LibprocScanner().processesHoldingFiles(underPaths: [paths.liveLink.path], excludingNames: manager.excludedProcessNames)
    print("데이터 폴더 파일을 열고 있는 프로세스: \(holders.count)")
    for process in holders {
        print("  pid \(process.pid)  \(process.path)")
    }
    exit(0)
}

// 자가 테스트: 메뉴 항목 클릭이 핸들러까지 전달되는지 NSMenu 경로로 확인한다.
if CommandLine.arguments.contains("--self-test-menu") {
    _ = NSApplication.shared
    var received: [MenuAction] = []
    let builder = MenuBuilder { received.append($0) }
    let manifest = Manifest(version: 1, profiles: [Profile(id: "a", name: "A", directoryName: "a", createdAt: Date(), state: .registered)], currentProfileID: nil, backups: [])
    let status = ManagerStatus(manifest: manifest, layout: .plainDirectory, accountHint: nil, unknownDirectories: [], pendingJournal: nil, claudeRunning: false)
    let menu = builder.makeMenu(MenuModel.build(status: status, busy: nil, error: nil))
    var fired = 0
    for item in menu.items where item.isEnabled {
        guard let target = item.target as? ActionTarget, let action = item.action else { continue }
        _ = NSApp.sendAction(action, to: target, from: item)
        fired += 1
    }
    print("전송한 항목: \(fired), 핸들러 수신: \(received.count), 수신 목록: \(received)")
    exit(fired == received.count && fired > 0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
