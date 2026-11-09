import Testing
@testable import MacPyeonCore

private let finder = KeyRules.finderBundleID
private let all = Set(FeatureID.allCases)

private func down(_ code: UInt16, _ mods: Modifiers = [], app: String? = finder, repeat_: Bool = false,
                  rules: KeyRules = KeyRules(enabled: all), text: Bool = false) -> KeyAction {
    rules.keyDown(KeyInput(keyCode: code, modifiers: mods, isAutorepeat: repeat_, frontmostBundleID: app),
                  isTextFocused: { text })
}

@Suite struct KeyRulesTests {
    @Test func taskManagerAnywhere() {
        #expect(down(KeyCode.escape, [.control, .shift], app: "com.google.Chrome") == .openActivityMonitor)
        #expect(down(KeyCode.delete, [.control, .command], app: nil) == .openActivityMonitor)
        #expect(down(KeyCode.forwardDelete, [.control, .command]) == .openActivityMonitor)
        #expect(down(KeyCode.delete, [.control, .option], app: nil) != .openActivityMonitor)
        #expect(down(KeyCode.escape, [.control]) != .openActivityMonitor)
    }

    @Test func finderKeysOnlyInFinder() {
        #expect(down(KeyCode.f2) == .post(key: KeyCode.returnKey, modifiers: []))
        #expect(down(KeyCode.f2, app: "com.apple.Safari") == .pass)
        #expect(down(KeyCode.forwardDelete) == .post(key: KeyCode.delete, modifiers: [.command]))
        #expect(down(KeyCode.delete) == .post(key: KeyCode.delete, modifiers: [.command])) // 맥북 지우기 키
        #expect(down(KeyCode.delete, app: "com.apple.Safari") == .pass)
        #expect(down(KeyCode.x, [.command]) == .finderCut)
        #expect(down(KeyCode.v, [.command]) == .finderPaste)
        #expect(down(KeyCode.c, [.command]) == .finderCopy)
        #expect(down(KeyCode.returnKey) == .post(key: KeyCode.o, modifiers: [.command]))
        #expect(down(KeyCode.n, [.control, .option]) == .newTextFile)
    }

    @Test func finderKeysPassWhileEditingText() {
        // 이름 바꾸는 중에는 ⌘X, Enter, F2가 원래대로 동작해야 한다.
        #expect(down(KeyCode.x, [.command], text: true) == .pass)
        #expect(down(KeyCode.returnKey, text: true) == .pass)
        #expect(down(KeyCode.f2, text: true) == .pass)
        #expect(down(KeyCode.forwardDelete, text: true) == .pass)
        #expect(down(KeyCode.delete, text: true) == .pass) // 이름 바꾸는 중에는 글자 지우기
    }

    @Test func textFocusCheckedOnlyWhenNeeded() {
        var asked = false
        _ = KeyRules(enabled: all).keyDown(
            KeyInput(keyCode: KeyCode.a, modifiers: [], frontmostBundleID: finder),
            isTextFocused: { asked = true; return false })
        #expect(!asked) // 일반 글자 입력마다 손쉬운 사용 API를 부르지 않는다.
    }

    @Test func disabledFeaturesPass() {
        let none = KeyRules(enabled: [])
        #expect(down(KeyCode.f2, rules: none) == .pass)
        #expect(down(KeyCode.x, [.command], rules: none) == .pass)
        #expect(down(KeyCode.escape, [.control, .shift], rules: none) == .pass)
        #expect(down(KeyCode.f18, rules: none) == .pass)
        let onlyF2 = KeyRules(enabled: [.finderF2Rename])
        #expect(down(KeyCode.returnKey, rules: onlyF2) == .pass)
        #expect(down(KeyCode.x, [.command], rules: onlyF2) == .pass)
    }

    @Test func autorepeatDoesNotRepeatActions() {
        #expect(down(KeyCode.forwardDelete, repeat_: true) == .swallow)
        #expect(down(KeyCode.f18, app: nil, repeat_: true) == .swallow)
    }

    @Test func hangulKeys() {
        #expect(down(KeyCode.f18, app: nil) == .toggleInputSource)
        #expect(down(KeyCode.lang1, app: nil) == .toggleInputSource)
        #expect(KeyRules(enabled: all).keyUp(keyCode: KeyCode.f18) == .swallow)
        #expect(down(KeyCode.escape, app: "com.googlecode.iterm2") == .switchToEnglishThenPass)
        #expect(down(KeyCode.escape, [.command], app: nil) == .pass)
    }

