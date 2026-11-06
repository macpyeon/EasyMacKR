import Carbon
import Foundation
import MacPyeonCore

/// 한/영 입력 소스 전환.
///
/// 영문으로 갈 때는 TISSelectInputSource를 쓴다(안정적).
/// 한글로 갈 때는 TISSelectInputSource가 메뉴 막대 표시만 바뀌고 실제 입력은 그대로인 경우가 있어서,
/// 시스템의 '이전 입력 소스 선택' 단축키가 켜져 있으면 그 단축키를 대신 눌러 준다.
enum InputSourceSwitcher {
    private static var lastKoreanID: String?
    private static var lastEnglishID: String?

    // MARK: 조회

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? T
    }

    static func id(of source: TISInputSource) -> String? { property(source, kTISPropertyInputSourceID) }

    static func isKorean(_ source: TISInputSource) -> Bool {
        if let id = id(of: source), id.hasPrefix("com.apple.inputmethod.Korean") { return true }
        let langs: [String] = property(source, kTISPropertyInputSourceLanguages) ?? []
        return langs.first == "ko"
    }

    private static func isASCIILayout(_ source: TISInputSource) -> Bool {
        let ascii: Bool = property(source, kTISPropertyInputSourceIsASCIICapable) ?? false
        return ascii && !isKorean(source)
    }

    static func current() -> TISInputSource {
        TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    }

    static func isKoreanActive() -> Bool { isKorean(current()) }

    private static func selectableSources() -> [TISInputSource] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceIsSelectCapable: true,
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() else { return [] }
        return (list as? [TISInputSource]) ?? []
    }

    // MARK: 전환

    static func remember() {
        let src = current()
        guard let id = id(of: src) else { return }
        if isKorean(src) { lastKoreanID = id } else if isASCIILayout(src) { lastEnglishID = id }
    }

    static func selectEnglish() {
        remember()
        let sources = selectableSources().filter(isASCIILayout)
        let preferred = [lastEnglishID, "com.apple.keylayout.ABC", "com.apple.keylayout.US"].compactMap { $0 }
        let target = preferred.lazy.compactMap { pid in sources.first { id(of: $0) == pid } }.first ?? sources.first
        if let target { TISSelectInputSource(target) }
    }

    static func selectKorean() {
        remember()
        if let hotkey = SymbolicHotKey.selectPrevious(), hotkey.enabled {
            KeySender.post(key: hotkey.keyCode, modifiers: hotkey.modifiers)
            // 이전 입력 소스가 한글이 아니었다면(입력 소스가 3개 이상) 직접 고른다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !isKoreanActive() { selectKoreanDirectly() }
            }
        } else {
            selectKoreanDirectly()
        }
    }

    private static func selectKoreanDirectly() {
        let sources = selectableSources().filter(isKorean)
        let target = sources.first { id(of: $0) == lastKoreanID } ?? sources.first
        if let target { TISSelectInputSource(target) }
    }

    static func toggle() {
        if isKoreanActive() { selectEnglish() } else { selectKorean() }
    }
}

/// 시스템 설정 > 키보드 > 단축키의 '이전 입력 소스 선택'(ID 60).
struct SymbolicHotKey {
    let enabled: Bool
    let keyCode: UInt16
    let modifiers: Modifiers

    static func selectPrevious() -> SymbolicHotKey? {
        let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                            "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        guard let entry = all?["60"] as? [String: Any] else {
            // 기록이 없으면 기본값(Ctrl+Space, 켜짐)이다.
            return SymbolicHotKey(enabled: true, keyCode: KeyCode.space, modifiers: [.control])
        }
        let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? false
        guard let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [NSNumber], params.count >= 3,
              params[1].intValue != 65535
        else { return SymbolicHotKey(enabled: false, keyCode: 0, modifiers: []) }
        return SymbolicHotKey(
            enabled: enabled,
            keyCode: UInt16(params[1].intValue),
            modifiers: Modifiers(rawFlags: UInt64(params[2].intValue))
        )
    }
}
