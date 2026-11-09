import AppKit
import ApplicationServices
import MacPyeonCore
import ScreenCaptureKit
import SwiftUI

/// 창 하나. 같은 앱의 창도 따로 고를 수 있다.
struct SwitchableWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage
    let element: AXUIElement?
    let isMinimized: Bool
    var isHidden: Bool
    var thumbnail: NSImage?

    var label: String { title.isEmpty || title == appName ? appName : title }
}

/// ⌘Tab 창 전환(맥 기본 앱 전환기 대신). ⌘를 누르고 있는 동안 목록을 보여 주고, 떼면 고른 창으로 간다.
/// 키 입력은 이벤트 탭(KeyRouter)이 받아 여기로 넘긴다. 목록 창은 포커스를 가져가지 않는다.
final class WindowSwitcher: ObservableObject {
    static let shared = WindowSwitcher()

    @Published private(set) var windows: [SwitchableWindow] = []
    @Published private(set) var selected = 0
    private(set) var isActive = false
    private var panel: NSPanel?
    private var thumbnailTask: Task<Void, Never>?
    private var host: NSHostingView<SwitcherView>?
    private var openedAt = Date.distantPast
    private var showWork: DispatchWorkItem?
    /// 맥 기본 ⌘Tab처럼, 짧게 눌렀다 떼면 목록 없이 바로 전환한다. 이만큼 누르고 있어야 목록이 뜬다.
    private static let showDelay: TimeInterval = 0.12
    /// ⌘를 뗀 이벤트를 놓쳐도(탭이 잠깐 꺼짐 등) 목록이 남지 않게 주기적으로 확인한다.
    private var releaseWatch: Timer?

    // MARK: 열기·이동·닫기

    /// 창 목록을 모으는 동안 들어온 Tab·⌘ 떼기.
    private var pendingSteps = 0
    private var pendingCommit = false
    private var loadToken = 0
    /// ⌘를 뗀 뒤 전환을 기다리는 동안 친 키. 전환이 끝나면 새 창에 다시 보낸다(버려지지 않게).
    private var typedAhead: [CGEvent] = []
    private var typedDown = Set<Int64>()
    private var terminateObserver: NSObjectProtocol?

