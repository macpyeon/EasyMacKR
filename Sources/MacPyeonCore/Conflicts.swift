import Foundation

/// 같은 기능을 켠 다른 앱. 둘 다 켜면 스크롤이 두 번 뒤집히거나 단축키가 두 번 실행된다.
public struct FeatureConflict: Equatable, Sendable {
    public let appName: String
    public let feature: FeatureID
}

public enum Conflicts {
    struct Rule {
        let appName: String
        let bundleID: String
        let domain: String
        let key: String
        let feature: FeatureID
    }

    static let rules: [Rule] = {
        let v = ("Vorssaint", "com.vorssaint.utils", "com.vorssaint.utils")
        let pairs: [(String, FeatureID)] = [
            ("scrollInverterEnabled", .mouseScrollReverse),
            ("scrollInverterHorizontalEnabled", .mouseScrollReverseHorizontal),
            ("linearScrollEnabled", .linearScroll),
            ("smoothScrollEnabled", .linearScroll),
            ("mouseNavigationEnabled", .mouseSideButtons),
            ("finderCutPasteEnabled", .finderCutPaste),
            ("finderRenameEnabled", .finderF2Rename),
            ("clipboardHistoryEnabled", .clipboardHistory),
            ("pastePlainEnabled", .plainTextPaste),
            ("quitWindowProtectionEnabled", .quitProtection),
            ("windowLayoutEnabled", .windowSnap),
            ("urlCleanerEnabled", .cleanURLs),
        ]
        return pairs.map { Rule(appName: v.0, bundleID: v.1, domain: v.2, key: $0.0, feature: $0.1) }
    }()

    /// - Parameters:
    ///   - readBool: (설정 도메인, 키) → 값. 없으면 nil.
    ///   - isRunning: 번들 ID → 실행 중인지.
    public static func find(enabled: Set<FeatureID>,
                            readBool: (String, String) -> Bool?,
                            isRunning: (String) -> Bool) -> [FeatureConflict] {
        var result: [FeatureConflict] = []
        for rule in rules where enabled.contains(rule.feature) && isRunning(rule.bundleID) {
            guard readBool(rule.domain, rule.key) == true else { continue }
            let conflict = FeatureConflict(appName: rule.appName, feature: rule.feature)
            if !result.contains(conflict) { result.append(conflict) }
        }
        return result
    }
}
