import CoreGraphics
import Testing
@testable import MacPyeonCore

private func down(_ code: UInt16, _ mods: Modifiers, app: String? = "com.apple.Safari",
                  enabled: Set<FeatureID> = Set(FeatureID.allCases)) -> KeyAction {
    KeyRules(enabled: enabled).keyDown(KeyInput(keyCode: code, modifiers: mods, frontmostBundleID: app),
                                       isTextFocused: { false })
}

@Suite struct GlobalShortcutTests {
    @Test func windowSnapShortcuts() {
        #expect(down(KeyCode.leftArrow, [.control, .option]) == .window(.leftHalf))
        #expect(down(KeyCode.rightArrow, [.control, .option]) == .window(.rightHalf))
        #expect(down(KeyCode.upArrow, [.control, .option]) == .window(.maximize))
        #expect(down(KeyCode.returnKey, [.control, .option]) == .window(.maximize))
        #expect(down(KeyCode.downArrow, [.control, .option]) == .window(.restore))
        #expect(down(KeyCode.upArrow, [.control, .option, .shift]) == .window(.topHalf))
        #expect(down(KeyCode.rightArrow, [.control, .option, .command]) == .window(.nextDisplay))
        #expect(down(KeyCode.leftArrow, [.control]) == .pass)
        #expect(down(KeyCode.leftArrow, [.control, .option], enabled: []) == .pass)
    }

    @Test func toolAndClipboardShortcuts() {
        #expect(down(KeyCode.t, [.control, .option]) == .tool(.copyTextFromScreen))
        #expect(down(KeyCode.p, [.control, .option]) == .tool(.pickColor))
        #expect(down(KeyCode.m, [.control, .option]) == .tool(.toggleMicMute))
        #expect(down(KeyCode.v, [.control, .option]) == .clipboardHistory)
        #expect(down(KeyCode.v, [.command, .option, .shift]) == .plainTextPaste)
        #expect(down(KeyCode.v, [.command]) == .pass) // Finder가 아닌 앱의 ⌘V는 그대로
    }

    @Test func quitGuardSkipsFinder() {
        #expect(down(KeyCode.q, [.command]) == .quitGuard)
        #expect(down(KeyCode.q, [.command], app: KeyRules.finderBundleID) == .pass)
        #expect(down(KeyCode.q, [.command], enabled: []) == .pass)
    }

    @Test func finderPasteImageAloneStillRoutesPaste() {
        #expect(down(KeyCode.v, [.command], app: KeyRules.finderBundleID, enabled: [.finderPasteImage]) == .finderPaste)
    }

    @Test func shortcutsDoNotOverlapExistingOnes() {
        // 작업 관리자(⌃⌘Delete)와 새 텍스트 문서(⌃⌥N)는 그대로 동작해야 한다.
        #expect(down(KeyCode.delete, [.control, .command]) == .openActivityMonitor)
        #expect(down(KeyCode.n, [.control, .option], app: KeyRules.finderBundleID) == .newTextFile)
    }
}

@Suite struct QuitGuardTests {
    @Test func needsSecondPressWithinWindow() {
        var g = QuitGuard(window: 1.0)
        let q1 = g.press(app: "a", time: 0)
        #expect(!q1)
        let q2 = g.press(app: "a", time: 0.5)
        #expect(q2)
        let q3 = g.press(app: "a", time: 1.0)
        #expect(!q3)   // 새로 시작
        let q4 = g.press(app: "a", time: 2.5)
        #expect(!q4)   // 너무 늦음
        let q5 = g.press(app: "b", time: 2.6)
        #expect(!q5)   // 다른 앱
        let q6 = g.press(app: "b", time: 3.0)
        #expect(q6)
    }
}

@Suite struct ScrollTests {
    let wheelDown = ScrollAxis(lines: -3, fixed: -2.7, points: -27)
    let none = ScrollAxis(lines: 0, fixed: 0, points: 0)

    @Test func reversesOnlyMouseWheel() {
        let opts = ScrollOptions(reverseVertical: true)
        let mouse = ScrollTransform.apply(vertical: wheelDown, horizontal: none, isGesture: false, options: opts)
        #expect(mouse.vertical == ScrollAxis(lines: 3, fixed: 2.7, points: 27))
        let trackpad = ScrollTransform.apply(vertical: wheelDown, horizontal: none, isGesture: true, options: opts)
        #expect(trackpad.vertical == wheelDown)
    }

    @Test func gestureDetection() {
        #expect(ScrollTransform.isGesture(scrollPhase: 1, momentumPhase: 0))   // 트랙패드 시작
        #expect(ScrollTransform.isGesture(scrollPhase: 0, momentumPhase: 2))   // 트랙패드 관성
        #expect(!ScrollTransform.isGesture(scrollPhase: 0, momentumPhase: 0))  // 휠 마우스(부드러운 스크롤 포함)
    }

    @Test func horizontalIndependent() {
        let opts = ScrollOptions(reverseHorizontal: true)
        let out = ScrollTransform.apply(vertical: wheelDown, horizontal: wheelDown, isGesture: false, options: opts)
        #expect(out.vertical == wheelDown)
        #expect(out.horizontal.lines == 3)
    }

