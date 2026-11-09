import Foundation

/// macOS 가상 키 코드(kVK_*).
public enum KeyCode {
    public static let a: UInt16 = 0
    public static let x: UInt16 = 7
    public static let c: UInt16 = 8
    public static let v: UInt16 = 9
    public static let o: UInt16 = 31
    public static let n: UInt16 = 45
    public static let tab: UInt16 = 48
    public static let returnKey: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let delete: UInt16 = 51          // Backspace (맥 키보드의 delete)
    public static let forwardDelete: UInt16 = 117  // ⌦ (fn+delete, 윈도우 키보드의 Delete)
    public static let escape: UInt16 = 53
    public static let space: UInt16 = 49
    public static let f2: UInt16 = 120
    public static let f18: UInt16 = 79
    public static let rightCommand: UInt16 = 54
    public static let rightOption: UInt16 = 61
    /// 윈도우용 한국어 키보드의 한/영 키(HID Lang1)가 들어오는 코드.
    public static let lang1: UInt16 = 104
    public static let q: UInt16 = 12
    public static let t: UInt16 = 17
    public static let p: UInt16 = 35
    public static let m: UInt16 = 46
    public static let leftBracket: UInt16 = 33
    public static let rightBracket: UInt16 = 30
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
}

/// CGEventFlags 원시 비트.
public enum RawFlag {
    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    // 좌우 구분 비트 (NX_DEVICE*KEYMASK)
    public static let leftCommand: UInt64 = 0x08
    public static let rightCommand: UInt64 = 0x10
    public static let leftOption: UInt64 = 0x20
    public static let rightOption: UInt64 = 0x40
}

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let control = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)

    /// fn, 숫자패드 같은 비트는 무시하고 네 가지 수정키만 본다.
    public init(rawFlags: UInt64) {
        var m: Modifiers = []
        if rawFlags & RawFlag.command != 0 { m.insert(.command) }
        if rawFlags & RawFlag.option != 0 { m.insert(.option) }
        if rawFlags & RawFlag.control != 0 { m.insert(.control) }
        if rawFlags & RawFlag.shift != 0 { m.insert(.shift) }
        self = m
    }

    public var rawFlags: UInt64 {
        var f: UInt64 = 0
        if contains(.command) { f |= RawFlag.command }
        if contains(.option) { f |= RawFlag.option }
        if contains(.control) { f |= RawFlag.control }
        if contains(.shift) { f |= RawFlag.shift }
        return f
    }
}

/// 키 입력 하나에 대해 할 일.
public enum KeyAction: Equatable, Sendable {
    /// 손대지 않고 통과.
    case pass
    /// 삼킨다(앱에 전달하지 않음).
    case swallow
    case openActivityMonitor
    /// 원래 입력을 삼키고 이 키 조합을 대신 보낸다.
    case post(key: UInt16, modifiers: Modifiers)
    /// Finder 잘라내기: ⌘C를 보내고 '잘라내기 대기' 상태로.
    case finderCut
    /// Finder 붙여넣기: 잘라내기 대기 중이면 ⌘⌥V(이동)로, 아니면 그대로.
    case finderPaste
    /// Finder 복사: 그대로 통과시키고 잘라내기 대기 해제.
    case finderCopy
    case toggleInputSource
    /// 한글 입력 중이면 영문으로 바꾸고, Esc는 그대로 통과.
    case switchToEnglishThenPass
    case newTextFile
    case window(WindowLayout)
    case clipboardHistory
    case plainTextPaste
    /// ⌘Q: 짧은 시간 안에 두 번 눌렀는지 보고 종료 여부를 정한다.
    case quitGuard
    case tool(ToolAction)
    /// ⌥Tab 창 전환: 처음 누르면 열고, 열려 있으면 다음(또는 이전) 창으로.
    case windowSwitcher(forward: Bool)
    case finderCopyPath
    case openTerminalHere
}

