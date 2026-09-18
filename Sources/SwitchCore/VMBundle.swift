import CSystemShims
import Foundation

/// Cowork VM 번들(`vm_bundles/claudevm.bundle`)의 파일 구성. Claude 2.2553.0 기준이며 구성이 다르면 아무것도 하지 않는다.
public enum VMBundle {
    public static let relativePath = "vm_bundles/claudevm.bundle"
    /// 다운로드되는 기본 이미지. 프로필 간에 내용이 같다.
    public static let imageNames = ["rootfs.img", "vmlinuz", "initrd", "initrd-micro"]
    /// 계정·설치 단위 상태. 절대 복사하지 않는다.
    public static let privateNames = ["sessiondata.img", "sessiondata.vhdx", "efivars.fd", "machineIdentifier", "macAddress", "gvisorMacAddress", "vmIP", ".cowork-adopted"]

    public static func compressedName(_ image: String) -> String { "\(image).zst" }
    public static func originName(_ image: String) -> String { ".\(image).origin" }
    public static func compressedOriginName(_ image: String) -> String { ".\(image).zst.origin" }

    /// 전파 대상 파일 전체. 이미지와 압축 캐시를 먼저, 마커를 마지막에 두어 중간에 끊겨도 마커가 새 버전을 주장하지 않게 한다.
    public static var propagatedNames: [String] {
        imageNames.map { $0 } + imageNames.map(compressedName) + imageNames.map(originName) + imageNames.map(compressedOriginName)
    }

    public static func bundleDir(profileDir: URL) -> URL {
        profileDir.appendingPathComponent(relativePath, isDirectory: true)
    }

    /// rootfs 마커 내용. 없으면 nil.
    public static func marker(profileDir: URL) -> String? {
        let url = bundleDir(profileDir: profileDir).appendingPathComponent(originName("rootfs.img"))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 전파 원본이 될 수 있는지: 모든 이미지와 마커가 일반 파일로 존재해야 한다. 압축 캐시는 없어도 된다.
    public static func isCompleteSource(profileDir: URL) -> Bool {
        let dir = bundleDir(profileDir: profileDir)
        for image in imageNames {
            guard (try? FileOps.kind(dir.appendingPathComponent(image))) == .file,
                  (try? FileOps.kind(dir.appendingPathComponent(originName(image)))) == .file else { return false }
        }
        return true
    }
}

public struct ProfileUsage: Equatable {
    public let profileID: String
    public var total: Int64 = 0
    public var caches: Int64 = 0
    public var vmImages: Int64 = 0
    public var vmCompressed: Int64 = 0
    public var sessionData: Int64 = 0
    public var claudeCode: Int64 = 0
    public var vmMarker: String?
    public var hasVMBundle = false

    public var other: Int64 { max(0, total - caches - vmImages - vmCompressed - sessionData - claudeCode) }

    public init(profileID: String) {
        self.profileID = profileID
    }

    /// 지우면 재생성되는 Chromium 캐시 폴더.
    public static let cacheDirectoryNames = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "ShaderCache", "GrShaderCache"]
    public static let claudeCodeDirectoryNames = ["claude-code", "claude-code-vm"]
}

public struct PropagationPlan: Equatable {
    public struct Target: Equatable {
        public let profileID: String
        public let currentMarker: String?
        public let hasBundle: Bool

        public init(profileID: String, currentMarker: String?, hasBundle: Bool) {
            self.profileID = profileID
            self.currentMarker = currentMarker
            self.hasBundle = hasBundle
        }
    }

    public let sourceProfileID: String
    public let sourceMarker: String
    /// 지금 복제할 수 있는 대상.
    public let targets: [Target]
    /// 복제가 필요하지만 지금은 할 수 없는 대상(현재 프로필인데 Claude 실행 중).
    public let deferred: [Target]
    /// 이미 같은 이미지를 가진 프로필.
    public let upToDate: [String]

    public init(sourceProfileID: String, sourceMarker: String, targets: [Target], deferred: [Target] = [], upToDate: [String] = []) {
        self.sourceProfileID = sourceProfileID
        self.sourceMarker = sourceMarker
        self.targets = targets
        self.deferred = deferred
        self.upToDate = upToDate
    }
}

public struct PropagationResult: Equatable {
    public var updated: [String] = []
    public var skipped: [String: String] = [:]
    public var reason: String?
}
