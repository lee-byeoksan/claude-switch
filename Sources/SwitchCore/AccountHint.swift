import Foundation

/// Claude가 config.json에 남긴 마지막 계정 UUID의 앞부분. 토큰이나 비밀 값은 읽지 않는다.
public enum AccountHint {
    static let key = "lastKnownAccountUuid"
    static let maxBytes = 4 * 1024 * 1024

    public static func read(paths: Paths) -> String? {
        let url = paths.liveConfigJSON
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size <= maxBytes,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = object[key] as? String, uuid.count >= 8 else {
            return nil
        }
        return String(uuid.prefix(8))
    }
}
