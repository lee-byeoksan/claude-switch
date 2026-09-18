import AppKit
import Foundation
import SwitchUI
import ServiceManagement

/// UserDefaults와 SMAppService에 저장되는 런처 설정.
final class SettingsStore {
    private let defaults: UserDefaults
    private enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let autoPropagate = "autoPropagateVMImages"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.showMenuBarIcon: false, Key.autoPropagate: true])
    }

    var current: LauncherSettings {
        LauncherSettings(showMenuBarIcon: defaults.bool(forKey: Key.showMenuBarIcon),
                         launchAtLogin: SMAppService.mainApp.status == .enabled,
                         serviceShortcut: ServiceShortcutStore.read(),
                         autoPropagateVMImages: defaults.bool(forKey: Key.autoPropagate))
    }

    func setShowMenuBarIcon(_ value: Bool) { defaults.set(value, forKey: Key.showMenuBarIcon) }
    func setAutoPropagate(_ value: Bool) { defaults.set(value, forKey: Key.autoPropagate) }

    func setLaunchAtLogin(_ value: Bool) throws {
        if value {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// 서비스 메뉴 단축키. macOS는 사용자 지정 서비스 단축키를 `pbs` 설정 도메인의 NSServicesStatus에 저장한다.
/// 시스템 설정 > 키보드 > 단축키 > 서비스에서 바꾼 값과 같은 자리이며, 문서화되지 않은 형식이라 macOS 업데이트로 바뀔 수 있다.
enum ServiceShortcutStore {
    static let defaultShortcut = "^@s"
    private static let domain = "pbs" as CFString
    private static let statusKey = "NSServicesStatus" as CFString
    private static var entryKey: String {
        "\(Bundle.main.bundleIdentifier ?? "dev.claude-switch.app") - Claude Switch - switchProfile"
    }

    static func read() -> String? {
        guard let status = CFPreferencesCopyAppValue(statusKey, domain) as? [String: Any],
              let entry = status[entryKey] as? [String: Any] else { return nil }
        return entry["key_equivalent"] as? String
    }

    static func write(_ stored: String) throws {
        var status = (CFPreferencesCopyAppValue(statusKey, domain) as? [String: Any]) ?? [:]
        var entry = (status[entryKey] as? [String: Any]) ?? [:]
        entry["key_equivalent"] = stored
        status[entryKey] = entry
        CFPreferencesSetAppValue(statusKey, status as CFDictionary, domain)
        CFPreferencesSetAppValue("ServicesShortcutsPresent" as CFString, 1 as CFNumber, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw NSError(domain: "ClaudeSwitch", code: 1, userInfo: [NSLocalizedDescriptionKey: "단축키 설정을 저장하지 못했습니다."])
        }
        refreshServices()
    }

    /// 처음 실행할 때 기본 단축키(Cmd+Ctrl+S)를 기록한다. 사용자가 이미 바꿨으면 건드리지 않는다.
    static func ensureDefault() {
        guard read() == nil else { return }
        try? write(defaultShortcut)
    }

    static func refreshServices() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        process.arguments = ["-update"]
        try? process.run()
        process.waitUntilExit()
    }
}

/// Info.plist 에 빌드 스크립트가 기록한 버전과 커밋 해시.
enum AppVersion {
    static var text: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let commit = info["ClaudeSwitchCommit"] as? String ?? "unknown"
        return "\(version) (\(commit))"
    }
}
