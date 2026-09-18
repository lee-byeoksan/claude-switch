import Foundation

public enum AccountError: Error, LocalizedError, Equatable {
    case locked
    case journalPending(String)
    case unexpectedLayout(String)
    case inconsistentState(String)
    case profileNotFound
    case profileIsCurrent
    case profileDirectoryMissing(String)
    case directoryAlreadyExists(String)
    case invalidName
    case claudeStillRunning([RunningProcess])
    case raceDetected(String)
    case backupVerificationFailed(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case notOwnedByUser(String)
    case posix(String, Int32)
    case cloneUnsupported(String)
    case inUse(String)
    case unsupportedLayout(String)

    public var errorDescription: String? {
        switch self {
        case .locked:
            return "다른 작업이 진행 중입니다. 잠시 후 다시 시도하세요."
        case .journalPending(let detail):
            return "완료되지 않은 이전 작업이 있습니다. 상태 점검을 먼저 실행하세요. (\(detail))"
        case .unexpectedLayout(let detail):
            return "Claude 데이터 경로 상태가 예상과 다릅니다: \(detail)"
        case .inconsistentState(let detail):
            return "기록과 실제 상태가 다릅니다: \(detail)"
        case .profileNotFound:
            return "프로필을 찾을 수 없습니다."
        case .profileIsCurrent:
            return "현재 사용 중인 프로필은 등록 해제하거나 변경할 수 없습니다."
        case .profileDirectoryMissing(let path):
            return "프로필 데이터 폴더가 없습니다: \(path)"
        case .directoryAlreadyExists(let path):
            return "이미 폴더가 있습니다. 덮어쓰지 않습니다: \(path)"
        case .invalidName:
            return "프로필 이름이 비어 있거나 사용할 수 없는 문자를 포함합니다."
        case .claudeStillRunning(let processes):
            let list = processes.prefix(6).map { "\($0.name) (pid \($0.pid))" }.joined(separator: ", ")
            return "Claude 관련 프로세스가 아직 실행 중이라 전환하지 않았습니다. Claude 창에 확인 대화상자가 열려 있는지 확인하고 직접 종료한 뒤 다시 시도하세요. 실행 중: \(list)"
        case .raceDetected(let detail):
            return "전환 도중 Claude가 다시 실행되어 원래 상태로 되돌렸습니다. Claude를 종료한 뒤 다시 시도하세요. (\(detail))"
        case .backupVerificationFailed(let detail):
            return "백업 검증에 실패해 마이그레이션을 중단했습니다. 원본은 그대로입니다. (\(detail))"
        case .insufficientDiskSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "디스크 공간이 부족합니다. 필요: \(f.string(fromByteCount: needed)), 가능: \(f.string(fromByteCount: available))"
        case .notOwnedByUser(let path):
            return "현재 사용자 소유가 아닌 항목입니다: \(path)"
        case .posix(let op, let code):
            return "\(op) 실패: \(String(cString: strerror(code))) (errno \(code))"
        case .cloneUnsupported(let path):
            return "이 볼륨은 APFS clone을 지원하지 않아 공간 절약 복사를 할 수 없습니다: \(path)"
        case .inUse(let detail):
            return "사용 중이라 진행하지 않았습니다: \(detail)"
        case .unsupportedLayout(let detail):
            return "예상과 다른 파일 구성이라 건드리지 않았습니다: \(detail)"
        }
    }
}
