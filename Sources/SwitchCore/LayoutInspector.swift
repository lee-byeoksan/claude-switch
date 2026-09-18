import Foundation

public enum LayoutInspector {
    public static func inspect(paths: Paths, manifest: Manifest) throws -> LiveLayout {
        switch try FileOps.kind(paths.liveLink) {
        case .missing:
            return .missing
        case .directory:
            return .plainDirectory
        case .file:
            return .other("일반 파일")
        case .other:
            return .other("알 수 없는 종류")
        case .symlink(let rawTarget):
            let target = FileOps.resolveLinkTarget(rawTarget, relativeTo: paths.liveLink)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .brokenLink(target: target.path)
            }
            if let profile = manifest.profiles.first(where: { paths.profileDir($0).standardizedFileURL.path == target.path }) {
                return .managed(profileID: profile.id)
            }
            return .linkedToUnknown(target: target.path)
        }
    }

    /// profiles 폴더 안에 있지만 manifest에 없는 폴더 이름.
    public static func unknownDirectories(paths: Paths, manifest: Manifest) -> [String] {
        guard let entries = try? FileOps.topLevelEntries(paths.profilesDir) else { return [] }
        let known = Set(manifest.profiles.map(\.directoryName))
        return entries.filter { name in
            !known.contains(name) && !name.hasPrefix(".") && (try? FileOps.kind(paths.profileDir(directoryName: name))) == .directory
        }
    }
}