/// 단축키로 부르는 도구.
public enum ToolAction: Equatable, Sendable {
    case copyTextFromScreen
    case pickColor
    case toggleMicMute
}

public struct KeyInput: Sendable {
    public var keyCode: UInt16
    public var modifiers: Modifiers
    public var isAutorepeat: Bool
    public var frontmostBundleID: String?

    public init(keyCode: UInt16, modifiers: Modifiers, isAutorepeat: Bool = false, frontmostBundleID: String?) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isAutorepeat = isAutorepeat
        self.frontmostBundleID = frontmostBundleID
    }
}

/// 어떤 키를 무엇으로 바꿀지 정하는 순수 규칙. 시스템 상태는 인자로만 받는다.
public struct KeyRules: Sendable {
    public static let finderBundleID = "com.apple.finder"

    public var enabled: Set<FeatureID>

    public init(enabled: Set<FeatureID>) {
        self.enabled = enabled
    }

    /// - Parameter isTextFocused: 지금 포커스가 글자 입력란인지(이름 바꾸는 중, 검색창 등). 필요할 때만 호출된다.
    public func keyDown(_ input: KeyInput, isTextFocused: () -> Bool) -> KeyAction {
        let code = input.keyCode
        let mods = input.modifiers

        if enabled.contains(.taskManager) {
            if code == KeyCode.escape && mods == [.control, .shift] { return .openActivityMonitor }
            if (code == KeyCode.delete || code == KeyCode.forwardDelete) && mods == [.control, .command] {
                return .openActivityMonitor
            }
        }

        if enabled.contains(.capsLockHangul) && code == KeyCode.f18 {
            return input.isAutorepeat ? .swallow : .toggleInputSource
        }

        if enabled.contains(.hangulKey) && code == KeyCode.lang1 {
            return input.isAutorepeat ? .swallow : .toggleInputSource
        }

        if enabled.contains(.escToEnglish) && code == KeyCode.escape && mods.isEmpty {
            return .switchToEnglishThenPass
        }

        // ⌥Tab은 꾹 누르고 있으면 계속 넘어가야 해서 자동 반복도 받는다.
        if enabled.contains(.windowSwitcher) && code == KeyCode.tab,
           !Self.optionTabApps.contains(input.frontmostBundleID ?? "") {
            if mods == [.option] { return .windowSwitcher(forward: true) }
            if mods == [.option, .shift] { return .windowSwitcher(forward: false) }
        }

        if let action = globalShortcut(code: code, mods: mods, input: input) {
            return input.isAutorepeat ? .swallow : action
        }

        guard input.frontmostBundleID == Self.finderBundleID else { return .pass }
        return finderKeyDown(input, isTextFocused: isTextFocused)
    }

    /// ⌥Tab을 자체 기능(표 칸 안에 탭 넣기)으로 쓰는 앱.
    static let optionTabApps: Set<String> = ["com.apple.iWork.Numbers", "com.apple.iWork.Pages", "com.apple.iWork.Keynote"]

    private static let quitGuardExempt: Set<String> = [finderBundleID, "kr.macpyeon.MacPyeon"]

