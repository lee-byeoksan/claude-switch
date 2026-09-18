import CSystemShims
import Foundation

public enum FileKind: Equatable {
    case missing
    case directory
    case symlink(target: String)
    case file
    case other
}

/// 파일 시스템 조작. 모두 lstat 기반이며 symlink를 따라가지 않는다.
public enum FileOps {
    static let privateMode: mode_t = 0o700

    public static func kind(_ url: URL) throws -> FileKind {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            throw AccountError.posix("lstat \(url.path)", code)
        }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            return .symlink(target: target)
        case S_IFREG: return .file
        default: return .other
        }
    }

    public static func isOwnedByCurrentUser(_ url: URL) throws -> Bool {
        var st = stat()
        if lstat(url.path, &st) != 0 { throw AccountError.posix("lstat \(url.path)", errno) }
        return st.st_uid == getuid()
    }

    /// 소유자만 접근 가능한 폴더를 만든다. 이미 있으면 권한만 맞춘다.
    public static func ensurePrivateDirectory(_ url: URL) throws {
        switch try kind(url) {
        case .missing:
            if mkdir(url.path, privateMode) != 0 {
                let code = errno
                if code != EEXIST { throw AccountError.posix("mkdir \(url.path)", code) }
            }
        case .directory:
            break
        default:
            throw AccountError.unexpectedLayout("폴더가 아닌 항목이 있습니다: \(url.path)")
        }
        try tightenPermissions(url)
    }

    public static func tightenPermissions(_ url: URL) throws {
        if chmod(url.path, privateMode) != 0 {
            throw AccountError.posix("chmod \(url.path)", errno)
        }
    }

    /// 대상이 이미 있으면 실패하는 원자적 이동. 같은 볼륨에서만 동작한다.
    public static func moveNoClobber(from: URL, to: URL) throws {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            if code == EEXIST || code == ENOTEMPTY { throw AccountError.directoryAlreadyExists(to.path) }
            throw AccountError.posix("rename \(from.lastPathComponent) -> \(to.path)", code)
        }
    }

    /// live 경로의 symlink를 새 대상으로 원자적으로 교체한다.
    /// live 경로가 없거나 symlink일 때만 진행하며, 일반 폴더는 절대 덮어쓰지 않는다.
    /// `finalCheck`는 임시 링크를 만든 뒤 rename 직전에 호출된다. 여기서 throw하면 임시 링크를 지우고 중단한다.
    public static func replaceSymlink(at live: URL, target: URL, tempDir: URL, finalCheck: () throws -> Void = {}) throws {
        switch try kind(live) {
        case .missing, .symlink:
            break
        case .directory:
            throw AccountError.unexpectedLayout("\(live.path)가 일반 폴더라 링크로 교체하지 않습니다.")
        default:
            throw AccountError.unexpectedLayout("\(live.path)가 폴더도 링크도 아닙니다.")
        }
        let temp = tempDir.appendingPathComponent(".link-tmp-\(UUID().uuidString)", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: temp.path, withDestinationPath: target.path)
        do {
            try finalCheck()
            // rename(2)은 대상이 symlink이면 링크 자체를 교체하고, 대상이 폴더이면 EISDIR로 실패한다.
            if rename(temp.path, live.path) != 0 {
                throw AccountError.posix("rename link -> \(live.path)", errno)
            }
        } catch {
            unlink(temp.path)
            throw error
        }
    }

    /// symlink만 제거한다. 폴더나 파일이면 건드리지 않는다.
    public static func removeSymlinkOnly(_ url: URL) throws {
        guard case .symlink = try kind(url) else { return }
        if unlink(url.path) != 0 { throw AccountError.posix("unlink \(url.path)", errno) }
    }

    public static func topLevelEntries(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    public static func availableCapacity(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public static func logicalSize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// 폴더 전체를 복제한다. APFS에서는 clonefile로 즉시 복제하고, 실패하면 일반 복사로 대체한다.
    /// 반환값은 사용된 방식이다.
    @discardableResult
    public static func cloneDirectory(from source: URL, to destination: URL) throws -> String {
        guard try kind(destination) == .missing else { throw AccountError.directoryAlreadyExists(destination.path) }
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 {
            return "clonefile"
        }
        let cloneErrno = errno
        if cloneErrno != ENOTSUP && cloneErrno != EXDEV && cloneErrno != EINVAL {
            throw AccountError.posix("clonefile \(source.lastPathComponent)", cloneErrno)
        }
        let needed = logicalSize(of: source)
        let available = availableCapacity(at: destination.deletingLastPathComponent())
        if available < needed + needed / 10 {
            throw AccountError.insufficientDiskSpace(needed: needed, available: available)
        }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
        if copyfile(source.path, destination.path, nil, flags) != 0 {
            throw AccountError.posix("copyfile \(source.lastPathComponent)", errno)
        }
        return "copyfile"
    }

    /// 상대 경로 링크 대상을 절대 경로로 바꾼다.
    public static func resolveLinkTarget(_ target: String, relativeTo link: URL) -> URL {
        if target.hasPrefix("/") { return URL(fileURLWithPath: target).standardizedFileURL }
        return link.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
    }
}

extension FileOps {
    /// 파일 하나를 clone한다. APFS가 아니면 `cloneUnsupported`를 던지고 일반 복사는 하지 않는다.
    public static func cloneFile(from source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        let code = errno
        if code == ENOTSUP || code == EXDEV {
            throw AccountError.cloneUnsupported(destination.deletingLastPathComponent().path)
        }
        throw AccountError.posix("clonefile \(source.lastPathComponent)", code)
    }

    /// 파일을 임시 이름으로 clone한 뒤 rename으로 교체한다. 대상이 폴더면 실패한다.
    public static func cloneFileReplacing(from source: URL, to destination: URL) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".cs-tmp-\(destination.lastPathComponent)-\(UUID().uuidString.prefix(8))")
        try cloneFile(from: source, to: temp)
        if case .directory = try kind(destination) {
            unlink(temp.path)
            throw AccountError.unexpectedLayout("폴더 위에 파일을 덮어쓰지 않습니다: \(destination.path)")
        }
        if rename(temp.path, destination.path) != 0 {
            let code = errno
            unlink(temp.path)
            throw AccountError.posix("rename \(destination.lastPathComponent)", code)
        }
    }

    /// 실제 할당 블록 기준 크기. clone으로 공유된 블록도 파일마다 전부 세므로 프로필 합계는 실제 디스크 점유보다 클 수 있다.
    public static func allocatedSize(of url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) == S_IFREG { return Int64(st.st_blocks) * 512 }
        guard (st.st_mode & S_IFMT) == S_IFDIR,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// 폴더나 파일을 즉시 삭제한다. symlink는 링크만 지운다. 호출자가 대상이 재생성 가능한 것인지 보장해야 한다.
    public static func deleteItem(_ url: URL) throws {
        switch try kind(url) {
        case .missing: return
        case .symlink: try removeSymlinkOnly(url)
        default: try FileManager.default.removeItem(at: url)
        }
    }
}