    @Test func linearIgnoresAcceleration() {
        let fast = ScrollAxis(lines: -12, fixed: -11.4, points: -114)
        let out = ScrollTransform.apply(vertical: fast, horizontal: none, isGesture: false,
                                        options: ScrollOptions(linearLines: 3))
        #expect(out.vertical == ScrollAxis(lines: -3, fixed: -3, points: -30))
        #expect(out.horizontal == none)
        let both = ScrollTransform.apply(vertical: fast, horizontal: none, isGesture: false,
                                         options: ScrollOptions(reverseVertical: true, linearLines: 2))
        #expect(both.vertical.lines == 2)
    }

    @Test func optionsFromFeatures() {
        let o = ScrollOptions(enabled: [.mouseScrollReverse, .linearScroll], linesPerNotch: 4)
        #expect(o.reverseVertical && !o.reverseHorizontal && o.linearLines == 4)
        #expect(!ScrollOptions(enabled: [], linesPerNotch: 3).isActive)
    }
}

@Suite struct SideButtonTests {
    @Test func mapsOnlyInBrowsersAndFinder() {
        #expect(SideButtons.key(forButton: 3, app: "com.naver.Whale") == KeyCode.leftBracket)
        #expect(SideButtons.key(forButton: 4, app: "com.apple.finder") == KeyCode.rightBracket)
        #expect(SideButtons.key(forButton: 3, app: "com.microsoft.VSCode") == nil) // ⌘[ = 내어쓰기
        #expect(SideButtons.key(forButton: 2, app: "com.apple.Safari") == nil)
    }
}

@Suite struct WindowGeometryTests {
    let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)

    @Test func halvesAndMaximize() {
        let cur = CGRect(x: 100, y: 100, width: 600, height: 400)
        #expect(WindowGeometry.frame(for: .leftHalf, visible: screen, current: cur) == CGRect(x: 0, y: 25, width: 720, height: 875))
        #expect(WindowGeometry.frame(for: .rightHalf, visible: screen, current: cur) == CGRect(x: 720, y: 25, width: 720, height: 875))
        #expect(WindowGeometry.frame(for: .maximize, visible: screen, current: cur) == screen)
        let bottom = WindowGeometry.frame(for: .bottomHalf, visible: screen, current: cur)
        #expect(bottom.maxY == screen.maxY)
    }

    @Test func centerKeepsSizeUnlessTooBig() {
        let small = WindowGeometry.frame(for: .center, visible: screen, current: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(small.size == CGSize(width: 400, height: 300))
        #expect(abs(small.midX - screen.midX) <= 1)
        let big = WindowGeometry.frame(for: .center, visible: screen, current: CGRect(x: 0, y: 0, width: 3000, height: 2000))
        #expect(big.width < screen.width && big.height < screen.height)
    }

    @Test func moveKeepsRelativePosition() {
        let external = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let left = CGRect(x: 0, y: 25, width: 720, height: 875)
        let moved = WindowGeometry.move(left, from: screen, to: external)
        #expect(moved.minX == 1440)
        #expect(moved.width == 1280)
        #expect(external.contains(moved))
    }

    @Test func flip() {
        let r = WindowGeometry.flip(CGRect(x: 0, y: 0, width: 100, height: 50), primaryHeight: 900)
        #expect(r == CGRect(x: 0, y: 850, width: 100, height: 50))
    }
}

@Suite struct URLCleanerTests {
    @Test func removesTrackingParams() {
        #expect(URLCleaner.clean("https://example.com/a?utm_source=x&id=3&fbclid=abc") == "https://example.com/a?id=3")
        #expect(URLCleaner.clean("https://shop.example.com/?gclid=1") == "https://shop.example.com/")
        #expect(URLCleaner.clean("https://youtu.be/abc?si=XYZ") == "https://youtu.be/abc")
        #expect(URLCleaner.clean("https://www.youtube.com/watch?v=abc&si=1") == "https://www.youtube.com/watch?v=abc")
    }

    @Test func leavesOthersAlone() {
        #expect(URLCleaner.clean("https://example.com/search?q=맥&page=2") == nil)
        #expect(URLCleaner.clean("https://example.com/?si=1") == nil) // si는 유튜브·스포티파이에서만 추적용
        #expect(URLCleaner.clean("그냥 글자 utm_source=1") == nil)
        #expect(URLCleaner.clean("ftp://example.com/?utm_source=1") == nil)
    }
}

@Suite struct FormatTests {
    @Test func formats() {
        #expect(Format.bytes(512) == "512B")
        #expect(Format.bytes(1_500_000) == "1.5MB")
        #expect(Format.bytes(250_000_000_000) == "250GB")
        #expect(Format.percent(0.426) == "43%")
        #expect(Format.duration(minutes: 45) == "45분")
        #expect(Format.duration(minutes: 135) == "2시간 15분")
        #expect(Format.hex(red: 1, green: 0.5, blue: 0) == "#FF8000")
    }
}

@Suite struct MemoryFormatTests {
    @Test func usesBinaryUnitsLikeActivityMonitor() {
        #expect(Format.memory(48 * 1024 * 1024 * 1024) == "48GB")
        #expect(Format.memory(UInt64(33.5 * 1024 * 1024 * 1024)) == "33.5GB")
        #expect(Format.memory(512 * 1024 * 1024) == "512MB")
        #expect(Format.bytes(48 * 1024 * 1024 * 1024) == "51.5GB") // 디스크식(1000) 단위와 다름
    }
}