    @Test func modifiersIgnoreFnAndKeypadBits() {
        let fn: UInt64 = 0x80_0000
        let numpad: UInt64 = 0x20_0000
        #expect(Modifiers(rawFlags: fn | numpad).isEmpty)
        #expect(Modifiers(rawFlags: RawFlag.command | fn) == [.command])
        #expect(Modifiers([.command, .shift]).rawFlags == RawFlag.command | RawFlag.shift)
    }
}

@Suite struct ModifierTapDetectorTests {
    let rightCmdDown = RawFlag.command | RawFlag.rightCommand
    let up: UInt64 = 0

    @Test func shortTapFires() {
        var d = ModifierTapDetector(choice: .rightCommand)
        let r1 = d.flagsChanged(keyCode: KeyCode.rightCommand, rawFlags: rightCmdDown, time: 1.0)
        #expect(!r1)
        let r2 = d.flagsChanged(keyCode: KeyCode.rightCommand, rawFlags: up, time: 1.1)
        #expect(r2)
    }

    @Test func comboOrLongPressDoesNotFire() {
        var d = ModifierTapDetector(choice: .rightCommand)
        _ = d.flagsChanged(keyCode: KeyCode.rightCommand, rawFlags: rightCmdDown, time: 1.0)
        d.interrupt() // ⌘C 처럼 다른 키를 같이 누름
        let r3 = d.flagsChanged(keyCode: KeyCode.rightCommand, rawFlags: up, time: 1.1)
        #expect(!r3)

        _ = d.flagsChanged(keyCode: KeyCode.rightCommand, rawFlags: rightCmdDown, time: 2.0)
        let r4 = d.flagsChanged(keyCode: KeyCode.rightCommand, rawFlags: up, time: 3.0)
        #expect(!r4)
    }

    @Test func leftCommandHeldDoesNotFire() {
        var d = ModifierTapDetector(choice: .rightCommand)
        let both = RawFlag.command | RawFlag.rightCommand | RawFlag.leftCommand
        _ = d.flagsChanged(keyCode: KeyCode.rightCommand, rawFlags: both, time: 1.0)
        let r5 = d.flagsChanged(keyCode: KeyCode.rightCommand, rawFlags: RawFlag.command | RawFlag.leftCommand, time: 1.1)
        #expect(!r5)
    }

    @Test func rightOptionChoice() {
        var d = ModifierTapDetector(choice: .rightOption)
        let r6 = d.flagsChanged(keyCode: KeyCode.rightCommand, rawFlags: rightCmdDown, time: 1.0)
        #expect(!r6)
        let r7 = d.flagsChanged(keyCode: KeyCode.rightCommand, rawFlags: up, time: 1.1)
        #expect(!r7)
        _ = d.flagsChanged(keyCode: KeyCode.rightOption, rawFlags: RawFlag.option | RawFlag.rightOption, time: 2.0)
        let r8 = d.flagsChanged(keyCode: KeyCode.rightOption, rawFlags: up, time: 2.1)
        #expect(r8)
    }
}

@Suite struct CatalogTests {
    @Test func everyFeatureHasInfo() {
        for id in FeatureID.allCases { #expect(FeatureCatalog.info(id).id == id) }
        #expect(FeatureCatalog.all.count == FeatureID.allCases.count)
    }

    @Test func defaultsFeaturesHaveTweaksAndOthersDont() {
        for info in FeatureCatalog.all {
            let tweaks = DefaultsTweaks.tweaks(for: info.id)
            #expect((info.kind == .defaults) == !tweaks.isEmpty, "\(info.id)")
        }
    }

    @Test func keyBindingsMergeKeepsUserEntries() {
        let user: [String: Any] = ["^w": ["deleteWordBackward:"], "₩": ["insertText:", "W"]]
        let on = KeyBindings.entries(for: [.wonToBacktick, .homeEndKeys])
        let first = KeyBindings.merge(existing: user, previouslyManaged: [], previouslyOverridden: [:], managed: on)
        #expect((first.contents["₩"] as? [String]) == ["insertText:", "`"])
        #expect(first.contents["^w"] != nil)
        #expect(first.contents.count == 2 + 8)

        // 끄면 사용자 원래 값으로 돌아간다.
        let off = KeyBindings.merge(existing: first.contents, previouslyManaged: first.managedKeys,
                                    previouslyOverridden: first.overridden, managed: [:])
        #expect((off.contents["₩"] as? [String]) == ["insertText:", "W"])
        #expect(off.contents.count == 2)
        #expect(off.managedKeys.isEmpty)
    }
}

@Suite struct MediaKeyTests {
    @Test func decodesBrightnessKeys() {
        let down = MediaKey.decode(data1: (2 << 16) | (0x0A << 8))
        #expect(down.key == .brightnessUp && down.isDown && !down.isRepeat)
        let up = MediaKey.decode(data1: (2 << 16) | (0x0B << 8))
        #expect(up.key == .brightnessUp && !up.isDown)
        #expect(MediaKey.decode(data1: (0 << 16) | (0x0A << 8)).key == .other(0)) // 볼륨 올리기
    }

