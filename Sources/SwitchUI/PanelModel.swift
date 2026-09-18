import Foundation
import SwitchCore

/// 프로필 선택 창의 표시 내용. 로직 실행 없이 상태만으로 만든다.
public struct PanelModel: Equatable {
    public enum Tab: String, CaseIterable, Equatable {
        case active = "Active"
        case inactive = "Inactive"
    }

    public struct Row: Equatable, Identifiable {
        public var id: String { profileID }
        public var profileID: String
        public var name: String
        public var isCurrent: Bool
        public var directoryName: String
        public var createdAt: Date
        public var accountHint: String?
        public var backupPath: String?
        public var canSwitch: Bool
        public var canEdit: Bool
        public var canArchive: Bool
        public var canReactivate: Bool
        public var canTrash: Bool
    }

    public enum Notice: Equatable {
        case needsAdoption
        case layoutProblem(String)
        case pendingJournal(String)
    }

    public var active: [Row]
    public var inactive: [Row]
    public var claudeRunning: Bool
    public var busyText: String?
    public var canAdd: Bool
    public var notice: Notice?
    public var unknownDirectories: [String]
    public var errorText: String?

    public var currentName: String? { active.first { $0.isCurrent }?.name }

    public static func build(status: ManagerStatus?, busy: String?, error: String?) -> PanelModel {
        guard let status else {
            return PanelModel(active: [], inactive: [], claudeRunning: false, busyText: busy, canAdd: false, notice: nil, unknownDirectories: [], errorText: error ?? "상태를 읽을 수 없습니다")
        }
        let currentID: String? = {
            if case .managed(let id) = status.layout { return id }
            return nil
        }()
        let locked = busy != nil
        let switchable = !locked && status.layout != .plainDirectory
        let backups = Dictionary(grouping: status.manifest.backups, by: \.profileID)

        func row(_ profile: Profile) -> Row {
            let isCurrent = profile.id == currentID
            return Row(profileID: profile.id, name: profile.name, isCurrent: isCurrent,
                       directoryName: profile.directoryName, createdAt: profile.createdAt,
                       accountHint: isCurrent ? status.accountHint : nil,
                       backupPath: backups[profile.id]?.last?.path,
                       canSwitch: switchable && !(isCurrent && status.claudeRunning) && profile.state == .registered,
                       canEdit: !locked,
                       canArchive: !locked && !isCurrent && profile.state == .registered,
                       canReactivate: !locked && profile.state == .archived,
                       canTrash: !locked && !isCurrent)
        }

        let ordered = { (rows: [Row]) -> [Row] in
            rows.sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        let notice: Notice? = {
            if let journal = status.pendingJournal { return .pendingJournal(journal.kind.rawValue) }
            switch status.layout {
            case .plainDirectory: return .needsAdoption
            case .managed, .missing: return nil
            default: return .layoutProblem(status.layout.description)
            }
        }()
        return PanelModel(active: ordered(status.manifest.registered.map(row)),
                          inactive: ordered(status.manifest.archived.map(row)),
                          claudeRunning: status.claudeRunning,
                          busyText: busy,
                          canAdd: !locked && status.layout != .plainDirectory,
                          notice: notice,
                          unknownDirectories: status.unknownDirectories,
                          errorText: nil)
    }
}
