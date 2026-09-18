import Foundation
import SwitchCore

/// 용량 정리 화면의 표시 내용. 계산은 core가 하고 여기서는 표시용으로 정리만 한다.
public struct StorageModel: Equatable {
    public struct Row: Equatable, Identifiable {
        public var id: String { profileID }
        public var profileID: String
        public var name: String
        public var isCurrent: Bool
        public var isActive: Bool
        public var total: Int64
        /// 이 프로필만 가리키는 블록. 지우면 회수되는 양. 계산 전에는 nil.
        public var exclusive: Int64?
        public var caches: Int64
        public var vmImages: Int64
        public var vmCompressed: Int64
        public var sessionData: Int64
        public var claudeCode: Int64
        public var other: Int64
        public var vmMarker: String?
        public var hasVMBundle: Bool
        public var needsPropagation: Bool
        public var canCleanCaches: Bool
        public var canRemoveVMImages: Bool
    }

    public struct BackupRow: Equatable, Identifiable {
        public var id: String { path }
        public var path: String
        public var createdAt: Date
        public var profileName: String
    }

    public var rows: [Row]
    public var backups: [BackupRow]
    public var propagationSource: String?
    public var propagationTargets: [String]
    public var propagationDeferred: [String]
    public var propagationUpToDate: [String]
    public var propagationNote: String
    public var totalBytes: Int64
    /// 프로필과 백업이 실제로 차지하는 블록의 합집합. 계산 전에는 nil.
    public var physicalTotal: Int64?
    public var backupExclusive: [String: Int64]
    public var loading: Bool
    public var busyText: String?

    public static func build(status: ManagerStatus?, usages: [ProfileUsage], plan: PropagationPlan?, physical: PhysicalUsage? = nil, loading: Bool, busy: String?) -> StorageModel {
        guard let status else {
            return StorageModel(rows: [], backups: [], propagationSource: nil, propagationTargets: [], propagationDeferred: [], propagationUpToDate: [], propagationNote: "상태를 읽을 수 없습니다", totalBytes: 0, physicalTotal: nil, backupExclusive: [:], loading: loading, busyText: busy)
        }
        let currentID: String? = {
            if case .managed(let id) = status.layout { return id }
            return nil
        }()
        let usageByID = Dictionary(uniqueKeysWithValues: usages.map { ($0.profileID, $0) })
        let targets = Set(plan?.targets.map(\.profileID) ?? [])
        let locked = busy != nil
        let rows = status.manifest.profiles.map { profile -> Row in
            let usage = usageByID[profile.id] ?? ProfileUsage(profileID: profile.id)
            let isCurrent = profile.id == currentID
            return Row(profileID: profile.id, name: profile.name, isCurrent: isCurrent, isActive: profile.state == .registered,
                       total: usage.total, exclusive: physical?.root(profile.id)?.exclusive, caches: usage.caches, vmImages: usage.vmImages, vmCompressed: usage.vmCompressed,
                       sessionData: usage.sessionData, claudeCode: usage.claudeCode, other: usage.other,
                       vmMarker: usage.vmMarker, hasVMBundle: usage.hasVMBundle, needsPropagation: targets.contains(profile.id),
                       canCleanCaches: !locked && usage.caches > 0 && !(isCurrent && status.claudeRunning),
                       canRemoveVMImages: !locked && !isCurrent && usage.vmImages > 0)
        }
        .sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let nameByID = Dictionary(uniqueKeysWithValues: status.manifest.profiles.map { ($0.id, $0.name) })
        let backups = status.manifest.backups.map { BackupRow(path: $0.path, createdAt: $0.createdAt, profileName: nameByID[$0.profileID] ?? "(제거된 프로필)") }
        let note: String
        if let plan {
            let sourceName = nameByID[plan.sourceProfileID] ?? "?"
            if plan.targets.isEmpty && plan.deferred.isEmpty {
                note = "모든 프로필이 \(sourceName) 프로필과 같은 VM 이미지(\(plan.sourceMarker.prefix(12)))를 가지고 있습니다."
            } else {
                note = "\(sourceName) 프로필의 VM 이미지(\(plan.sourceMarker.prefix(12)))를 APFS clone으로 복사합니다. 대상의 세션 데이터는 유지되고, 실행 중 rootfs에 쓰인 임시 변경은 업데이트 때처럼 초기화됩니다."
            }
        } else {
            note = "완전한 VM 이미지를 가진 프로필이 없어 복제할 원본이 없습니다. Cowork를 한 번 실행하면 이미지가 내려받아집니다."
        }
        return StorageModel(rows: rows, backups: backups, propagationSource: plan.flatMap { nameByID[$0.sourceProfileID] },
                            propagationTargets: plan?.targets.compactMap { nameByID[$0.profileID] } ?? [],
                            propagationDeferred: plan?.deferred.compactMap { nameByID[$0.profileID] } ?? [],
                            propagationUpToDate: plan?.upToDate.compactMap { nameByID[$0] } ?? [],
                            propagationNote: note, totalBytes: rows.reduce(0) { $0 + $1.total },
                            physicalTotal: physical?.union,
                            backupExclusive: Dictionary(uniqueKeysWithValues: status.manifest.backups.compactMap { backup in
                                physical?.root(backup.path).map { (backup.path, $0.exclusive) }
                            }),
                            loading: loading, busyText: busy)
    }

    public static func format(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "-" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
