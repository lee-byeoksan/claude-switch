import Foundation

/// 관리 대상 경로 모음. 테스트에서는 임시 폴더를 가리키도록 주입한다.
public struct Paths: Equatable {
    public static let liveDirectoryName = "Claude"
    public static let profilesRootName = "ClaudeProfiles"
    public static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"

    public let appSupportDir: URL
    public let claudeAppURL: URL

    public init(appSupportDir: URL, claudeAppURL: URL) {
        self.appSupportDir = appSupportDir.standardizedFileURL
        self.claudeAppURL = claudeAppURL.standardizedFileURL
    }

    public static func standard() -> Paths {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Paths(appSupportDir: appSupport, claudeAppURL: URL(fileURLWithPath: "/Applications/Claude.app"))
    }

    /// Claude가 실제로 사용하는 경로. 관리 상태에서는 symlink가 된다.
    public var liveLink: URL { appSupportDir.appendingPathComponent(Self.liveDirectoryName, isDirectory: false) }
    public var profilesRoot: URL { appSupportDir.appendingPathComponent(Self.profilesRootName, isDirectory: true) }
    public var profilesDir: URL { profilesRoot.appendingPathComponent("profiles", isDirectory: true) }
    public var backupsDir: URL { profilesRoot.appendingPathComponent("backups", isDirectory: true) }
    public var manifestURL: URL { profilesRoot.appendingPathComponent("manifest.json", isDirectory: false) }
    public var journalURL: URL { profilesRoot.appendingPathComponent("journal.json", isDirectory: false) }
    public var lockURL: URL { profilesRoot.appendingPathComponent(".lock", isDirectory: false) }
    public var logURL: URL { profilesRoot.appendingPathComponent("account-menu.log", isDirectory: false) }
    public var liveConfigJSON: URL { liveLink.appendingPathComponent("config.json", isDirectory: false) }

    public func profileDir(_ profile: Profile) -> URL {
        profileDir(directoryName: profile.directoryName)
    }

    public func profileDir(directoryName: String) -> URL {
        profilesDir.appendingPathComponent(directoryName, isDirectory: true)
    }
}