    private func globalShortcut(code: UInt16, mods: Modifiers, input: KeyInput) -> KeyAction? {
        if enabled.contains(.windowSnap) {
            switch (code, mods) {
            case (KeyCode.leftArrow, [.control, .option]): return .window(.leftHalf)
            case (KeyCode.rightArrow, [.control, .option]): return .window(.rightHalf)
            case (KeyCode.upArrow, [.control, .option]), (KeyCode.returnKey, [.control, .option]): return .window(.maximize)
            case (KeyCode.downArrow, [.control, .option]): return .window(.restore)
            case (KeyCode.upArrow, [.control, .option, .shift]): return .window(.topHalf)
            case (KeyCode.downArrow, [.control, .option, .shift]): return .window(.bottomHalf)
            case (KeyCode.c, [.control, .option]): return .window(.center)
            case (KeyCode.leftArrow, [.control, .option, .command]): return .window(.previousDisplay)
            case (KeyCode.rightArrow, [.control, .option, .command]): return .window(.nextDisplay)
            default: break
            }
        }
        if enabled.contains(.toolShortcuts) {
            switch (code, mods) {
            case (KeyCode.t, [.control, .option]): return .tool(.copyTextFromScreen)
            case (KeyCode.p, [.control, .option]): return .tool(.pickColor)
            case (KeyCode.m, [.control, .option]): return .tool(.toggleMicMute)
            default: break
            }
        }
        if enabled.contains(.clipboardHistory) && code == KeyCode.v && mods == [.control, .option] {
            return .clipboardHistory
        }
        if enabled.contains(.plainTextPaste) && code == KeyCode.v && mods == [.command, .option, .shift] {
            return .plainTextPaste
        }
        if enabled.contains(.quitProtection) && code == KeyCode.q && mods == [.command],
           !Self.quitGuardExempt.contains(input.frontmostBundleID ?? "") {
            return .quitGuard
        }
        return nil
    }

    private func finderKeyDown(_ input: KeyInput, isTextFocused: () -> Bool) -> KeyAction {
        let code = input.keyCode
        let mods = input.modifiers

        if enabled.contains(.finderNewTextFile) && code == KeyCode.n && mods == [.control, .option] {
            return input.isAutorepeat ? .swallow : .newTextFile
        }
        if enabled.contains(.finderWindowsShortcuts) && mods == [.control, .shift] {
            switch code {
            case KeyCode.n: return input.isAutorepeat ? .swallow : .post(key: KeyCode.n, modifiers: [.command, .shift])
            case KeyCode.c: return input.isAutorepeat ? .swallow : .finderCopyPath
            case KeyCode.t: return input.isAutorepeat ? .swallow : .openTerminalHere
            default: break
            }
        }

        // 아래 규칙은 이름 바꾸기·검색 입력 중에는 적용하지 않는다.
        let candidates: Bool = {
            switch (code, mods) {
            case (KeyCode.f2, []),
                 (KeyCode.returnKey, []), (KeyCode.keypadEnter, []),
                 (KeyCode.forwardDelete, []), (KeyCode.delete, []),
                 (KeyCode.x, [.command]), (KeyCode.v, [.command]), (KeyCode.c, [.command]):
                return true
            default:
                return false
            }
        }()
        guard candidates, !isTextFocused() else { return .pass }

        switch (code, mods) {
        case (KeyCode.f2, []) where enabled.contains(.finderF2Rename):
            return input.isAutorepeat ? .swallow : .post(key: KeyCode.returnKey, modifiers: [])
        case (KeyCode.returnKey, []) where enabled.contains(.finderEnterOpens),
             (KeyCode.keypadEnter, []) where enabled.contains(.finderEnterOpens):
            return input.isAutorepeat ? .swallow : .post(key: KeyCode.o, modifiers: [.command])
        // 맥북에는 ⌦ 키가 없어서, 지우기(delete) 키도 휴지통으로 보내기로 쓴다.
        case (KeyCode.forwardDelete, []) where enabled.contains(.finderDeleteKey),
             (KeyCode.delete, []) where enabled.contains(.finderDeleteKey):
            return input.isAutorepeat ? .swallow : .post(key: KeyCode.delete, modifiers: [.command])
        case (KeyCode.x, [.command]) where enabled.contains(.finderCutPaste):
            return input.isAutorepeat ? .swallow : .finderCut
        case (KeyCode.v, [.command]) where enabled.contains(.finderCutPaste) || enabled.contains(.finderPasteImage):
            return input.isAutorepeat ? .swallow : .finderPaste
        case (KeyCode.c, [.command]) where enabled.contains(.finderCutPaste):
            return .finderCopy
        default:
            return .pass
        }
    }