    func open(forward: Bool) {
        if isActive { step(forward ? 1 : -1); return }
        isActive = true
        openedAt = Date()
        windows = []
        typedAhead = []
        typedDown = []
        // 목록이 떠 있는 동안 앱이 끝나면(Q 포함) 그 앱 창을 뺀다.
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appTerminated(app.processIdentifier)
        }
        pendingSteps = 0
        pendingCommit = false
        loadToken += 1
        let token = loadToken
        startReleaseWatch()
        // 손쉬운 사용 호출은 느린 앱이 있으면 오래 걸려서, 키보드 처리(메인)를 막지 않게 백그라운드에서 모은다.
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .map { AppSnapshot(pid: $0.processIdentifier, name: $0.localizedName ?? "앱", icon: $0.icon ?? NSImage(), isHidden: $0.isHidden) }
        DispatchQueue.global(qos: .userInteractive).async {
            let list = Self.collectWindows(apps: apps)
            DispatchQueue.main.async { self.loaded(list, forward: forward, token: token) }
        }
        // 어떤 앱이 응답하지 않아 목록이 늦어지면 키 입력을 계속 붙잡지 않고 포기한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isActive, self.windows.isEmpty, token == self.loadToken else { return }
            self.cancel()
        }
    }

    private func loaded(_ list: [SwitchableWindow], forward: Bool, token: Int) {
        guard isActive, token == loadToken else { return }
        guard !list.isEmpty else { cancel(); return }
        windows = Array(list.prefix(150))
        // 처음엔 '바로 전 창'을 고른다.
        let first = list.count > 1 ? (forward ? 1 : list.count - 1) : 0
        selected = ((first + pendingSteps) % list.count + list.count) % list.count
        pendingSteps = 0
        // ⌘Tab을 아주 빨리 눌렀다 뗐으면 목록을 띄우지 않고 바로 전환한다.
        if pendingCommit || !Self.commandHeld() {
            commit()
            return
        }
        loadThumbnails()
        let wait = Self.showDelay - Date().timeIntervalSince(openedAt)
        if wait <= 0 { show(); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, token == self.loadToken else { return }
            self.show()
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func startReleaseWatch() {
        releaseWatch?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            if !Self.commandHeld() { self.commit() }
        }
        RunLoop.main.add(t, forMode: .common)
        releaseWatch = t
    }

    func step(_ delta: Int) {
        guard isActive else { return }
        guard !windows.isEmpty else { pendingSteps += delta; return }
        selected = (selected + delta + windows.count) % windows.count
    }

    func select(_ index: Int) {
        guard windows.indices.contains(index) else { return }
        selected = index
    }

    func commit() {
        guard isActive else { return }
        // 아직 목록을 모으는 중이면 다 모은 뒤에 전환한다.
        guard !windows.isEmpty else { pendingCommit = true; return }
        let target = windows.indices.contains(selected) ? windows[selected] : nil
        let typed = close()
        if let target {
            Self.activate(target) { Self.replay(typed) }
        } else {
            Self.replay(typed)
        }
    }

    /// ⌘를 이미 뗀 뒤 들어온 키(전환 대기 중). 삼키고 모아 뒀다가 전환 뒤에 보낸다.
    func typeAhead(_ event: CGEvent, isDown: Bool, keyCode: Int64) {
        guard isActive else { return }
        if isDown {
            typedDown.insert(keyCode)
        } else if !typedDown.contains(keyCode) {
            return   // ⌘Tab의 Tab 떼기 등, 누른 것을 모으지 않은 키는 버린다
        }
        if typedAhead.count < 64, let copy = event.copy() { typedAhead.append(copy) }
        if !pendingCommit { commit() }
    }

    private static func replay(_ events: [CGEvent]) {
        guard !events.isEmpty else { return }
        for e in events { e.post(tap: .cgSessionEventTap) }
    }

    func cancel() {
        guard isActive else { return }
        Self.replay(close())
    }

    /// 목록에서 고른 창의 앱을 끝낸다(맥 기본 ⌘Tab의 Q).
    func quitSelectedApp() {
        guard isActive, windows.indices.contains(selected) else { return }
        // 실제로 끝나면 목록에서 뺀다(저장 확인 창을 띄우거나 끝나지 않는 앱은 남는다).
        NSRunningApplication(processIdentifier: windows[selected].pid)?.terminate()
    }

    private func appTerminated(_ pid: pid_t) {
        guard isActive, windows.contains(where: { $0.pid == pid }) else { return }
        let current = windows.indices.contains(selected) ? windows[selected].id : nil
        windows.removeAll { $0.pid == pid }
        guard !windows.isEmpty else { cancel(); return }
        selected = current.flatMap { id in windows.firstIndex { $0.id == id } } ?? min(selected, windows.count - 1)
        // SwiftUI가 바뀐 목록을 반영한 뒤에 크기를 다시 잰다.
        DispatchQueue.main.async { [weak self] in self?.relayout() }
    }

    /// 목록에서 고른 창의 앱을 가린다(맥 기본 ⌘Tab의 H). 목록에는 흐리게 남는다.
    func hideSelectedApp() {
        guard isActive, windows.indices.contains(selected) else { return }
        let pid = windows[selected].pid
        NSRunningApplication(processIdentifier: pid)?.hide()
        for i in windows.indices where windows[i].pid == pid { windows[i].isHidden = true }
    }

    func cancelIfClickOutside() {
        guard isActive, let panel, panel.isVisible else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) { cancel() }
    }

    /// 닫고, 그동안 모아 둔 키를 돌려준다.
    @discardableResult
    private func close() -> [CGEvent] {
        isActive = false
        if let o = terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            terminateObserver = nil
        }
        releaseWatch?.invalidate()
        releaseWatch = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        showWork?.cancel()
        showWork = nil
        panel?.orderOut(nil)
        windows = []
        let typed = typedAhead
        typedAhead = []
        typedDown = []
        return typed
    }

    /// `--demo-switcher`(화면 확인용)에서는 ⌘를 누른 것으로 친다.
    static var demo = false
    var panelWindowNumber: Int? { panel?.windowNumber }

    private static func commandHeld() -> Bool {
        if demo { return true }
        return CGEventSource.flagsState(.combinedSessionState).rawValue & RawFlag.command != 0
    }

    // MARK: 화면

    private func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let h = NSHostingView(rootView: SwitcherView(model: self, maxWidth: screen.visibleFrame.width - 120,
                                                 maxHeight: screen.visibleFrame.height - 120))
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .popUpMenu
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.hidesOnDeactivate = false
            p.animationBehavior = .none
            return p
        }()
        // 뒤가 비치는 흐린 바탕(맥 기본 ⌘Tab과 같은 재질)
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.roundedMask(radius: SwitcherView.cornerRadius)
        h.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: blur.leadingAnchor), h.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            h.topAnchor.constraint(equalTo: blur.topAnchor), h.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        p.contentView = blur
        host = h
        panel = p
        relayout(on: screen)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.08; p.animator().alphaValue = 1 }
    }

    /// 목록 크기가 바뀌면(앱 종료 등) 창을 다시 맞추고 화면 가운데에 둔다.
    private func relayout(on screen: NSScreen? = nil) {
        guard let panel, let host else { return }
        let screen = screen ?? panel.screen ?? NSScreen.main
        guard let screen else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                           y: (screen.frame.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    /// 모서리가 둥근 늘어나는 마스크(흐린 바탕을 둥글게 자른다).
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// 화면 기록 권한이 있을 때만 미리보기를 만든다(없으면 아이콘만).
    private func loadThumbnails() {
        guard CGPreflightScreenCaptureAccess() else { return }
        guard #available(macOS 14.0, *) else { return }
        let ids = windows.filter { !$0.isMinimized && !$0.isHidden }.map(\.id)
        let maxWidth = SwitcherView.thumbSize.width * 2
        thumbnailTask = Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            for id in ids {
                if Task.isCancelled { return }
                guard let scWindow = content.windows.first(where: { $0.windowID == id }) else { continue }
                let config = SCStreamConfiguration()
                let scale = min(1, maxWidth / max(scWindow.frame.width, 1))
                config.width = Int(scWindow.frame.width * scale)
                config.height = Int(scWindow.frame.height * scale)
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { continue }
                let ns = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
                DispatchQueue.main.async {
                    let model = WindowSwitcher.shared
                    guard model.isActive, let i = model.windows.firstIndex(where: { $0.id == id }) else { return }
                    model.windows[i].thumbnail = ns
                }
            }
        }
    }

    // MARK: 창 모으기

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// 손쉬운 사용 요소 → 창 번호(비공개 함수, 없으면 위치로 짝짓는다).
    private static let axGetWindow: GetWindowFn? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindow else { return nil }
        var id: CGWindowID = 0
        return fn(element, &id) == .success && id != 0 ? id : nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    struct AppSnapshot {
        let pid: pid_t
        let name: String
        let icon: NSImage
        let isHidden: Bool
    }

    /// 화면에 보이는 창(앞에서부터) + 최소화·가려진 앱의 창. 백그라운드에서 부른다.
    static func collectWindows(apps: [AppSnapshot]) -> [SwitchableWindow] {
        let appByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        // 1) 앱마다 손쉬운 사용으로 창 목록(제목·최소화 여부)을 얻는다.
        struct AXWin { let element: AXUIElement; let title: String; let minimized: Bool; let frame: CGRect?; let id: CGWindowID? }
        var axByPID: [pid_t: [AXWin]] = [:]
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            guard let list: [AXUIElement] = attribute(appElement, kAXWindowsAttribute) else { continue }
            axByPID[app.pid] = list.prefix(40).compactMap { w in
                // 창 요소에도 제한 시간을 건다(기본은 수 초).
                AXUIElementSetMessagingTimeout(w, 0.25)
                let subrole: String? = attribute(w, kAXSubroleAttribute)
                // 일반 창과 대화상자만(툴팁·팝오버 제외)
                guard subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return nil }
                let minimized: Bool = attribute(w, kAXMinimizedAttribute) ?? false
                return AXWin(element: w, title: attribute(w, kAXTitleAttribute) ?? "", minimized: minimized,
                             frame: frame(of: w), id: windowID(of: w))
            }
        }

        var result: [SwitchableWindow] = []
        var usedAX = Set<String>()
        func key(_ pid: pid_t, _ i: Int) -> String { "\(pid)-\(i)" }

        // 2) 화면에 보이는 창을 앞에서부터.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, let app = appByPID[pid],
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            let bounds = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard bounds.width > 80, bounds.height > 60 else { continue }
            let axList = axByPID[pid] ?? []
            let match = axList.firstIndex { $0.id == id }
                ?? axList.firstIndex { a in a.id == nil && a.frame.map { abs($0.minX - bounds.minX) < 3 && abs($0.minY - bounds.minY) < 3 && abs($0.width - bounds.width) < 3 } == true }
            // 손쉬운 사용으로 안 잡히는 창(그림자·오버레이 등)은 뺀다.
            guard let index = match, !usedAX.contains(key(pid, index)) else { continue }
            usedAX.insert(key(pid, index))
            let ax = axList[index]
            result.append(SwitchableWindow(id: id, pid: pid, appName: app.name, title: ax.title,
                                           icon: app.icon, element: ax.element,
                                           isMinimized: false, isHidden: false, thumbnail: nil))
        }

        // 3) 최소화된 창, 가려진(⌘H) 앱의 창을 뒤에.
        for app in apps {
            for (i, ax) in (axByPID[app.pid] ?? []).enumerated() where !usedAX.contains(key(app.pid, i)) {
                guard ax.minimized || app.isHidden else { continue }
                result.append(SwitchableWindow(id: ax.id ?? CGWindowID(UInt32.max - UInt32(result.count)), pid: app.pid,
                                               appName: app.name, title: ax.title,
                                               icon: app.icon, element: ax.element,
                                               isMinimized: ax.minimized, isHidden: app.isHidden, thumbnail: nil))
            }
        }
        return result
    }

    // MARK: 전환

    private static let activationQueue = DispatchQueue(label: "macpyeon.switcher.activate", qos: .userInteractive)

    /// 손쉬운 사용 호출은 응답 없는 앱에서 오래 걸릴 수 있어(그동안 키보드 처리가 멈춘다) 백그라운드에서 한다.
    static func activate(_ window: SwitchableWindow, then done: @escaping () -> Void) {
        let pid = window.pid, element = window.element, minimized = window.isMinimized
        activationQueue.async {
            guard let app = NSRunningApplication(processIdentifier: pid) else { DispatchQueue.main.async(execute: done); return }
            if app.isHidden { app.unhide() }
            if let element {
                AXUIElementSetMessagingTimeout(element, 0.25)
                if minimized {
                    AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            app.activate(options: [])
            // 앱이 앞으로 온 뒤 다른 창이 위로 올라오는 경우가 있어 한 번 더 올린다.
            usleep(80_000)
            if let element { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
            DispatchQueue.main.async(execute: done)
        }
    }
}

// MARK: - 목록 화면

/// 맥 기본 ⌘Tab 모양: 흐린 둥근 판 위에 한 줄로(많으면 여러 줄) 늘어선 창, 고른 칸은 옅은 회색 판.
struct SwitcherView: View {
    @ObservedObject var model: WindowSwitcher
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    @Namespace private var selection

    static let cornerRadius: CGFloat = 22
    static let thumbSize = CGSize(width: 184, height: 116)
    static let tileSize = CGSize(width: 204, height: 172)
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 14

    /// 화면에 다 들어가도록 한 줄 개수와 칸 크기 비율을 정한다(창이 많으면 칸을 줄인다).
    private var layout: (perRow: Int, scale: CGFloat) {
        let n = max(model.windows.count, 1)
        var result = (perRow: 1, scale: CGFloat(1))
        for s in [1.0, 0.85, 0.72, 0.6, 0.5, 0.42] as [CGFloat] {
            let w = Self.tileSize.width * s, h = Self.tileSize.height * s
            let per = max(1, min(n, Int((maxWidth - Self.padding * 2 + Self.spacing) / (w + Self.spacing))))
            let rows = (n + per - 1) / per
            result = (per, s)
            if CGFloat(rows) * (h + Self.spacing) + Self.padding * 2 <= maxHeight { break }
        }
        return result
    }

    var body: some View {
        let (perRow, scale) = layout
        let indices = Array(model.windows.indices)
        let rows = stride(from: 0, to: indices.count, by: perRow).map { Array(indices[$0..<min($0 + perRow, indices.count)]) }
        VStack(spacing: Self.spacing) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: Self.spacing) {
                    ForEach(row, id: \.self) { index in
                        let window = model.windows[index]
                        WindowTile(window: window, isSelected: index == model.selected, selection: selection, scale: scale)
                            .id(window.id)
                            .onHover { if $0 { model.select(index) } }
                            .onTapGesture { model.select(index); model.commit() }
                    }
                }
            }
        }
        .padding(Self.padding)
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: model.selected)
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .fixedSize()
    }
}

