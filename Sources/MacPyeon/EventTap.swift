import AppKit
import ApplicationServices
import MacPyeonCore

/// 전역 키보드·마우스 이벤트 탭. 손쉬운 사용 권한이 있어야 만들어진다.
final class EventTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    init(handler: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) {
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }
    /// 만들어져 있고 시스템이 꺼 두지도 않았는지.
    var isHealthy: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// 시스템이 탭을 꺼 버렸는지(처리 지연, 보안 입력 등). 꺼져 있으면 다시 켜고 true.
    @discardableResult
    func reviveIfNeeded() -> Bool {
        guard let port = tap, !CGEvent.tapIsEnabled(tap: port) else { return false }
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .scrollWheel,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .otherMouseUp,
            KeyRouter.systemDefined,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func dispatch(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 처리가 늦어 시스템이 탭을 끈 경우 다시 켠다.
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return handler(type, event)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.dispatch(type: type, event: event)
}

/// 키 입력을 보낸다. 우리가 보낸 이벤트는 표시를 달아 탭에서 다시 가로채지 않는다.
enum KeySender {
    static let marker: Int64 = 0x4D50_594E // "MPYN"

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    static func post(key: UInt16, modifiers: Modifiers) {
        let source = CGEventSource(stateID: .privateState)
        let flags = CGEventFlags(rawValue: modifiers.rawFlags)
        for isDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cgSessionEventTap)
        }
    }
}

/// 지금 키보드 포커스가 글자 입력란인지 손쉬운 사용 API로 확인한다.
enum FocusInspector {
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// 맨 앞 앱의 포커스된 요소. 제한 시간은 그 앱 요소에만 건다(시스템 전체에 걸면 창 배치 등 다른 호출까지 짧아짐).
    private static func focusedElement() -> (AXUIElement?, AXError) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return (nil, .failure) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return (nil, err) }
        return ((element as! AXUIElement), .success)
    }

    /// 글자를 입력하는 중인지. 판별에 실패하면(앱이 응답 없음 등) 안전하게 '입력 중'으로 본다.
    static func isTextFocused() -> Bool {
        let (element, err) = focusedElement()
        guard let element else {
            // 포커스된 요소가 아예 없으면(바탕화면 등) 입력 중이 아니다. 시간 초과·오류면 가로채지 않는다.
            return !(err == .noValue || err == .attributeUnsupported)
        }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleName = role as? String else { return true }
        return textRoles.contains(roleName)
    }

    /// Finder에서 파일이 선택돼 있는지(목록·아이콘·분할 보기). 모르겠으면 false.
    static func finderHasSelection() -> Bool {
        let (element, _) = focusedElement()
        guard let element else { return false }
        for attribute in ["AXSelectedRows", "AXSelectedChildren"] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let items = value as? [AnyObject], !items.isEmpty {
                return true
            }
        }
        return false
    }
}

/// 탭에서 받은 이벤트를 규칙대로 처리한다.
final class KeyRouter {
    var rules = KeyRules(enabled: [])
    var tapDetector = ModifierTapDetector(choice: .rightCommand)
    var scroll = ScrollOptions()
    /// 청소 모드: 키보드 입력을 전부 막는다.
    var lockKeyboard = false

    /// 잘라내기 대기 상태. 잘라낸 직후 클립보드 변경 번호를 기억해, 그 사이 다른 걸 복사했으면 취소한다.
    private var cutPending = false
    private var cutChangeCountBefore = 0
    private var cutChangeCountAfter: Int?
    private var quitGuard = QuitGuard()

    var onNewTextFile: (() -> Void)?
    var onClipboardHistory: (() -> Void)?
    var onTaskManager: (() -> Void)?

    private var enabled: Set<FeatureID> { rules.enabled }

    /// NX_SYSDEFINED(미디어 키 등)
    static let systemDefined = CGEventType(rawValue: 14)!

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if KeySender.isOurs(event) { return pass }

        if lockKeyboard && (type == .keyDown || type == .keyUp || type == .flagsChanged || type == Self.systemDefined) {
            return nil
        }

        if type == Self.systemDefined {
            return mediaKey(event) ? nil : pass
        }

        // 창 전환 목록이 떠 있는 동안은 키를 목록 조작에 쓴다.
        if WindowSwitcher.shared.isActive {
            if let handled = switcherEvent(type: type, event: event) { return handled ? nil : pass }
        }

