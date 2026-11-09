import Foundation

/// "v0.1.2", "0.1.2", "0.2" 같은 버전 문자열. 숫자 부분만 비교한다.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // "0.2.0-beta" 처럼 꼬리표가 붙으면 앞부분만 본다.
        if let dash = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<dash]) }
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var parts: [Int] = []
        for p in pieces {
            guard let n = Int(p), n >= 0 else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    /// 끝 숫자를 한국어로 읽었을 때 받침에 맞춘 조사. 0.1.1이 / 0.1.2가
    public var withSubject: String { description + (Self.batchimDigits.contains(lastDigit) ? "이" : "가") }
    /// 0.1.0으로 / 0.1.1로(ㄹ 받침은 '로') / 0.1.2로
    public var withDirection: String { description + ([0, 3, 6].contains(lastDigit) ? "으로" : "로") }

    private static let batchimDigits: Set<Int> = [0, 1, 3, 6, 7, 8]   // 영 일 삼 육 칠 팔
    private var lastDigit: Int { (parts.last ?? 0) % 10 }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        for i in 0..<count {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// GitHub "releases/latest" 응답에서 필요한 부분.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    public let tag: String
    public let pageURL: URL
    public let notes: String
    /// 릴리스에 올린 앱 zip(MacPyeon-버전.zip). 앱 안에서 바로 업데이트할 때 쓴다.
    public let downloadURL: URL?
    /// GitHub가 알려 주는 그 zip의 sha256(소문자 16진수). 받은 파일과 맞춰 본다.
    public let downloadSHA256: String?

    public init(version: AppVersion, tag: String, pageURL: URL, notes: String,
                downloadURL: URL? = nil, downloadSHA256: String? = nil) {
        self.version = version
        self.tag = tag
        self.pageURL = pageURL
        self.notes = notes
        self.downloadURL = downloadURL
        self.downloadSHA256 = downloadSHA256
    }

    /// 초안·시험판이거나 버전을 읽을 수 없으면 nil.
    /// repo를 주면 앱 zip은 그 저장소의 그 버전 릴리스 주소일 때만 받아들인다.
    public static func parse(json data: Data, repo: String? = nil) -> ReleaseInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = AppVersion(tag),
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https"
        else { return nil }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return nil }
        let notes = (object["body"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        // GitHub에서 받는 https 주소이고 이름이 정확히 MacPyeon-<버전>.zip인 파일만.
        let file = "MacPyeon-\(version).zip"
        let assets = object["assets"] as? [[String: Any]] ?? []
        let asset = assets.first { asset in
            guard asset["name"] as? String == file,
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  url.scheme == "https", url.host == "github.com" else { return false }
            if let repo { return url.path == "/\(repo)/releases/download/\(tag)/\(file)" }
            return true
        }
        let download = (asset?["browser_download_url"] as? String).flatMap(URL.init(string:))
        let digest = (asset?["digest"] as? String).flatMap { d -> String? in
            guard d.hasPrefix("sha256:") else { return nil }
            let hex = d.dropFirst(7).lowercased()
            return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? String(hex) : nil
        }
        return ReleaseInfo(version: version, tag: tag, pageURL: page, notes: notes,
                           downloadURL: download, downloadSHA256: digest)
    }

    /// 알림에 보여 줄 짧은 변경 내용: 목록 줄만 최대 limit개.
    public func summaryLines(limit: Int = 4) -> [String] {
        notes.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { String($0.dropFirst(2)) }
            .prefix(limit)
            .map { $0 }
    }
}

public enum UpdatePolicy {
    /// 새 버전을 알릴지: 지금보다 높고, 사용자가 건너뛴 버전이 아니면.
    public static func shouldNotify(current: AppVersion, latest: AppVersion, skipped: AppVersion?) -> Bool {
        guard current < latest else { return false }
        if let skipped, skipped == latest { return false }
        return true
    }
}
