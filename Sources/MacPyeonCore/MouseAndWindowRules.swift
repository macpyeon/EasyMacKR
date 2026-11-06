import CoreGraphics
import Foundation

// MARK: - 창 배치

public enum WindowLayout: Equatable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case maximize, center, restore
    case nextDisplay, previousDisplay
}

public enum WindowGeometry {
    /// 화면의 사용 가능 영역(`visible`) 안에서 배치 결과를 계산한다. 좌표계는 호출하는 쪽과 같다(위가 0인 AX 좌표).
    /// restore / 모니터 이동은 호출하는 쪽이 처리한다.
    public static func frame(for layout: WindowLayout, visible v: CGRect, current: CGRect) -> CGRect {
        switch layout {
        case .leftHalf:
            return CGRect(x: v.minX, y: v.minY, width: (v.width / 2).rounded(), height: v.height)
        case .rightHalf:
            let w = (v.width / 2).rounded()
            return CGRect(x: v.maxX - w, y: v.minY, width: w, height: v.height)
        case .topHalf:
            return CGRect(x: v.minX, y: v.minY, width: v.width, height: (v.height / 2).rounded())
        case .bottomHalf:
            let h = (v.height / 2).rounded()
            return CGRect(x: v.minX, y: v.maxY - h, width: v.width, height: h)
        case .maximize:
            return v
        case .center:
            var size = current.size
            if size.width > v.width || size.height > v.height {
                size = CGSize(width: (v.width * 2 / 3).rounded(), height: (v.height * 2 / 3).rounded())
            }
            return CGRect(x: (v.midX - size.width / 2).rounded(), y: (v.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        case .restore, .nextDisplay, .previousDisplay:
            return current
        }
    }

    /// 창을 다른 화면으로 옮길 때, 원래 화면에서의 상대 위치·크기를 유지한다.
    public static func move(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let rx = (frame.minX - source.minX) / max(source.width, 1)
        let ry = (frame.minY - source.minY) / max(source.height, 1)
        let rw = frame.width / max(source.width, 1)
        let rh = frame.height / max(source.height, 1)
        var result = CGRect(x: target.minX + rx * target.width, y: target.minY + ry * target.height,
                            width: min(rw, 1) * target.width, height: min(rh, 1) * target.height)
        result.origin.x = min(max(result.minX, target.minX), target.maxX - result.width)
        result.origin.y = min(max(result.minY, target.minY), target.maxY - result.height)
        return result.integral
    }

    /// 위가 0인 AX 좌표 ↔ 아래가 0인 AppKit 좌표 변환. `primaryHeight`는 주 화면 높이.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - 스크롤

public struct ScrollAxis: Equatable, Sendable {
    /// 줄 단위(정수) 값
    public var lines: Int64
    /// 고정소수점 줄 값(앱이 주로 읽는 값)
    public var fixed: Double
    /// 픽셀 값
    public var points: Int64

    public init(lines: Int64, fixed: Double, points: Int64) {
        self.lines = lines
        self.fixed = fixed
        self.points = points
    }

    var isZero: Bool { lines == 0 && fixed == 0 && points == 0 }

    var sign: Int64 {
        if fixed != 0 { return fixed > 0 ? 1 : -1 }
        if lines != 0 { return lines > 0 ? 1 : -1 }
        return points > 0 ? 1 : (points < 0 ? -1 : 0)
    }

    mutating func negate() {
        lines = -lines
        fixed = -fixed
        points = -points
    }
}

public struct ScrollOptions: Equatable, Sendable {
    public var reverseVertical = false
    public var reverseHorizontal = false
    /// nil이면 macOS 가속을 그대로 쓴다.
    public var linearLines: Int?

    public init(reverseVertical: Bool = false, reverseHorizontal: Bool = false, linearLines: Int? = nil) {
        self.reverseVertical = reverseVertical
        self.reverseHorizontal = reverseHorizontal
        self.linearLines = linearLines
    }

    public init(enabled: Set<FeatureID>, linesPerNotch: Int) {
        self.init(reverseVertical: enabled.contains(.mouseScrollReverse),
                  reverseHorizontal: enabled.contains(.mouseScrollReverseHorizontal),
                  linearLines: enabled.contains(.linearScroll) ? linesPerNotch : nil)
    }

    public var isActive: Bool { reverseVertical || reverseHorizontal || linearLines != nil }
}

public enum ScrollTransform {
    /// 픽셀 값은 한 줄을 10pt로 본다(macOS 기본).
    static let pointsPerLine: Int64 = 10

    /// 트랙패드·매직 마우스(손가락 제스처)인지. 손가락으로 만든 스크롤은 시작·이동·끝 단계(phase)나
    /// 관성 단계(momentum)가 붙는다. 휠 마우스는 부드러운 스크롤을 켜서 '연속' 신호가 와도 단계가 없다.
    public static func isGesture(scrollPhase: Int64, momentumPhase: Int64) -> Bool {
        scrollPhase != 0 || momentumPhase != 0
    }

    /// 휠 마우스 이벤트만 바꾼다. 트랙패드·매직 마우스는 그대로 둔다.
    public static func apply(vertical: ScrollAxis, horizontal: ScrollAxis, isGesture: Bool,
                             options: ScrollOptions) -> (vertical: ScrollAxis, horizontal: ScrollAxis) {
        guard !isGesture else { return (vertical, horizontal) }
        var v = vertical, h = horizontal
        if let n = options.linearLines {
            v = linear(v, lines: Int64(n))
            h = linear(h, lines: Int64(n))
        }
        if options.reverseVertical { v.negate() }
        if options.reverseHorizontal { h.negate() }
        return (v, h)
    }

    /// 가속과 상관없이 한 칸에 `lines`줄만 움직이게 한다.
    static func linear(_ axis: ScrollAxis, lines: Int64) -> ScrollAxis {
        guard !axis.isZero else { return axis }
        let n = axis.sign * lines
        return ScrollAxis(lines: n, fixed: Double(n), points: n * pointsPerLine)
    }
}

// MARK: - 마우스 옆 버튼

public enum SideButtons {
    /// 옆 버튼을 ⌘[ / ⌘] 로 바꿔 줄 앱. 다른 앱에서는 ⌘[ 가 '내어쓰기' 같은 다른 뜻이라 건드리지 않는다.
    public static let supportedApps: Set<String> = [
        "com.apple.finder", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.naver.Whale", "com.microsoft.edgemac", "org.mozilla.firefox",
        "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "app.zen-browser.zen",
    ]

    /// 버튼 번호(0=왼쪽, 1=오른쪽, 2=가운데, 3=뒤로, 4=앞으로)에 해당하는 키. 해당 없으면 nil.
    public static func key(forButton button: Int64, app: String?) -> UInt16? {
        guard let app, supportedApps.contains(app) else { return nil }
        switch button {
        case 3: return KeyCode.leftBracket
        case 4: return KeyCode.rightBracket
        default: return nil
        }
    }
}

// MARK: - ⌘Q 실수 방지

public struct QuitGuard: Sendable {
    public var window: TimeInterval
    private var lastPress: (app: String, time: TimeInterval)?

    public init(window: TimeInterval = 1.0) {
        self.window = window
    }

    /// true면 이번 입력으로 실제 종료한다. false면 안내만 띄운다.
    public mutating func press(app: String, time: TimeInterval) -> Bool {
        if let last = lastPress, last.app == app, time - last.time <= window {
            lastPress = nil
            return true
        }
        lastPress = (app, time)
        return false
    }
}

// MARK: - 링크 추적 코드 제거

public enum URLCleaner {
    static let trackingParams: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmkt", "mkt_tok", "ref_src", "ref_url",
        "spm", "scm", "_ga", "_gl", "oly_anon_id", "oly_enc_id", "vero_id", "wickedid",
    ]
    /// 특정 사이트에서만 추적용인 파라미터.
    static let siteParams: [String: Set<String>] = [
        "youtube.com": ["si", "feature", "pp"],
        "youtu.be": ["si", "feature"],
        "open.spotify.com": ["si"],
        "instagram.com": ["utm_source", "igsh"],
        "x.com": ["s", "t"],
        "twitter.com": ["s", "t"],
    ]

    /// 추적 파라미터를 뺀 링크. 바뀐 게 없거나 링크가 아니면 nil.
    public static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host?.lowercased(),
              let items = comps.queryItems, !items.isEmpty
        else { return nil }
        let siteSpecific = siteParams.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? []
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !(name.hasPrefix("utm_") || trackingParams.contains(name) || siteSpecific.contains(name))
        }
        guard kept.count != items.count else { return nil }
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.string
    }
}

// MARK: - 표시 형식

public enum Format {
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1000 && i < units.count - 1 {
            v /= 1000
            i += 1
        }
        if i == 0 { return "\(value)B" }
        return v >= 100 ? String(format: "%.0f%@", v, units[i]) : String(format: "%.1f%@", v, units[i])
    }

    /// 메모리 크기. macOS(활동 모니터)처럼 1GB = 1024³ 바이트로 센다. 48GB 램은 "48GB".
    public static func memory(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(value)B" }
        if v >= 100 || (v >= 10 && abs(v - v.rounded()) < 0.05) { return String(format: "%.0f%@", v, units[i]) }
        return String(format: "%.1f%@", v, units[i])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(0, bytesPerSecond))) + "/s"
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    public static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)분" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)시간" : "\(h)시간 \(m)분"
    }

    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(red), c(green), c(blue))
    }
}
