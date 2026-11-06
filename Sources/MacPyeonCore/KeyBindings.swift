import Foundation

/// ~/Library/KeyBindings/DefaultKeyBinding.dict 에 넣을 항목을 만든다.
///
/// Cocoa 텍스트 입력(메모, Safari, Pages, 대부분의 macOS 앱)이 이 파일을 읽는다.
/// 사용자가 원래 갖고 있던 항목은 건드리지 않고, 우리가 넣은 키만 관리한다.
public enum KeyBindings {
    // NSEvent 함수 키 문자 (NSHomeFunctionKey, NSEndFunctionKey)
    static let home = "\u{F729}"
    static let end = "\u{F72B}"

    public static func entries(for enabled: Set<FeatureID>) -> [String: [String]] {
        var result: [String: [String]] = [:]
        if enabled.contains(.wonToBacktick) {
            result["₩"] = ["insertText:", "`"]
        }
        if enabled.contains(.homeEndKeys) {
            result[home] = ["moveToBeginningOfLine:"]
            result[end] = ["moveToEndOfLine:"]
            result["$" + home] = ["moveToBeginningOfLineAndModifySelection:"]
            result["$" + end] = ["moveToEndOfLineAndModifySelection:"]
            result["^" + home] = ["moveToBeginningOfDocument:"]
            result["^" + end] = ["moveToEndOfDocument:"]
            result["^$" + home] = ["moveToBeginningOfDocumentAndModifySelection:"]
            result["^$" + end] = ["moveToEndOfDocumentAndModifySelection:"]
        }
        return result
    }

    public struct MergeResult {
        public let contents: [String: Any]
        /// 이번에 우리가 관리하게 된 키.
        public let managedKeys: Set<String>
        /// 우리가 덮어쓴 사용자 원래 값. 기능을 끄면 이 값으로 되돌린다.
        public let overridden: [String: Any]
    }

    /// 기존 파일 내용에서 예전에 우리가 넣은 키를 사용자 원래 값으로 되돌리고, 이번에 넣을 키를 더한다.
    public static func merge(
        existing: [String: Any],
        previouslyManaged: Set<String>,
        previouslyOverridden: [String: Any],
        managed: [String: [String]]
    ) -> MergeResult {
        var contents = existing
        for key in previouslyManaged {
            if let original = previouslyOverridden[key] {
                contents[key] = original
            } else {
                contents.removeValue(forKey: key)
            }
        }
        var overridden: [String: Any] = [:]
        for (key, value) in managed {
            if let original = contents[key] { overridden[key] = original }
            contents[key] = value
        }
        return MergeResult(contents: contents, managedKeys: Set(managed.keys), overridden: overridden)
    }
}
