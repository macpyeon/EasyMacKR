import AppKit
import ApplicationServices
import MacPyeonCore

/// 지금 포커스된 창을 손쉬운 사용 API로 옮기고 크기를 바꾼다.
enum WindowManager {
    /// 배치하기 전 크기. '원래대로'(⌃⌥↓)에서 쓴다.
    private static var saved: [String: CGRect] = [:]

    static func apply(_ layout: WindowLayout) {
        guard let window = focusedWindow(), let current = frame(of: window) else {
            NSSound.beep()
            return
        }
        let key = windowKey(window)
        let screens = axScreens()
        guard let screenIndex = screenIndex(for: current, in: screens) else { return }
        let visible = screens[screenIndex]

        let target: CGRect
        switch layout {
        case .restore:
            guard let original = saved.removeValue(forKey: key) else { return }
            setFrame(window, original)
            return
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1 else { return }
            let step = layout == .nextDisplay ? 1 : screens.count - 1
            let dest = screens[(screenIndex + step) % screens.count]
            target = WindowGeometry.move(current, from: visible, to: dest)
        default:
            target = WindowGeometry.frame(for: layout, visible: visible, current: current)
        }
        if saved[key] == nil { saved[key] = current }
        setFrame(window, target)
    }

    // MARK: AX 도우미

    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
    }

    private static func windowKey(_ window: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        return "\(pid)|\((title as? String) ?? "")"
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        var size = rect.size, point = rect.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let pointValue = AXValueCreate(.cgPoint, &point) else { return }
        // 크기 → 위치 → 크기 순서: 화면 경계 때문에 크기가 잘리는 걸 막는다.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }

    /// 화면들의 사용 가능 영역을 AX 좌표(주 화면 왼쪽 위가 0)로.
    private static func axScreens() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { WindowGeometry.flip($0.visibleFrame, primaryHeight: primary.frame.height) }
    }

    private static func screenIndex(for frame: CGRect, in screens: [CGRect]) -> Int? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let i = screens.firstIndex(where: { $0.contains(center) }) { return i }
        // 창 가운데가 화면 밖이면 가장 많이 겹치는 화면
        let areas = screens.map { $0.intersection(frame).isNull ? 0 : $0.intersection(frame).width * $0.intersection(frame).height }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }) else { return nil }
        return best
    }
}