    @Test func brightnessUpRenamesOnlyInFinderSelection() {
        let rules = KeyRules(enabled: [.finderF2Rename])
        let finder = KeyRules.finderBundleID
        #expect(rules.mediaKey(.brightnessUp, isDown: true, isRepeat: false, frontmostBundleID: finder,
                               isTextFocused: { false }) == .post(key: KeyCode.returnKey, modifiers: []))
        #expect(rules.mediaKey(.brightnessUp, isDown: false, isRepeat: false, frontmostBundleID: finder,
                               isTextFocused: { false }) == .swallow)
        // 다른 앱, 이름 입력 중, 밝기 내리기, 기능 꺼짐 → 원래 밝기 키 그대로
        #expect(rules.mediaKey(.brightnessUp, isDown: true, isRepeat: false, frontmostBundleID: "com.apple.Safari",
                               isTextFocused: { false }) == .pass)
        #expect(rules.mediaKey(.brightnessUp, isDown: true, isRepeat: false, frontmostBundleID: finder,
                               isTextFocused: { true }) == .pass)
        #expect(rules.mediaKey(.brightnessDown, isDown: true, isRepeat: false, frontmostBundleID: finder,
                               isTextFocused: { false }) == .pass)
        #expect(KeyRules(enabled: []).mediaKey(.brightnessUp, isDown: true, isRepeat: false, frontmostBundleID: finder,
                                               isTextFocused: { false }) == .pass)
    }
}

struct NewShortcutTests {
    private func run(_ rules: KeyRules, _ code: UInt16, _ mods: Modifiers, app: String = "com.apple.finder", repeatKey: Bool = false) -> KeyAction {
        rules.keyDown(KeyInput(keyCode: code, modifiers: mods, isAutorepeat: repeatKey, frontmostBundleID: app), isTextFocused: { false })
    }

    @Test func optionTabSwitchesWindowsEverywhere() {
        let rules = KeyRules(enabled: [.windowSwitcher])
        #expect(run(rules, KeyCode.tab, [.option], app: "com.google.Chrome") == .windowSwitcher(forward: true))
        #expect(run(rules, KeyCode.tab, [.option, .shift]) == .windowSwitcher(forward: false))
        #expect(run(rules, KeyCode.tab, [.option], repeatKey: true) == .windowSwitcher(forward: true))
        #expect(run(rules, KeyCode.tab, [.command]) == .pass)
        #expect(run(KeyRules(enabled: []), KeyCode.tab, [.option]) == .pass)
        #expect(run(rules, KeyCode.tab, [.option], app: "com.apple.iWork.Numbers") == .pass)
    }

    @Test func finderWindowsShortcutsOnlyInFinder() {
        let rules = KeyRules(enabled: [.finderWindowsShortcuts])
        #expect(run(rules, KeyCode.n, [.control, .shift]) == .post(key: KeyCode.n, modifiers: [.command, .shift]))
        #expect(run(rules, KeyCode.c, [.control, .shift]) == .finderCopyPath)
        #expect(run(rules, KeyCode.t, [.control, .shift]) == .openTerminalHere)
        #expect(run(rules, KeyCode.c, [.control, .shift], app: "com.apple.Terminal") == .pass)
    }

    @Test func newFeaturesTurnOnOnceForExistingUsers() {
        // 기록이 없던 0.1.x 사용자: 새 추천 기능만
        let fresh = FeatureCatalog.newlyRecommended(known: nil)
        let expected: Set<FeatureID> = [.clipboardNFC, .inputSourceIndicator, .windowSwitcher, .finderWindowsShortcuts]
        #expect(fresh == expected.subtracting(FeatureCatalog.unavailableHere))
        // 이미 본 기능은 다시 켜지 않는다(사용자가 끈 것 존중)
        let all = Set(FeatureID.allCases.map(\.rawValue))
        #expect(FeatureCatalog.newlyRecommended(known: all).isEmpty)
    }
}


struct AvailabilityTests {
    @Test func indicatorOnlyBeforeSonoma() {
        #expect(FeatureCatalog.unavailable(onMacOS: 13).isEmpty)
        #expect(FeatureCatalog.unavailable(onMacOS: 14) == [.inputSourceIndicator])
    }
}
