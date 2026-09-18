import CSystemShims
import Foundation

/// manifest, journal, 로그 파일의 읽기와 원자적 쓰기.
public final class Store {
    public let paths: Paths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: Paths) {
        self.paths = paths
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadManifest() throws -> Manifest {
        guard try FileOps.kind(paths.manifestURL) != .missing else { return .empty }
        let data = try Data(contentsOf: paths.manifestURL)
        let manifest = try decoder.decode(Manifest.self, from: data)
        guard manifest.version == Manifest.currentVersion else {
            throw AccountError.inconsistentState("manifest 버전 \(manifest.version)은 지원하지 않습니다.")
        }
        return manifest
    }

    public func saveManifest(_ manifest: Manifest) throws {
        try FileOps.ensurePrivateDirectory(paths.profilesRoot)
        try writeAtomic(try encoder.encode(manifest), to: paths.manifestURL)
    }

    public func loadJournal() throws -> Journal? {
        guard try FileOps.kind(paths.journalURL) != .missing else { return nil }
        return try decoder.decode(Journal.self, from: try Data(contentsOf: paths.journalURL))
    }

    public func saveJournal(_ journal: Journal) throws {
        try writeAtomic(try encoder.encode(journal), to: paths.journalURL)
    }

    public func clearJournal() throws {
        if try FileOps.kind(paths.journalURL) == .missing { return }
        try FileManager.default.removeItem(at: paths.journalURL)
    }

    public func appendLog(_ line: String) {
        guard (try? FileOps.kind(paths.profilesRoot)) == .directory else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        let fd = open(paths.logURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        text.withCString { ptr in _ = write(fd, ptr, strlen(ptr)) }
    }

    private func writeAtomic(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw AccountError.posix("open \(temp.lastPathComponent)", errno) }
        let written = data.withUnsafeBytes { buffer -> Int in
            write(fd, buffer.baseAddress, buffer.count)
        }
        fsync(fd)
        close(fd)
        guard written == data.count else {
            unlink(temp.path)
            throw AccountError.posix("write \(url.lastPathComponent)", EIO)
        }
        if rename(temp.path, url.path) != 0 {
            let code = errno
            unlink(temp.path)
            throw AccountError.posix("rename \(url.lastPathComponent)", code)
        }
    }
}

/// flock 기반 작업 잠금. 인스턴스가 살아 있는 동안 유지된다.
public final class OperationLock {
    private let fd: Int32

    public init(url: URL) throws {
        try FileOps.ensurePrivateDirectory(url.deletingLastPathComponent())
        fd = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AccountError.posix("open lock", errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw AccountError.locked
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
