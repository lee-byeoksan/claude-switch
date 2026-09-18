import Foundation

public struct Profile: Codable, Equatable, Identifiable {
    public enum State: String, Codable {
        case registered
        case archived
    }

    public let id: String
    public var name: String
    public let directoryName: String
    public let createdAt: Date
    public var state: State

    public init(id: String, name: String, directoryName: String, createdAt: Date, state: State) {
        self.id = id
        self.name = name
        self.directoryName = directoryName
        self.createdAt = createdAt
        self.state = state
    }
}

public struct BackupRecord: Codable, Equatable {
    public let path: String
    public let createdAt: Date
    public let method: String
    public let entryCount: Int
    public let profileID: String

    public init(path: String, createdAt: Date, method: String, entryCount: Int, profileID: String) {
        self.path = path
        self.createdAt = createdAt
        self.method = method
        self.entryCount = entryCount
        self.profileID = profileID
    }
}

public struct Manifest: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var profiles: [Profile]
    public var currentProfileID: String?
    public var backups: [BackupRecord]

    public static let empty = Manifest(version: currentVersion, profiles: [], currentProfileID: nil, backups: [])

    public init(version: Int, profiles: [Profile], currentProfileID: String?, backups: [BackupRecord]) {
        self.version = version
        self.profiles = profiles
        self.currentProfileID = currentProfileID
        self.backups = backups
    }

    public func profile(id: String) -> Profile? {
        profiles.first { $0.id == id }
    }

    public var registered: [Profile] { profiles.filter { $0.state == .registered } }
    public var archived: [Profile] { profiles.filter { $0.state == .archived } }
    public var current: Profile? { currentProfileID.flatMap(profile(id:)) }

    public mutating func update(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }
}

/// 파일 시스템을 바꾸는 작업의 진행 기록. 작업 도중 앱이 종료되면 다음 실행 때 이 기록으로 복구한다.
public struct Journal: Codable, Equatable {
    public enum Kind: String, Codable {
        case adopt
        case switchProfile
        case restore
    }

    public var kind: Kind
    public var step: String
    public var startedAt: Date
    public var profileID: String
    public var profileName: String
    public var directoryName: String
    public var previousProfileID: String?
    public var backupPath: String?
    public var retiredLinkPath: String?

    public init(kind: Kind, step: String, startedAt: Date, profileID: String, profileName: String, directoryName: String,
                previousProfileID: String?, backupPath: String?, retiredLinkPath: String?) {
        self.kind = kind
        self.step = step
        self.startedAt = startedAt
        self.profileID = profileID
        self.profileName = profileName
        self.directoryName = directoryName
        self.previousProfileID = previousProfileID
        self.backupPath = backupPath
        self.retiredLinkPath = retiredLinkPath
    }
}

public struct RunningProcess: Equatable {
    public let pid: Int32
    public let path: String
    public let startTime: Date?

    public init(pid: Int32, path: String, startTime: Date?) {
        self.pid = pid
        self.path = path
        self.startTime = startTime
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public enum LiveLayout: Equatable {
    /// 일반 폴더. 아직 프로필로 등록되지 않은 상태.
    case plainDirectory
    /// 등록된 프로필 폴더를 가리키는 symlink.
    case managed(profileID: String)
    /// 존재하는 대상이지만 우리가 등록한 프로필이 아닌 곳을 가리키는 symlink.
    case linkedToUnknown(target: String)
    /// 대상이 없는 symlink.
    case brokenLink(target: String)
    case missing
    /// 일반 파일 등 예상하지 못한 항목.
    case other(String)

    public var description: String {
        switch self {
        case .plainDirectory: return "일반 폴더 (프로필 미등록)"
        case .managed: return "프로필에 연결됨"
        case .linkedToUnknown(let target): return "등록되지 않은 대상에 연결됨: \(target)"
        case .brokenLink(let target): return "끊어진 링크: \(target)"
        case .missing: return "Claude 데이터 폴더 없음"
        case .other(let what): return "예상하지 못한 항목: \(what)"
        }
    }
}

public struct ManagerStatus: Equatable {
    public var manifest: Manifest
    public var layout: LiveLayout
    public var accountHint: String?
    public var unknownDirectories: [String]
    public var pendingJournal: Journal?
    public var claudeRunning: Bool

    public init(manifest: Manifest, layout: LiveLayout, accountHint: String?, unknownDirectories: [String], pendingJournal: Journal?, claudeRunning: Bool) {
        self.manifest = manifest
        self.layout = layout
        self.accountHint = accountHint
        self.unknownDirectories = unknownDirectories
        self.pendingJournal = pendingJournal
        self.claudeRunning = claudeRunning
    }
}

public struct RecoveryReport: Equatable {
    public var notes: [String]
    public var resolved: Bool
}
