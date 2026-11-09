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
    let isHidden: Bool
    var thumbnail: NSImage?

    var label: String { title.isEmpty || title == appName ? appName : title }
}

/// ⌥Tab 창 전환. ⌥를 누르고 있는 동안 목록을 보여 주고, 떼면 고른 창으로 간다.
/// 키 입력은 이벤트 탭(KeyRouter)이 받아 여기로 넘긴다. 목록 창은 포커스를 가져가지 않는다.
final class WindowSwitcher: ObservableObject {
    static let shared = WindowSwitcher()

    @Published private(set) var windows: [SwitchableWindow] = []
    @Published private(set) var selected = 0
    private(set) var isActive = false
    private var panel: NSPanel?
    private var thumbnailTask: Task<Void, Never>?
    /// ⌥를 뗀 이벤트를 놓쳐도(탭이 잠깐 꺼짐 등) 목록이 남지 않게 주기적으로 확인한다.
    private var releaseWatch: Timer?

    // MARK: 열기·이동·닫기

    /// 창 목록을 모으는 동안 들어온 Tab·⌥ 떼기.
    private var pendingSteps = 0
    private var pendingCommit = false
    private var loadToken = 0

    func open(forward: Bool) {
        if isActive { step(forward ? 1 : -1); return }
        isActive = true
        windows = []
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
            self.close()
        }
    }

    private func loaded(_ list: [SwitchableWindow], forward: Bool, token: Int) {
        guard isActive, token == loadToken else { return }
        guard !list.isEmpty else { close(); return }
        windows = list
        // 윈도우처럼 처음엔 '바로 전 창'을 고른다.
        let first = list.count > 1 ? (forward ? 1 : list.count - 1) : 0
        selected = ((first + pendingSteps) % list.count + list.count) % list.count
        pendingSteps = 0
        // ⌥Tab을 아주 빨리 눌렀다 뗐으면 목록을 띄우지 않고 바로 전환한다.
        if pendingCommit || !Self.optionHeld() {
            commit()
            return
        }
        show()
        loadThumbnails()
    }

    private func startReleaseWatch() {
        releaseWatch?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            if !Self.optionHeld() { self.commit() }
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
        close()
        if let target { Self.activate(target) }
    }

    func cancel() {
        guard isActive else { return }
        close()
    }

    func cancelIfClickOutside() {
        guard isActive, let panel, panel.isVisible else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) { cancel() }
    }

    private func close() {
        isActive = false
        releaseWatch?.invalidate()
        releaseWatch = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        panel?.orderOut(nil)
        windows = []
    }

    private static func optionHeld() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).rawValue & RawFlag.option != 0
    }

    // MARK: 화면

    private func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let host = NSHostingView(rootView: SwitcherView(model: self, maxWidth: screen.visibleFrame.width - 80))
        let size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .popUpMenu
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.hidesOnDeactivate = false
            return p
        }()
        p.contentView = host
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.midY - size.height / 2,
                           width: size.width, height: size.height)
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
        panel = p
    }

    /// 화면 기록 권한이 있을 때만 미리보기를 만든다(없으면 아이콘만).
    private func loadThumbnails() {
        guard CGPreflightScreenCaptureAccess() else { return }
        guard #available(macOS 14.0, *) else { return }
        let ids = windows.filter { !$0.isMinimized && !$0.isHidden }.map(\.id)
        thumbnailTask = Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            for id in ids {
                if Task.isCancelled { return }
                guard let scWindow = content.windows.first(where: { $0.windowID == id }) else { continue }
                let config = SCStreamConfiguration()
                let scale = min(1, 360 / max(scWindow.frame.width, 1))
                config.width = Int(scWindow.frame.width * scale * 2)
                config.height = Int(scWindow.frame.height * scale * 2)
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

    static func activate(_ window: SwitchableWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        if app.isHidden { app.unhide() }
        if let element = window.element {
            if window.isMinimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        let appElement = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [])
        // 앱이 앞으로 온 뒤 다른 창이 위로 올라오는 경우가 있어 한 번 더 올린다.
        if let element = window.element {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
        }
    }
}

// MARK: - 목록 화면

private struct SwitcherView: View {
    @ObservedObject var model: WindowSwitcher
    let maxWidth: CGFloat

    private let tile = CGSize(width: 168, height: 132)
    private var columns: Int { max(1, min(model.windows.count, Int((maxWidth - 24) / (tile.width + 10)))) }

    var body: some View {
        let grid = Array(repeating: GridItem(.fixed(tile.width), spacing: 10), count: columns)
        VStack(spacing: 10) {
            LazyVGrid(columns: grid, spacing: 10) {
                ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                    WindowTile(window: window, isSelected: index == model.selected, size: tile)
                        .onHover { if $0 { model.select(index) } }
                        .onTapGesture { model.select(index); model.commit() }
                }
            }
            if model.windows.indices.contains(model.selected) {
                let w = model.windows[model.selected]
                Text(w.appName + (w.label == w.appName ? "" : " — " + w.label))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: CGFloat(columns) * (tile.width + 10))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
    }
}

private struct WindowTile: View {
    let window: SwitchableWindow
    let isSelected: Bool
    let size: CGSize

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumb = window.thumbnail {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(nsImage: window.icon).resizable().aspectRatio(contentMode: .fit).padding(14)
                    }
                }
                .frame(width: size.width - 16, height: size.height - 44)
                if window.thumbnail != nil {
                    Image(nsImage: window.icon).resizable().frame(width: 26, height: 26).offset(x: 4, y: 4)
                }
            }
            HStack(spacing: 4) {
                if window.isMinimized { Image(systemName: "arrow.down.right.and.arrow.up.left").font(.caption2) }
                Text(window.label).font(.caption).lineLimit(1)
            }
            .foregroundStyle(window.isMinimized || window.isHidden ? .secondary : .primary)
            .frame(width: size.width - 12)
        }
        .padding(6)
        .frame(width: size.width, height: size.height)
        .background(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}
