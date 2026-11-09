import AppKit
import ApplicationServices
import Carbon
import MacPyeonCore
import SwiftUI

/// 입력 언어가 바뀔 때 커서 옆에 '한' / 'A'를 잠깐 띄운다.
enum InputSourceIndicator {
    static var enabled = false
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    private static var lastShownKorean: Bool?
    /// 사라지는 애니메이션 도중 다시 띄웠으면 이전 애니메이션의 마무리가 새 표시를 끄지 않게.
    private static var generation = 0

    static func sourceChanged() {
        guard enabled else { return }
        let korean = InputSourceSwitcher.isKoreanActive()
        // 같은 언어 안에서 배열만 바뀐 경우(두벌식↔세벌식)는 띄우지 않는다.
        if lastShownKorean == korean, panel?.isVisible == true { return }
        lastShownKorean = korean
        show(korean: korean)
    }

    private static func show(korean: Bool) {
        let view = Text(korean ? "한" : "A")
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(korean ? Color(red: 0.16, green: 0.45, blue: 0.95) : Color(white: 0.25),
                        in: RoundedRectangle(cornerRadius: 9))
        let host = NSHostingView(rootView: view)
        let p = panel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 34, height: 34),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return p
        }()
        p.contentView = host
        let anchor = caretRect().map { NSPoint(x: $0.maxX + 6, y: $0.minY - 4) }
            ?? NSPoint(x: NSEvent.mouseLocation.x + 14, y: NSEvent.mouseLocation.y - 40)
        p.setFrameOrigin(clamp(NSPoint(x: anchor.x, y: anchor.y - 34)))
        generation += 1
        let mine = generation
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 },
                                                 completionHandler: {
                                                     guard mine == generation else { return }
                                                     p.orderOut(nil)
                                                     lastShownKorean = nil
                                                 })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private static func clamp(_ point: NSPoint) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -40, dy: -40).contains(point) }) ?? NSScreen.main else { return point }
        let f = screen.visibleFrame
        return NSPoint(x: min(max(point.x, f.minX + 4), f.maxX - 38), y: min(max(point.y, f.minY + 4), f.maxY - 38))
    }

    /// 글자 입력 위치(화면 좌표, 왼쪽 아래 원점). 앱이 알려 주지 않으면 nil.
    private static func caretRect() -> NSRect? {
        guard AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let el = element as! AXUIElement
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let rangeValue = range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &bounds) == .success,
              let b = bounds, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &rect), rect.height > 0, rect.height < 200 else { return nil }
        // 손쉬운 사용 좌표(왼쪽 위 원점) → 화면 좌표(왼쪽 아래 원점)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: max(rect.width, 1), height: rect.height)
    }
}

/// 앱마다 마지막으로 쓰던 입력 언어를 기억해, 그 앱으로 돌아가면 되돌려 준다.
enum PerAppInputSource {
    private static let key = "inputSourceByApp"
    private static var observer: NSObjectProtocol?
    /// 앱을 바꾼 직후 우리가 언어를 바꾸는 중이면 그 변경은 기록하지 않는다(엉뚱한 앱에 기록되지 않게).
    private static var switchingUntil = Date.distantPast

    static var isOn: Bool { observer != nil }

    static func set(_ on: Bool) {
        if on, observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                appActivated(app?.bundleIdentifier)
            }
        } else if !on, let o = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            observer = nil
        }
    }

    static func forgetAll() { UserDefaults.standard.removeObject(forKey: key) }

    static var rememberedCount: Int { (UserDefaults.standard.dictionary(forKey: key) ?? [:]).count }

    /// 입력 언어가 바뀌면 지금 앱에 기록한다.
    static func sourceChanged() {
        guard isOn, Date() > switchingUntil,
              let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return }
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map[id] = InputSourceSwitcher.isKoreanActive() ? "ko" : "en"
        UserDefaults.standard.set(map, forKey: key)
    }

    private static func appActivated(_ bundleID: String?) {
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier,
              let want = (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[bundleID] else { return }
        let korean = InputSourceSwitcher.isKoreanActive()
        guard (want == "ko") != korean else { return }
        switchingUntil = Date().addingTimeInterval(0.6)
        // 앱이 완전히 앞으로 온 뒤에 바꾼다(한글 전환은 단축키를 그 앱에 보내므로).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            if want == "ko" { InputSourceSwitcher.selectKorean() } else { InputSourceSwitcher.selectEnglish() }
        }
    }
}
