import CSystemShims
import Foundation

/// APFS clone으로 공유된 블록을 감안한 실제 점유량. 파일마다 물리 블록 범위를 얻어 여러 루트가 같은 범위를 가리키면 한 번만 센다.
public struct PhysicalUsage: Equatable {
    public struct Root: Equatable {
        public let id: String
        /// 이 루트의 파일이 가리키는 블록 합. clone 공유 블록도 포함하므로 논리 합계와 같다.
        public var logical: Int64
        /// 이 루트만 가리키는 블록. 이 루트를 지우면 회수되는 양이다.
        public var exclusive: Int64

        public init(id: String, logical: Int64, exclusive: Int64) {
            self.id = id
            self.logical = logical
            self.exclusive = exclusive
        }
    }

    public var roots: [Root]
    /// 모든 루트가 실제로 차지하는 블록의 합집합.
    public var union: Int64

    public init(roots: [Root], union: Int64) {
        self.roots = roots
        self.union = union
    }

    public func root(_ id: String) -> Root? { roots.first { $0.id == id } }
}

public enum PhysicalUsageScanner {
    struct Extent {
        var start: UInt64
        var end: UInt64
        var owner: Int
    }

    /// 여러 루트 폴더를 한 번에 스캔한다. 같은 볼륨에 있어야 물리 위치 비교가 의미 있다.
    public static func scan(roots: [(id: String, url: URL)]) -> PhysicalUsage {
        var extents: [Extent] = []
        var fallback = [Int64](repeating: 0, count: roots.count)
        for (index, root) in roots.enumerated() {
            guard let enumerator = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: nil) else { continue }
            for case let item as URL in enumerator {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                collectExtents(of: item.path, owner: index, into: &extents, fallback: &fallback[index])
            }
        }
        return reduce(extents: extents, fallback: fallback, roots: roots)
    }

    static func collectExtents(of path: String, owner: Int, into out: inout [Extent], fallback: inout Int64) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return }
        let size = Int64(st.st_size)
        var found = false
        var position: Int64 = 0
        while position < size {
            let dataStart = lseek(fd, position, SEEK_DATA)
            if dataStart < 0 { break }
            var dataEnd = lseek(fd, dataStart, SEEK_HOLE)
            if dataEnd < 0 || dataEnd > size { dataEnd = size }
            var cursor = dataStart
            while cursor < dataEnd {
                var mapping = log2phys()
                mapping.l2p_flags = 0
                mapping.l2p_contigbytes = dataEnd - cursor
                mapping.l2p_devoffset = cursor
                guard fcntl(fd, F_LOG2PHYS_EXT, &mapping) == 0, mapping.l2p_contigbytes > 0, mapping.l2p_devoffset >= 0 else { break }
                let length = min(mapping.l2p_contigbytes, dataEnd - cursor)
                out.append(Extent(start: UInt64(mapping.l2p_devoffset), end: UInt64(mapping.l2p_devoffset) + UInt64(length), owner: owner))
                found = true
                cursor += length
            }
            position = dataEnd
        }
        if !found { fallback += Int64(st.st_blocks) * 512 }
    }

    /// 스위프 라인으로 합집합과 루트별 고유 블록을 센다.
    static func reduce(extents: [Extent], fallback: [Int64], roots: [(id: String, url: URL)]) -> PhysicalUsage {
        var events: [(position: UInt64, delta: Int, owner: Int)] = []
        events.reserveCapacity(extents.count * 2)
        for extent in extents {
            events.append((extent.start, 1, extent.owner))
            events.append((extent.end, -1, extent.owner))
        }
        events.sort { $0.position < $1.position }
        var counts = [Int](repeating: 0, count: roots.count)
        var activeOwners = 0
        var union: UInt64 = 0
        var exclusive = [UInt64](repeating: 0, count: roots.count)
        var logical = [UInt64](repeating: 0, count: roots.count)
        var previous: UInt64 = 0
        var soleOwner = -1
        for event in events {
            let length = event.position > previous ? event.position - previous : 0
            if length > 0 && activeOwners > 0 {
                union += length
                for index in 0 ..< roots.count where counts[index] > 0 { logical[index] += length }
                if activeOwners == 1, soleOwner >= 0 { exclusive[soleOwner] += length }
            }
            counts[event.owner] += event.delta
            activeOwners = 0
            soleOwner = -1
            for index in 0 ..< roots.count where counts[index] > 0 {
                activeOwners += 1
                soleOwner = index
            }
            previous = event.position
        }
        let result = roots.enumerated().map { index, root in
            PhysicalUsage.Root(id: root.id, logical: Int64(logical[index]) + fallback[index], exclusive: Int64(exclusive[index]) + fallback[index])
        }
        return PhysicalUsage(roots: result, union: Int64(union) + fallback.reduce(0, +))
    }
}