    /// 맥 키보드 맨 윗줄은 기본이 밝기·볼륨 키라서 F2를 누르면 '밝기 올리기'가 온다.
    /// Finder에서 파일을 고른 상태라면 이걸 F2(이름 바꾸기)로 본다. 다른 곳에서는 밝기 키 그대로.
    public func mediaKey(_ key: MediaKey, isDown: Bool, isRepeat: Bool, frontmostBundleID: String?,
                         isTextFocused: () -> Bool) -> KeyAction {
        guard enabled.contains(.finderF2Rename), key == .brightnessUp,
              frontmostBundleID == Self.finderBundleID, !isTextFocused() else { return .pass }
        guard isDown, !isRepeat else { return .swallow }
        return .post(key: KeyCode.returnKey, modifiers: [])
    }

    public func keyUp(keyCode: UInt16) -> KeyAction {
        if enabled.contains(.capsLockHangul) && keyCode == KeyCode.f18 { return .swallow }
        if enabled.contains(.hangulKey) && keyCode == KeyCode.lang1 { return .swallow }
        return .pass
    }
}

/// 시스템 특수 키(NX_SYSDEFINED, subtype 8)의 종류.
public enum MediaKey: Equatable, Sendable {
    case brightnessUp
    case brightnessDown
    case other(Int)

    /// 이벤트의 data1 값에서 키 종류와 눌림 여부를 꺼낸다.
    /// data1 = (키 종류 << 16) | (상태 << 8) | 반복 여부, 상태 0x0A = 누름, 0x0B = 뗌.
    public static func decode(data1: Int) -> (key: MediaKey, isDown: Bool, isRepeat: Bool) {
        let code = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        let key: MediaKey
        switch code {
        case 2: key = .brightnessUp      // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .brightnessDown    // NX_KEYTYPE_BRIGHTNESS_DOWN
        default: key = .other(code)
        }
        return (key, state == 0x0A, (data1 & 0x1) != 0)
    }
}

/// 수정키 하나만 짧게 눌렀다 뗐는지 알아낸다(오른쪽 ⌘ 한/영 전환).
public struct ModifierTapDetector: Sendable {
    public var choice: HangulKeyChoice
    public var maxDuration: TimeInterval
    private var pressedAt: TimeInterval?

    public init(choice: HangulKeyChoice, maxDuration: TimeInterval = 0.5) {
        self.choice = choice
        self.maxDuration = maxDuration
    }

    private var targetKeyCode: UInt16 {
        choice == .rightCommand ? KeyCode.rightCommand : KeyCode.rightOption
    }

    private var targetDeviceBit: UInt64 {
        choice == .rightCommand ? RawFlag.rightCommand : RawFlag.rightOption
    }

    /// 대상 키 말고 다른 수정키가 눌려 있는지.
    private func othersHeld(_ rawFlags: UInt64) -> Bool {
        var others = Modifiers(rawFlags: rawFlags)
        switch choice {
        case .rightCommand:
            others.remove(.command)
            if rawFlags & RawFlag.leftCommand != 0 { return true }
        case .rightOption:
            others.remove(.option)
            if rawFlags & RawFlag.leftOption != 0 { return true }
        }
        return !others.isEmpty
    }

    /// flagsChanged 이벤트마다 부른다. 전환해야 하면 true.
    public mutating func flagsChanged(keyCode: UInt16, rawFlags: UInt64, time: TimeInterval) -> Bool {
        guard keyCode == targetKeyCode else {
            pressedAt = nil
            return false
        }
        let isDown = rawFlags & targetDeviceBit != 0
        if isDown {
            pressedAt = othersHeld(rawFlags) ? nil : time
            return false
        }
        defer { pressedAt = nil }
        guard let start = pressedAt else { return false }
        return time - start <= maxDuration
    }

    /// 대상 키를 누른 채로 다른 키를 누르거나 클릭하면 전환하지 않는다.
    public mutating func interrupt() {
        pressedAt = nil
    }
}
