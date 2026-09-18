import CSystemShims
import Foundation

public protocol ProcessScanning {
    /// 실행 파일이 주어진 경로 아래에 있는 프로세스를 찾는다.
    func processes(underPaths prefixes: [String], excludingNames: Set<String>) -> [RunningProcess]
    /// 주어진 경로 아래의 파일을 열고 있거나 작업 디렉터리로 쓰는 프로세스를 찾는다. 느리므로 최종 확인용이다.
    func processesHoldingFiles(underPaths prefixes: [String], excludingNames: Set<String>) -> [RunningProcess]
}

/// libproc 기반 구현. 외부 명령을 실행하지 않는다.
public struct LibprocScanner: ProcessScanning {
    public init() {}

    public func processes(underPaths prefixes: [String], excludingNames: Set<String>) -> [RunningProcess] {
        let normalized = prefixes.map(Self.withTrailingSlash)
        var found: [RunningProcess] = []
        for pid in Self.allPIDs() {
            guard let path = Self.path(of: pid) else { continue }
            let name = (path as NSString).lastPathComponent
            if excludingNames.contains(name) { continue }
            if normalized.contains(where: { path.hasPrefix($0) }) {
                found.append(RunningProcess(pid: pid, path: path, startTime: Self.startTime(of: pid)))
            }
        }
        return found
    }

    /// Spotlight 인덱서처럼 파일을 잠깐 읽기만 하는 시스템 프로세스는 제외한다.
    public static let systemPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/"]

    public func processesHoldingFiles(underPaths prefixes: [String], excludingNames: Set<String>) -> [RunningProcess] {
        let normalized = prefixes.map(Self.withTrailingSlash)
        var found: [RunningProcess] = []
        let me = getpid()
        for pid in Self.allPIDs() where pid != me {
            guard let path = Self.path(of: pid) else { continue }
            let name = (path as NSString).lastPathComponent
            if excludingNames.contains(name) { continue }
            if Self.systemPathPrefixes.contains(where: { path.hasPrefix($0) }) { continue }
            let held = Self.openPaths(of: pid)
            if held.contains(where: { p in normalized.contains(where: { p.hasPrefix($0) }) }) {
                found.append(RunningProcess(pid: pid, path: path, startTime: Self.startTime(of: pid)))
            }
        }
        return found
    }

    static func withTrailingSlash(_ p: String) -> String { p.hasSuffix("/") ? p : p + "/" }

    static func allPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 128)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        return Array(pids[0 ..< Int(got) / MemoryLayout<pid_t>.size]).filter { $0 > 0 }
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    static func openPaths(of pid: pid_t) -> [String] {
        var result: [String] = []
        var vnodeInfo = proc_vnodepathinfo()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, vnodeSize) == vnodeSize {
            result.append(cString(&vnodeInfo.pvi_cdir.vip_path))
        }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return result }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return result }
        let count = Int(got) / MemoryLayout<proc_fdinfo>.size
        for fd in fds[0 ..< count] where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size {
                result.append(cString(&info.pvip.vip_path))
            }
        }
        return result
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }
}