private struct WindowTile: View {
    let window: SwitchableWindow
    let isSelected: Bool
    let selection: Namespace.ID
    let scale: CGFloat

    private var dimmed: Bool { window.isMinimized || window.isHidden }

    var body: some View {
        let thumb = CGSize(width: SwitcherView.thumbSize.width * scale, height: SwitcherView.thumbSize.height * scale)
        let tile = CGSize(width: SwitcherView.tileSize.width * scale, height: SwitcherView.tileSize.height * scale)
        VStack(spacing: 10 * scale) {
            ZStack(alignment: .bottom) {
                Group {
                    if let image = window.thumbnail {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    } else {
                        Image(nsImage: window.icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 84 * scale, height: 84 * scale)
                    }
                }
                .frame(width: thumb.width, height: thumb.height)
                .opacity(dimmed ? 0.55 : 1)
                // 미리보기가 있으면 앱 아이콘을 아래 가운데에 겹쳐 둔다(미션 컨트롤처럼).
                if window.thumbnail != nil {
                    Image(nsImage: window.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 40 * scale, height: 40 * scale)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(y: 14 * scale)
                }
            }
            .frame(width: thumb.width, height: thumb.height)

            HStack(spacing: 4) {
                if window.isMinimized {
                    Image(systemName: "minus.circle.fill").font(.system(size: 10))
                } else if window.isHidden {
                    Image(systemName: "eye.slash").font(.system(size: 10))
                }
                Text(window.label)
                    .font(.system(size: max(10, 12 * scale), weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.top, window.thumbnail != nil ? 8 * scale : 0)
            .frame(width: tile.width - 16 * scale)
        }
        .frame(width: tile.width, height: tile.height)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.13))
                    .matchedGeometryEffect(id: "selection", in: selection)
            }
        }
        .contentShape(Rectangle())
    }
}