        switch type {
        case .keyDown:
            tapDetector.interrupt()
            return keyDown(event) ? nil : pass
        case .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            return rules.keyUp(keyCode: code) == .swallow ? nil : pass
        case .flagsChanged:
            if enabled.contains(.hangulKey) {
                let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                if tapDetector.flagsChanged(keyCode: code, rawFlags: event.flags.rawValue,
                                            time: ProcessInfo.processInfo.systemUptime) {
                    DispatchQueue.main.async { InputSourceSwitcher.toggle() }
                }
            }
            return pass
        case .scrollWheel:
            if scroll.isActive { transformScroll(event) }
            return pass
        case .otherMouseDown, .otherMouseUp:
            tapDetector.interrupt()
            guard enabled.contains(.mouseSideButtons) else { return pass }
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard let key = SideButtons.key(forButton: button, app: app) else { return pass }
            if type == .otherMouseDown { KeySender.post(key: key, modifiers: [.command]) }
            return nil
        case .leftMouseDown, .rightMouseDown:
            tapDetector.interrupt()
            return pass
        default:
            return pass
        }
    }

    /// 창 전환 중의 이벤트. nil이면 평소대로 처리, true면 삼킨다.
    /// 맥 기본 ⌘Tab과 같은 조작: ⌘를 떼면 이동, Tab·⇧Tab·화살표로 고르기, Esc 취소, Q 앱 종료, H 앱 가리기.
    private func switcherEvent(type: CGEventType, event: CGEvent) -> Bool? {
        let switcher = WindowSwitcher.shared
        switch type {
        case .flagsChanged:
            // ⌘를 떼면 고른 창으로 간다.
            if event.flags.rawValue & RawFlag.command == 0 {
                DispatchQueue.main.async { switcher.commit() }
            }
            return false
        case .keyDown:
            // ⌘를 이미 뗐는데 아직 전환 중이면(창 목록을 모으는 중) 친 키를 모아 뒀다가 전환 뒤에 보낸다.
            if event.flags.rawValue & RawFlag.command == 0 {
                switcher.typeAhead(event, isDown: true, keyCode: event.getIntegerValueField(.keyboardEventKeycode))
                return true
            }
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let shift = event.flags.rawValue & RawFlag.shift != 0
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            switch code {
            case KeyCode.tab:
                DispatchQueue.main.async { switcher.step(shift ? -1 : 1) }
            case KeyCode.grave:
                DispatchQueue.main.async { switcher.step(shift ? 1 : -1) }
            case KeyCode.leftArrow, KeyCode.upArrow:
                DispatchQueue.main.async { switcher.step(-1) }
            case KeyCode.rightArrow, KeyCode.downArrow:
                DispatchQueue.main.async { switcher.step(1) }
            case KeyCode.escape:
                DispatchQueue.main.async { switcher.cancel() }
            case KeyCode.returnKey, KeyCode.keypadEnter:
                DispatchQueue.main.async { switcher.commit() }
            case KeyCode.q where !repeated:
                DispatchQueue.main.async { switcher.quitSelectedApp() }
            case KeyCode.h where !repeated:
                DispatchQueue.main.async { switcher.hideSelectedApp() }
            default:
                break
            }
            return true
        case .keyUp:
            switcher.typeAhead(event, isDown: false, keyCode: event.getIntegerValueField(.keyboardEventKeycode))
            return true
        case .leftMouseDown, .rightMouseDown:
            // 목록 밖을 누르면 닫는다. 목록 안 클릭은 패널이 처리한다.
            DispatchQueue.main.async { switcher.cancelIfClickOutside() }
            return nil
        default:
            return nil
        }
    }

    /// true면 원래 입력을 삼킨다.
    private func keyDown(_ event: CGEvent) -> Bool {
        let input = KeyInput(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: Modifiers(rawFlags: event.flags.rawValue),
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        let action = rules.keyDown(input, isTextFocused: FocusInspector.isTextFocused)
        switch action {
        case .pass:
            return false
        case .swallow:
            return true
        case .openActivityMonitor:
            DispatchQueue.main.async { [weak self] in
                if let open = self?.onTaskManager { open() } else { Self.openActivityMonitor() }
            }
            return true
        case .post(let key, let modifiers):
            KeySender.post(key: key, modifiers: modifiers)
            return true
        case .finderCut:
            cutPending = true
            cutChangeCountBefore = NSPasteboard.general.changeCount
            cutChangeCountAfter = nil
            KeySender.post(key: KeyCode.c, modifiers: [.command])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.cutPending else { return }
                self.cutChangeCountAfter = NSPasteboard.general.changeCount
            }
            HUD.show("잘라내기 — 붙여넣을 곳에서 ⌘V", symbol: "scissors")
            return true
        case .finderPaste:
            defer { cutPending = false }
            if enabled.contains(.finderCutPaste), cutPending, isCutStillValid() {
                KeySender.post(key: KeyCode.v, modifiers: [.command, .option])
                return true
            }
            if enabled.contains(.finderPasteImage) { return QuickTools.pasteImageIntoFinder() }
            return false
        case .finderCopy:
            cutPending = false
            return false
        case .toggleInputSource:
            DispatchQueue.main.async { InputSourceSwitcher.toggle() }
            return true
        case .switchToEnglishThenPass:
            if InputSourceSwitcher.isKoreanActive() { InputSourceSwitcher.selectEnglish() }
            return false
        case .newTextFile:
            DispatchQueue.main.async { [weak self] in self?.onNewTextFile?() }
            return true
        case .window(let layout):
            DispatchQueue.main.async { WindowManager.apply(layout) }
            return true
        case .clipboardHistory:
            DispatchQueue.main.async { [weak self] in self?.onClipboardHistory?() }
            return true
        case .plainTextPaste:
            DispatchQueue.main.async { ClipboardHistory.shared.pastePlainText() }
            return true
        case .quitGuard:
            let app = input.frontmostBundleID ?? ""
            if quitGuard.press(app: app, time: ProcessInfo.processInfo.systemUptime) {
                KeySender.post(key: KeyCode.q, modifiers: [.command])
            } else {
                let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "앱"
                DispatchQueue.main.async { HUD.show("⌘Q를 한 번 더 누르면 \(name) 종료", symbol: "power") }
            }
            return true
        case .windowSwitcher(let forward):
            DispatchQueue.main.async { WindowSwitcher.shared.open(forward: forward) }
            return true
        case .finderCopyPath:
            // Finder 자체의 '경로 이름 복사'(⌥⌘C)를 부른다.
            KeySender.post(key: KeyCode.c, modifiers: [.command, .option])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if let path = NSPasteboard.general.string(forType: .string), path.hasPrefix("/") {
                    let lines = path.split(separator: "\n").count
                    HUD.show(lines > 1 ? "경로 \(lines)개를 복사했어요" : "경로를 복사했어요", symbol: "doc.on.doc")
                }
            }
            return true
        case .openTerminalHere:
            FileActions.openTerminalAtFinderLocation()
            return true
        case .tool(let tool):
            DispatchQueue.main.async {
                switch tool {
                case .copyTextFromScreen: QuickTools.copyTextFromScreen()
                case .pickColor: QuickTools.pickColor()
                case .toggleMicMute: QuickTools.toggleMicMute()
                }
            }
            return true
        }
    }

    /// 밝기·볼륨 같은 특수 키. true면 삼킨다.
    private func mediaKey(_ event: CGEvent) -> Bool {
        guard rules.enabled.contains(.finderF2Rename),
              let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let decoded = MediaKey.decode(data1: ns.data1)
        let action = rules.mediaKey(decoded.key, isDown: decoded.isDown, isRepeat: decoded.isRepeat,
                                    frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                    isTextFocused: { FocusInspector.isTextFocused() || !FocusInspector.finderHasSelection() })
        switch action {
        case .post(let key, let modifiers):
            KeySender.post(key: key, modifiers: modifiers)
            return true
        case .swallow:
            return true
        default:
            return false
        }
    }

    /// 맥편해가 클립보드를 다시 썼으면(자소 합치기) 잘라내기 대기를 그 번호로 이어 간다.
    func clipboardRewritten(from old: Int, to new: Int) {
        guard cutPending else { return }
        if cutChangeCountAfter == old { cutChangeCountAfter = new }
    }

    private func isCutStillValid() -> Bool {
        let now = NSPasteboard.general.changeCount
        if let after = cutChangeCountAfter { return now == after }
        return now > cutChangeCountBefore
    }

    private func transformScroll(_ event: CGEvent) {
        let gesture = ScrollTransform.isGesture(
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        func read(_ d: CGEventField, _ f: CGEventField, _ p: CGEventField) -> ScrollAxis {
            ScrollAxis(lines: event.getIntegerValueField(d), fixed: event.getDoubleValueField(f), points: event.getIntegerValueField(p))
        }
        func write(_ a: ScrollAxis, _ d: CGEventField, _ f: CGEventField, _ p: CGEventField) {
            event.setIntegerValueField(d, value: a.lines)
            event.setDoubleValueField(f, value: a.fixed)
            event.setIntegerValueField(p, value: a.points)
        }
        let v = read(.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
        let h = read(.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
        let out = ScrollTransform.apply(vertical: v, horizontal: h, isGesture: gesture, options: scroll)
        if out.vertical != v { write(out.vertical, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1) }
        if out.horizontal != h { write(out.horizontal, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2) }
    }

    static func openActivityMonitor() {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        ws.openApplication(at: url, configuration: config, completionHandler: nil)
    }
}
