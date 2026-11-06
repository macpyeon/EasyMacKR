import AppKit
import Combine
import CoreAudio
import MacPyeonCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let navigation = SettingsNavigation()
    private var cancellables = Set<AnyCancellable>()
    private var panel: QuickPanel!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onOpenDashboard = { [weak self] in self?.openSettings(page: .dashboard) }
        controller.start()

        NSApp.servicesProvider = controller.services
        NSUpdateDynamicServices()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "MacPyeonMain"
        menu.delegate = self
        // 왼쪽 클릭: 간단 패널, 오른쪽 클릭(또는 Ctrl+클릭): 메뉴
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        controller.readout.onRefresh = { [weak self] in self?.updateIcon() }
        panel = QuickPanel(store: controller.store)
        panel.onOpenSettings = { [weak self] page in self?.openSettings(page: page) }
        SettingsOpener.open = { [weak self] page in self?.openSettings(page: page) }
        updateIcon()
        KeepAwake.shared.$isOn.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }.store(in: &cancellables)

        if controller.store.showWelcome { openSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    /// Finder에서 앱을 다시 열면 설정 창을 보여 준다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRight {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil   // 다음 왼쪽 클릭은 다시 패널로
        } else {
            panel.toggle(from: sender)
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        button.image = Self.menuBarImage(filled: KeepAwake.shared.isOn, lines: controller.readout.lines)
        button.imagePosition = .imageOnly
        statusItem.button?.toolTip = KeepAwake.shared.isOn ? "맥편해 · 잠자기 방지 켜짐" : "맥편해"
    }

    /// 아이콘 + (켜져 있으면) 두 줄로 쌓은 작은 수치.
    static func menuBarImage(filled: Bool, lines: [String]) -> NSImage {
        let icon = menuBarIcon(filled: filled)
        guard !lines.isEmpty else { return icon }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        // 두 줄씩 한 칸
        let columns = stride(from: 0, to: lines.count, by: 2).map { Array(lines[$0..<min($0 + 2, lines.count)]) }
        let widths = columns.map { col in col.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 0 }
        let gap: CGFloat = 4
        let width = 18 + gap + widths.reduce(0, +) + gap * CGFloat(max(columns.count - 1, 0))
        let image = NSImage(size: NSSize(width: ceil(width), height: 18), flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            var x: CGFloat = 18 + gap
            for (col, w) in zip(columns, widths) {
                for (i, line) in col.enumerated() {
                    let y: CGFloat = col.count == 1 ? 4.5 : (i == 0 ? 9 : 0)
                    (line as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                }
                x += w + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 메뉴 막대 아이콘: 키캡 안의 '편'. 잠자기 방지가 켜지면 키캡을 채운다.
    static func menuBarIcon(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let cap = NSBezierPath(roundedRect: rect.insetBy(dx: 1.2, dy: 1.2), xRadius: 4.2, yRadius: 4.2)
            let text = NSAttributedString(string: "편", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: NSColor.black,
            ])
            let size = text.size()
            let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 0.3)
            if filled {
                NSColor.black.setFill()
                cap.fill()
                // 글자 부분을 뚫어서 보이게 한다.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                text.draw(at: origin)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                NSColor.black.setStroke()
                cap.lineWidth = 1.3
                cap.stroke()
                text.draw(at: origin)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "맥편해"
        return image
    }

    // MARK: 메뉴

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { SystemMonitor.shared.use("menu", true) }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { SystemMonitor.shared.use("menu", false) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        let store = controller.store

        menu.addItem(disabled("맥편해"))
        if store.needsAccessibility && !store.accessibilityGranted {
            menu.addItem(item("⚠️ 손쉬운 사용 권한 허용하기…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        menu.addItem(item("작업 관리자", #selector(openTaskManager), symbol: "list.bullet.rectangle"))
        menu.addItem(submenu("시스템 상태", symbol: "gauge.with.dots.needle.33percent", statusMenu()))
        menu.addItem(submenu("디스플레이", symbol: "display.2", displayMenu()))
        menu.addItem(submenu("사운드", symbol: "speaker.wave.2", soundMenu()))
        menu.addItem(submenu(KeepAwake.shared.isOn ? "잠자기 방지 (켜짐)" : "잠자기 방지", symbol: "cup.and.saucer", keepAwakeMenu()))
        menu.addItem(.separator())

        menu.addItem(submenu("빠른 도구", symbol: "wand.and.stars", toolsMenu()))
        menu.addItem(submenu("파일", symbol: "folder", filesMenu()))
        if store.isOn(.clipboardHistory) {
            menu.addItem(item("클립보드 기록 열기", #selector(openClipboard), symbol: "doc.on.clipboard"))
        }
        menu.addItem(.separator())
        menu.addItem(item("설정…", #selector(openSettingsAction), key: ","))
        menu.addItem(item("맥편해 종료", #selector(quit), key: "q"))
    }

    private func statusMenu() -> NSMenu {
        let m = NSMenu()
        let s = SystemMonitor.shared
        m.addItem(disabled("CPU \(Format.percent(s.cpu))" + (s.gpu.map { "  ·  GPU \(Format.percent($0))" } ?? "")))
        m.addItem(disabled("메모리 \(Format.memory(s.memoryUsed)) / \(Format.memory(s.memoryTotal))"))
        if let b = s.battery {
            var text = "배터리 \(Format.percent(b.percent))"
            if b.isCharging { text += " 충전 중" } else if b.onAC { text += " 전원 연결됨" }
            if let min = b.minutesRemaining { text += " · \(Format.duration(minutes: min)) " + (b.isCharging ? "후 완충" : "남음") }
            m.addItem(disabled(text))
            if let health = b.health, let cycles = b.cycleCount {
                m.addItem(disabled("배터리 성능 \(Format.percent(health)) · 충전 횟수 \(cycles)회"))
            }
        }
        m.addItem(disabled("디스크 \(Format.bytes(s.diskFree)) 남음"))
        m.addItem(disabled("네트워크 ↓\(Format.rate(s.netIn)) ↑\(Format.rate(s.netOut))"))
        if let ip = s.localIP { m.addItem(disabled("내부 IP \(ip)")) }
        m.addItem(disabled("발열 상태 \(s.thermal.title)"))
        m.addItem(.separator())
        m.addItem(item("자세히 보기…", #selector(openDashboard)))
        m.addItem(item("작업 관리자 열기", #selector(openTaskManager)))
        m.addItem(item("활동 모니터 열기", #selector(openActivityMonitor)))
        return m
    }

    private func displayMenu() -> NSMenu {
        let m = NSMenu()
        let displays = Displays.shared
        displays.refresh()
        for d in displays.list {
            m.addItem(disabled("\(d.name)\(d.isBuiltin ? " (내장)" : "")"))
            m.addItem(disabled("   \(d.resolutionText) · \(Int(d.refreshRate.rounded()))Hz · \(d.looksLikeText)"))
        }
        m.addItem(.separator())
        m.addItem(item("밝기 조절…", #selector(openDisplays)))
        m.addItem(item("화면 끄기", #selector(sleepDisplays)))
        return m
    }

    private func soundMenu() -> NSMenu {
        let m = NSMenu()
        let devices = AudioDevices.all()
        let output = AudioDevices.defaultDevice(input: false), input = AudioDevices.defaultDevice(input: true)
        m.addItem(disabled("출력"))
        for d in devices where d.hasOutput {
            let i = item(d.name, #selector(selectOutput(_:)))
            i.representedObject = d.id
            i.state = d.id == output ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        m.addItem(disabled("입력"))
        for d in devices where d.hasInput {
            let i = item(d.name, #selector(selectInput(_:)))
            i.representedObject = d.id
            i.state = d.id == input ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        let mute = item("마이크 음소거", #selector(toggleMic))
        mute.state = AudioDevices.isMicMuted() ? .on : .off
        m.addItem(mute)
        return m
    }

    private func keepAwakeMenu() -> NSMenu {
        let m = NSMenu()
        let k = KeepAwake.shared
        if k.isOn {
            let until = k.until.map { "\(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short))까지" } ?? "끌 때까지"
            m.addItem(disabled("켜짐 · \(until)"))
            m.addItem(item("끄기", #selector(stopKeepAwake)))
            m.addItem(.separator())
        }
        for (title, minutes) in [("끌 때까지", 0), ("30분", 30), ("1시간", 60), ("2시간", 120), ("4시간", 240), ("8시간", 480)] {
            let i = item(title, #selector(startKeepAwake(_:)))
            i.tag = minutes
            m.addItem(i)
        }
        return m
    }

    private func toolsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("화면 글자 복사 (OCR)", #selector(ocr), symbol: "text.viewfinder"))
        m.addItem(item("화면 색상 추출", #selector(pickColor), symbol: "eyedropper"))
        m.addItem(.separator())
        m.addItem(item("다크 모드 전환", #selector(darkMode), symbol: "circle.lefthalf.filled"))
        let icons = item("바탕화면 아이콘 숨기기", #selector(toggleDesktopIcons), symbol: "menubar.dock.rectangle")
        icons.state = QuickTools.desktopIconsHidden ? .on : .off
        m.addItem(icons)
        m.addItem(item("화면 잠금", #selector(lockScreen), symbol: "lock"))
        m.addItem(item("청소 모드 (키보드 잠금)", #selector(cleaning), symbol: "sparkles"))
        m.addItem(.separator())
        m.addItem(item("디스크 모두 꺼내기", #selector(ejectAll), symbol: "eject"))
        m.addItem(item("휴지통 비우기…", #selector(emptyTrash), symbol: "trash"))
        m.addItem(.separator())
        m.addItem(item("지금 앱 빼고 모두 종료", #selector(quitOthers), symbol: "xmark.circle"))
        m.addItem(item("앱 모두 종료", #selector(quitAll), symbol: "xmark.octagon"))
        m.addItem(item("포트 관리…", #selector(openPorts), symbol: "network"))
        return m
    }

    private func filesMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("현재 Finder 폴더에 새 텍스트 문서", #selector(newTextFile)))
        m.addItem(item("한글 파일명 정리(자소 합치기)…", #selector(normalizeNames)))
        m.addItem(item("윈도우용으로 압축…", #selector(zipForWindows)))
        return m
    }

    // MARK: 메뉴 도우미

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, symbol: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        i.submenu = sub
        return i
    }

    // MARK: 동작

    @objc private func openAccessibility() {
        controller.requestAccessibility(prompt: true)
        AppController.openAccessibilitySettings()
    }

    @objc private func openDashboard() { openSettings(page: .dashboard) }
    @objc private func openDisplays() { openSettings(page: .displays) }
    @objc private func openPorts() { openSettings(page: .ports) }
    @objc private func sleepDisplays() { QuickTools.sleepDisplays() }
    @objc private func selectOutput(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? AudioDeviceID { AudioDevices.setDefault(id, input: false) }
    }
    @objc private func selectInput(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? AudioDeviceID { AudioDevices.setDefault(id, input: true) }
    }
    @objc private func toggleMic() { QuickTools.toggleMicMute() }
    @objc private func startKeepAwake(_ sender: NSMenuItem) { KeepAwake.shared.start(minutes: sender.tag == 0 ? nil : sender.tag) }
    @objc private func stopKeepAwake() { KeepAwake.shared.stop() }
    @objc private func ocr() { QuickTools.copyTextFromScreen() }
    @objc private func pickColor() { QuickTools.pickColor() }
    @objc private func darkMode() { QuickTools.toggleDarkMode() }
    @objc private func toggleDesktopIcons() { QuickTools.setDesktopIconsHidden(!QuickTools.desktopIconsHidden) }
    @objc private func lockScreen() { QuickTools.lockScreen() }
    @objc private func cleaning() {
        if !controller.store.accessibilityGranted {
            FileActions.showError("청소 모드는 손쉬운 사용 권한이 필요해요.", detail: "권한이 없으면 키보드를 잠글 수 없어요.")
            return
        }
        CleaningMode.shared.start()
    }
    @objc private func ejectAll() { QuickTools.ejectAll() }
    @objc private func emptyTrash() { QuickTools.emptyTrash() }
    @objc private func quitOthers() { QuickTools.quitApps(exceptFrontmost: true) }
    @objc private func quitAll() { QuickTools.quitApps(exceptFrontmost: false) }
    @objc private func openClipboard() { ClipboardPanel.shared.show() }
    @objc private func newTextFile() { FileActions.createNewTextFile() }
    @objc private func openActivityMonitor() { KeyRouter.openActivityMonitor() }
    @objc private func openTaskManager() { TaskManagerWindow.show() }
    @objc private func normalizeNames() { FileActions.chooseAndNormalize() }
    @objc private func zipForWindows() { FileActions.chooseAndZip(encoding: controller.store.zipEncoding) }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 설정 창

    func openSettings(page: SettingsView.Page? = nil) {
        if let page { navigation.page = page }
        if settingsWindow == nil {
            let view = SettingsView(store: controller.store, navigation: navigation)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "맥편해 설정"
            window.contentView = NSHostingView(rootView: view)
            window.minSize = NSSize(width: 760, height: 500)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsView.Page = .general
}
