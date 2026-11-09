import AppKit
import CoreAudio
import MacPyeonCore
import SwiftUI

/// 메뉴 막대 아이콘을 누르면 뜨는 간단 설정 패널.
/// 시스템 말풍선(NSPopover)은 위치를 정할 수 없어 화면 위로 잘리므로, 직접 만든 창을 아이콘 바로 아래에 띄운다.
final class QuickPanel: NSObject {
    private var window: PanelWindow?
    private var monitors: [Any] = []
    private var closedAt = Date.distantPast
    private var topY: CGFloat = 0
    private var maxHeight: CGFloat = 600
    private let store: FeatureStore
    var onOpenSettings: ((SettingsView.Page?) -> Void)?

    init(store: FeatureStore) {
        self.store = store
        super.init()
    }

    var isShown: Bool { window?.isVisible == true }

    func toggle(from button: NSStatusBarButton) {
        if isShown { close(reason: "toggle"); return }
        // 바깥 클릭으로 막 닫힌 직후의 아이콘 클릭이면 다시 열지 않는다.
        guard Date().timeIntervalSince(closedAt) > 0.35 else { return }
        show(anchor: anchorPoint(for: button))
    }

    /// 아이콘 바로 아래 가운데. 아이콘 위치를 못 얻으면 방금 클릭한 마우스 위치를 쓴다.
    private func anchorPoint(for button: NSStatusBarButton) -> NSPoint {
        if let w = button.window {
            let frame = w.convertToScreen(button.convert(button.bounds, to: nil))
            if frame.width > 0, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                return NSPoint(x: frame.midX, y: frame.minY)
            }
        }
        return NSEvent.mouseLocation
    }

    private func show(anchor: NSPoint) {
        let view = QuickPanelView(store: store) { [weak self] page in
            self?.close(reason: "settings")
            self?.onOpenSettings?(page)
        } close: { [weak self] in
            self?.close(reason: "view")
        }
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        // 화면 높이에서 위·아래 여백을 뺀 만큼까지만. 넘치면 패널 안에서 스크롤된다.
        maxHeight = visible.height - 16
        // 내용의 실제 높이를 먼저 잰다.
        let natural = NSHostingView(rootView: view.frame(width: PanelContainer<EmptyView>.width)).fittingSize.height
        let height = min(natural, maxHeight)
        let width = PanelContainer<EmptyView>.width
        topY = visible.maxY - 6   // 메뉴 막대 바로 아래
        let host = NSHostingView(rootView: PanelContainer(initialHeight: natural, maxHeight: maxHeight,
                                                          onHeightChange: { [weak self] h in self?.resize(to: h) }) { view })

        var x = anchor.x - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let y = topY - height

        let w = window ?? PanelWindow()
        window = w
        w.contentView = host
        w.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        w.onEscape = { [weak self] in self?.close(reason: "escape") }
        SystemMonitor.shared.use("panel", true)
        Displays.shared.refresh()
        // 앱을 앞으로 가져오지 않고 패널만 띄운다(지금 쓰던 앱의 포커스를 빼앗지 않음).
        w.orderFrontRegardless()
        w.makeKey()
        DebugLog.write("panel show frame=\(w.frame) visible=\(w.isVisible) key=\(w.isKeyWindow)")

        // 패널 바깥을 누르면 닫는다.
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close(reason: "outside click")
        }
        if let outside { monitors.append(outside) }
    }

    /// 탭을 바꿔 내용 높이가 달라지면 위쪽을 고정한 채 창 높이를 맞춘다.
    private func resize(to contentHeight: CGFloat) {
        guard let w = window, w.isVisible else { return }
        let h = min(contentHeight, maxHeight)
        guard abs(w.frame.height - h) > 0.5 else { return }
        w.setFrame(NSRect(x: w.frame.minX, y: topY - h, width: w.frame.width, height: h), display: true)
    }

    func close(reason: String = "other") {
        DebugLog.write("panel close (\(reason)) visible=\(window?.isVisible ?? false)")
        guard let w = window, w.isVisible else { return }
        closedAt = Date()
        w.orderOut(nil)
        w.contentView = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        SystemMonitor.shared.use("panel", false)
    }
}

/// 테두리 없는 패널 창. 키 입력(Esc, 검색창)을 받을 수 있게 한다.
final class PanelWindow: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// 패널 바탕(불투명, 둥근 모서리)과 넘칠 때 스크롤.
private struct PanelContainer<Content: View>: View {
    static var width: CGFloat { 380 }
    let maxHeight: CGFloat
    let onHeightChange: (CGFloat) -> Void
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat

    init(initialHeight: CGFloat, maxHeight: CGFloat, onHeightChange: @escaping (CGFloat) -> Void,
         @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.onHeightChange = onHeightChange
        self.content = content()
        _contentHeight = State(initialValue: initialHeight)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > maxHeight) {
            content
                .frame(width: Self.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in
                    Color.clear.onChange(of: g.size.height) { h in
                        contentHeight = h
                        onHeightChange(h)
                    }
                })
        }
        .frame(width: Self.width, height: min(contentHeight, maxHeight))
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

enum PanelTab: String, CaseIterable, Identifiable {
    case dashboard, display, sound, battery, network, disk, calendar, awake, tools, toggles
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .awake: return "moon.zzz"
        case .display: return "display.2"
        case .sound: return "speaker.wave.2"
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .battery: return "battery.75percent"
        case .calendar: return "calendar"
        case .tools: return "wrench.and.screwdriver"
        case .toggles: return "switch.2"
        }
    }

    var title: String {
        switch self {
        case .awake: return "잠자기 방지"
        case .display: return "디스플레이"
        case .sound: return "사운드"
        case .dashboard: return "대시보드"
        case .network: return "네트워크"
        case .disk: return "디스크"
        case .battery: return "배터리"
        case .calendar: return "달력"
        case .tools: return "도구"
        case .toggles: return "빠른 설정"
        }
    }
}

struct QuickPanelView: View {
    @ObservedObject var store: FeatureStore
    let openSettings: (SettingsView.Page?) -> Void
    let close: () -> Void
    @AppStorage("panelTab") private var tabRaw = PanelTab.dashboard.rawValue

    private var tab: PanelTab { PanelTab(rawValue: tabRaw) ?? .dashboard }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UpdateCard()
            tabBar
            Text(tab.title).font(.headline).foregroundStyle(.secondary).padding(.leading, 2)
            Group {
                switch tab {
                case .awake: AwakeTab()
                case .display: DisplayTab()
                case .sound: SoundTab()
                case .dashboard: DashboardTab(close: close, openTaskManager: { close(); store.openTaskManager() })
                case .network: NetworkTab()
                case .disk: DiskTab()
                case .battery: BatteryTab()
                case .calendar: CalendarTab()
                case .tools: ToolsTab(store: store, close: close)
                case .toggles: TogglesTab(store: store)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.tapStatus == .needsPermission || store.tapStatus == .needsRestart {
                Card {
                    Label(store.tapStatus == .needsRestart ? "키보드 기능을 켜려면 앱을 다시 시작해야 해요" : "키보드·마우스 기능에 손쉬운 사용 권한이 필요해요",
                          systemImage: "hand.raised.fill").foregroundStyle(.orange).font(.callout)
                    Button(store.tapStatus == .needsRestart ? "다시 시작" : "권한 열기") {
                        if store.tapStatus == .needsRestart { AppController.relaunch() } else { AppController.openAccessibilitySettings() }
                    }
                }
            }
            if !store.conflicts.isEmpty {
                Card {
                    Label("\(store.conflicts[0].appName)와 같은 기능이 켜져 있어요", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                    Text(store.conflicts.map { FeatureCatalog.info($0.feature).title }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("맥편해 쪽 끄기") {
                        var next = store.enabled
                        store.conflicts.forEach { next.remove($0.feature) }
                        store.replace(with: next)
                    }
                }
            }

            HStack(spacing: 8) {
                PanelButton(title: "작업 관리자", symbol: "list.bullet.rectangle") { close(); store.openTaskManager() }
                PanelButton(title: "설정", symbol: "gearshape") { openSettings(nil) }
                PanelButton(title: "종료", symbol: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { t in
                Button {
                    tabRaw = t.rawValue
                } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 15))
                        .frame(width: 32, height: 30)
                        .foregroundStyle(t == tab ? Color.accentColor : .primary)
                        .background(t == tab ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
        }
        .padding(4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
    }
}

// MARK: - 업데이트 알림

/// 새 버전이 있거나 방금 업데이트됐을 때만 패널 맨 위에 나온다.
private struct UpdateCard: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let release = updater.available {
            Card {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("새 버전 \(release.version.withSubject) 나왔어요").font(.callout.weight(.semibold))
                        Text("지금 \(updater.currentText)").font(.caption).foregroundStyle(.secondary)
                        ForEach(release.summaryLines(limit: 3), id: \.self) {
                            Text("· " + $0).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let step = updater.installStep {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(step).font(.caption)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button(updater.canInstallInApp ? "업데이트" : "받으러 가기") { updater.install() }
                            .buttonStyle(.borderedProminent)
                        Button("바뀐 점") { updater.openReleasePage(release.version) }
                        Spacer()
                        Button("이번 버전 건너뛰기") { updater.skip() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = updater.installError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if updater.canInstallInApp {
                    Text("누르면 알아서 받아 설치하고 다시 켜요. 끝난 뒤 손쉬운 사용 권한 창이 뜨면 맥편해를 켜 주세요.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let version = updater.justUpdated {
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.title3).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(version.withDirection) 업데이트됐어요").font(.callout.weight(.semibold))
                        Button("바뀐 점 보기") { updater.openReleasePage(version) }
                            .buttonStyle(.link).font(.caption)
                    }
                    Spacer()
                    Button { updater.dismissJustUpdated() } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("닫기")
                }
            }
        }
    }
}

// MARK: - 공용 조각

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct PanelButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// 글자는 왼쪽, 스위치는 오른쪽 끝.
private struct SwitchRow<Label: View>: View {
    let isOn: Binding<Bool>
    @ViewBuilder let label: Label
    var body: some View {
        HStack {
            label
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

// MARK: - 탭들

/// 잠자기 방지: 시간을 고르고 '켜기'를 누른다. 켜져 있으면 남은 시간이 줄어드는 막대로 보인다.
private struct AwakeTab: View {
    @ObservedObject private var keep = KeepAwake.shared
    @State private var now = Date()
    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private let durations: [(String, Int)] = [("30분", 30), ("1시간", 60), ("2시간", 120), ("4시간", 240), ("계속", 0)]

    /// 고른 시간은 KeepAwake가 기억한다. 켜져 있을 때 바꾸면 그 시간으로 바로 다시 적용.
    private var selection: Binding<Int> {
        Binding(get: { keep.choice }, set: { value in
            guard value != keep.choice else { return }
            if keep.isOn { keep.start(minutes: value) } else { keep.choose(value) }
        })
    }

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: keep.isOn ? "sun.max.fill" : "moon.zzz")
                    .font(.system(size: 26))
                    .foregroundStyle(keep.isOn ? Color.orange : .secondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(keep.isOn ? "화면이 꺼지지 않게 붙잡는 중" : "꺼짐 — 평소 절전 설정대로")
                        .font(.callout.weight(.semibold))
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if keep.isOn, let until = keep.until, let startedAt = keep.startedAt {
                ProgressView(value: max(0, until.timeIntervalSince(now)), total: max(until.timeIntervalSince(startedAt), 1))
                    .tint(.orange)
            }
            Picker("시간", selection: selection) {
                ForEach(durations, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                if keep.isOn {
                    Button("끄기") { keep.stop() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("켜기") { keep.start(minutes: keep.choice) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear { now = Date() }
        .onReceive(timer) { now = $0 }
    }

    private var statusDetail: String {
        guard keep.isOn else { return "시간을 고르고 켜기를 누르세요" }
        guard let until = keep.until else { return "직접 끌 때까지 유지" }
        let left = max(0, Int(until.timeIntervalSince(now) / 60))
        return "\(Format.duration(minutes: max(left, 1))) 남음 · \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short))에 자동으로 꺼짐"
    }
}

private struct DisplayTab: View {
    @ObservedObject private var displays = Displays.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(displays.list) { d in
                Card {
                    HStack {
                        Text(d.name + (d.isBuiltin ? " (내장)" : "")).font(.callout.weight(.semibold))
                        Spacer()
                        Text("\(d.resolutionText) · \(Int(d.refreshRate.rounded()))Hz").font(.caption).foregroundStyle(.secondary)
                    }
                    BrightnessRow(display: d)
                }
            }
            HStack(spacing: 8) {
                PanelButton(title: "화면 끄기", symbol: "moon.fill") { QuickTools.sleepDisplays() }
                PanelButton(title: "디스플레이 설정", symbol: "gearshape") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                }
            }
        }
    }
}

private struct SoundTab: View {
    @State private var volume = AudioDevices.outputVolume() ?? 0.5
    @State private var muted = AudioDevices.isOutputMuted()
    @State private var micMuted = AudioDevices.isMicMuted()
    @State private var devices = AudioDevices.all()
    @State private var output = AudioDevices.defaultDevice(input: false)
    @State private var input = AudioDevices.defaultDevice(input: true)

    var body: some View {
        VStack(spacing: 8) {
            Card {
                HStack(spacing: 8) {
                    Button {
                        muted.toggle()
                        AudioDevices.setOutputMuted(muted)
                    } label: {
                        Image(systemName: muted || volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 20)
                    }
                    .buttonStyle(.plain)
                    Slider(value: Binding(get: { volume }, set: { volume = $0; muted = false; AudioDevices.setOutputVolume($0) }), in: 0...1)
                    Text(Format.percent(volume)).monospacedDigit().font(.caption).frame(width: 36, alignment: .trailing)
                }
                Picker("출력", selection: Binding(get: { output }, set: { output = $0; AudioDevices.setDefault($0, input: false); volume = AudioDevices.outputVolume() ?? volume })) {
                    ForEach(devices.filter(\.hasOutput)) { Text($0.name).tag($0.id) }
                }
            }
            Card {
                Picker("입력", selection: Binding(get: { input }, set: { input = $0; AudioDevices.setDefault($0, input: true) })) {
                    ForEach(devices.filter(\.hasInput)) { Text($0.name).tag($0.id) }
                }
                SwitchRow(isOn: Binding(get: { micMuted }, set: { _ in micMuted = AudioDevices.toggleMicMute() })) {
                    Text("마이크 음소거")
                }
            }
        }
    }
}

private struct DashboardTab: View {
    @ObservedObject private var m = SystemMonitor.shared
    let close: () -> Void
    let openTaskManager: () -> Void

    private var memoryFraction: Double { Double(m.memoryUsed) / Double(max(m.memoryTotal, 1)) }

    var body: some View {
        VStack(spacing: 8) {
            // 사용률 게이지
            Card {
                HStack(spacing: 0) {
                    RingGauge(title: "CPU", value: m.cpu, detail: "\(ProcessInfo.processInfo.activeProcessorCount)코어", color: .blue)
                    RingGauge(title: "메모리", value: memoryFraction,
                              detail: "\(Format.memory(m.memoryUsed)) / \(Format.memory(m.memoryTotal))", color: .purple)
                    RingGauge(title: "GPU", value: m.gpu ?? 0, detail: m.gpu == nil ? "알 수 없음" : "칩 내장", color: .pink)
                }
            }
            // 온도
            Card {
                HStack(spacing: 6) {
                    TempTile(title: "칩 평균", value: m.temperatures.chipAverage)
                    TempTile(title: "칩 최고", value: m.temperatures.chipMax)
                    TempTile(title: "SSD", value: m.temperatures.ssd)
                    TempTile(title: "배터리", value: m.temperatures.battery ?? m.battery?.temperature)
                }
                HStack {
                    Text("발열 상태").foregroundStyle(.secondary)
                    Spacer()
                    Text(m.thermal.title).foregroundStyle(m.thermal == .nominal ? Color.green : m.thermal == .fair ? .orange : .red)
                }
                .font(.callout)
            }
            // 추이
            Card {
                HStack {
                    Text("CPU").font(.caption.weight(.semibold)).frame(width: 44, alignment: .leading)
                    Sparkline(values: m.cpuHistory, color: .blue).frame(height: 24)
                }
                HStack {
                    Text("메모리").font(.caption.weight(.semibold)).frame(width: 44, alignment: .leading)
                    Sparkline(values: m.memoryHistory, color: .purple).frame(height: 24)
                }
                HStack {
                    Text("칩 온도").font(.caption.weight(.semibold)).frame(width: 44, alignment: .leading)
                    Sparkline(values: m.temperatureHistory, color: .orange).frame(height: 24)
                }
            }
            // 요약
            Card {
                Stat(title: "부하 (1·5·15분)", value: m.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " · "))
                Stat(title: "네트워크", value: "↓\(Format.rate(m.netIn))  ↑\(Format.rate(m.netOut))")
                Stat(title: "디스크", value: "\(Format.bytes(m.diskFree)) 남음")
                if let b = m.battery {
                    Stat(title: "배터리", value: Format.percent(b.percent) + (b.isCharging ? " · 충전 중" : b.onAC ? " · 전원 연결" : ""))
                }
            }
            // 많이 쓰는 앱
            Card {
                HStack {
                    Text("CPU 많이 쓰는 앱").font(.callout.weight(.semibold))
                    Spacer()
                    Button("작업 관리자", action: openTaskManager).font(.caption)
                }
                if m.topProcesses.isEmpty { Text("불러오는 중…").font(.caption).foregroundStyle(.secondary) }
                ForEach(m.topProcesses.prefix(5)) { p in
                    Stat(title: p.name, value: String(format: "%.1f%%", p.cpu))
                }
            }
        }
        .onAppear { SystemMonitor.shared.use("dashboard", true) }
        .onDisappear { SystemMonitor.shared.use("dashboard", false) }
    }
}

/// 원형 게이지: 가운데 퍼센트, 아래 이름과 설명.
private struct RingGauge: View {
    let title: String
    let value: Double
    let detail: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(value, 0), 1)))
                    .stroke(value > 0.85 ? Color.red : color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text(Format.percent(value)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            }
            .frame(width: 70, height: 70)
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 온도 칸. 60°C 넘으면 주황, 85°C 넘으면 빨강.
private struct TempTile: View {
    let title: String
    let value: Double?

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "thermometer.medium").foregroundStyle(color)
            Text(value.map { String(format: "%.0f°C", $0) } ?? "–").font(.callout.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        guard let v = value else { return .secondary }
        return v >= 85 ? .red : v >= 60 ? .orange : .green
    }
}

private struct NetworkTab: View {
    @ObservedObject private var m = SystemMonitor.shared

    var body: some View {
        Card {
            HStack {
                Label(Format.rate(m.netIn), systemImage: "arrow.down").foregroundStyle(.green)
                Spacer()
                Label(Format.rate(m.netOut), systemImage: "arrow.up").foregroundStyle(.orange)
            }
            .monospacedDigit()
            Sparkline(values: normalized(m.netInHistory), color: .green).frame(height: 30)
            Sparkline(values: normalized(m.netOutHistory), color: .orange).frame(height: 30)
            Stat(title: "이번 세션 받음", value: Format.bytes(m.netSessionIn))
            Stat(title: "이번 세션 보냄", value: Format.bytes(m.netSessionOut))
            HStack {
                Stat(title: "내부 IP", value: m.localIP ?? "연결 안 됨")
                if let ip = m.localIP {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
                        HUD.show("IP 복사함", symbol: "doc.on.doc")
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .help("복사")
                }
            }
        }
    }

    private func normalized(_ values: [Double]) -> [Double] {
        let peak = max(values.max() ?? 0, 1)
        return values.map { $0 / peak }
    }
}

private struct DiskTab: View {
    @ObservedObject private var m = SystemMonitor.shared
    @State private var volumes = QuickTools.ejectableVolumes()

    var body: some View {
        VStack(spacing: 8) {
            Card {
                let used = m.diskTotal > m.diskFree ? Double(m.diskTotal - m.diskFree) / Double(max(m.diskTotal, 1)) : 0
                HStack {
                    Text("Macintosh HD").font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(Format.bytes(m.diskFree)) 남음").monospacedDigit()
                }
                ProgressView(value: used).tint(used > 0.9 ? .red : .accentColor)
                Text("전체 \(Format.bytes(m.diskTotal)) 중 \(Format.percent(used)) 사용").font(.caption).foregroundStyle(.secondary)
            }
            Card {
                Text("외장 디스크").font(.callout.weight(.semibold))
                if volumes.isEmpty { Text("연결된 외장 디스크가 없어요").font(.caption).foregroundStyle(.secondary) }
                ForEach(volumes, id: \.self) { url in
                    HStack {
                        Image(systemName: "externaldrive")
                        Text(url.lastPathComponent)
                        Spacer()
                        Button("꺼내기") {
                            try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
                            volumes = QuickTools.ejectableVolumes()
                        }
                    }
                }
                if volumes.count > 1 {
                    Button("모두 꺼내기") { QuickTools.ejectAll(); volumes = [] }
                }
            }
        }
    }
}

private struct BatteryTab: View {
    @ObservedObject private var m = SystemMonitor.shared

    var body: some View {
        VStack(spacing: 10) {
            Card {
                if let b = m.battery {
                    HStack {
                        Image(systemName: b.isCharging ? "battery.100.bolt" : "battery.75percent")
                        Text(Format.percent(b.percent)).font(.title2.weight(.semibold)).monospacedDigit()
                        Spacer()
                        Text(b.isCharging ? "충전 중" : b.onAC ? "전원 연결됨" : "배터리 사용 중").foregroundStyle(.secondary)
                    }
                    ProgressView(value: b.percent).tint(b.percent < 0.2 ? .red : .green)
                    if let min = b.minutesRemaining { Stat(title: b.isCharging ? "완충까지" : "남은 시간", value: Format.duration(minutes: min)) }
                    if let health = b.health { Stat(title: "배터리 성능(최대 용량)", value: Format.percent(health)) }
                    if let cycles = b.cycleCount { Stat(title: "충전 횟수", value: "\(cycles)회") }
                    if let t = b.temperature { Stat(title: "온도", value: String(format: "%.1f°C", t)) }
                    if let w = b.watts, abs(w) > 0.05 { Stat(title: w > 0 ? "충전 전력" : "소비 전력", value: String(format: "%.1fW", abs(w))) }
                    if let a = b.adapterWatts { Stat(title: "전원 어댑터", value: "\(a)W") }
                } else {
                    Text("배터리가 없는 Mac이에요").foregroundStyle(.secondary)
                }
            }
            BluetoothBatteryCard()
        }
    }
}

private struct BluetoothBatteryCard: View {
    @ObservedObject private var bt = BluetoothBatteryMonitor.shared

    var body: some View {
        Card {
            HStack {
                Text("블루투스 기기").font(.callout.weight(.semibold))
                Spacer()
                if bt.loading { ProgressView().controlSize(.small) }
            }
            if bt.devices.isEmpty && !bt.loading {
                Text("연결된 블루투스 기기가 없어요").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(bt.devices) { d in
                HStack(spacing: 8) {
                    Image(systemName: d.symbol).frame(width: 20).foregroundStyle(.secondary)
                    Text(d.name).lineLimit(1)
                    Spacer()
                    if d.left != nil || d.right != nil || d.caseLevel != nil {
                        HStack(spacing: 8) {
                            if let l = d.left { level("왼", l) }
                            if let r = d.right { level("오", r) }
                            if let c = d.caseLevel { level("케이스", c) }
                        }
                    } else if let m = d.main {
                        level(nil, m)
                    } else {
                        Text("—").foregroundStyle(.tertiary).help("이 기기는 배터리 정보를 알려 주지 않아요")
                    }
                }
                .font(.callout)
            }
            if !bt.bleEnabled && bt.devices.contains(where: { !$0.hasLevel }) {
                Button("다른 회사 키보드·마우스 배터리도 보기") { bt.enableBLE() }
                    .buttonStyle(.link).font(.caption)
                    .help("블루투스 권한을 물어봐요. 저전력 블루투스 배터리 정보를 주는 기기만 보여요.")
            }
            if let state = bt.bleState {
                Text(state).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { bt.use("panel", true) }
        .onDisappear { bt.use("panel", false) }
    }

    private func level(_ label: String?, _ value: Int) -> some View {
        HStack(spacing: 3) {
            if let label { Text(label).font(.caption2).foregroundStyle(.secondary) }
            Text("\(value)%").monospacedDigit().foregroundStyle(value <= 15 ? .red : .primary)
        }
    }
}

private struct CalendarTab: View {
    @State private var shown = CalendarTab.startOfMonth(
        ProcessInfo.processInfo.environment["MACPYEON_RENDER_MONTH"].flatMap { ISO8601DateFormatter().date(from: $0 + "-01T12:00:00Z") } ?? Date())
    private let cal = KoreanCalendarView.calendar

    static func startOfMonth(_ date: Date) -> Date {
        let c = KoreanCalendarView.calendar
        return c.date(from: c.dateComponents([.year, .month], from: date))!
    }

    var body: some View {
        VStack(spacing: 10) {
            Card {
                KoreanCalendarView(month: $shown)
            }
            let comps = cal.dateComponents([.year, .month], from: shown)
            let list = KoreanCalendar.holidays(year: comps.year!, month: comps.month!)
            Card {
                if list.isEmpty {
                    Text("이번 달은 공휴일이 없어요").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(list, id: \.self) { h in
                        HStack {
                            Text("\(h.month)월 \(h.day)일 (\(KoreanCalendarView.weekdayName(h)))").monospacedDigit()
                            Spacer()
                            Text(h.name).foregroundStyle(.red)
                        }
                        .font(.callout)
                    }
                }
                Text("선거일·임시공휴일은 정부 발표 뒤에만 알 수 있어 빠져 있어요.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct KoreanCalendarView: View {
    @Binding var month: Date
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "ko_KR")
        c.firstWeekday = 1
        return c
    }
    private var cal: Calendar { Self.calendar }

    static func weekdayName(_ h: KoreanCalendar.Holiday) -> String {
        let c = calendar
        guard let d = c.date(from: DateComponents(year: h.year, month: h.month, day: h.day)) else { return "" }
        return ["일", "월", "화", "수", "목", "금", "토"][c.component(.weekday, from: d) - 1]
    }

    var body: some View {
        let comps = cal.dateComponents([.year, .month], from: month)
        let year = comps.year!, m = comps.month!
        let days = cal.range(of: .day, in: .month, for: month)!.count
        let lead = cal.component(.weekday, from: month) - 1
        let today = cal.dateComponents([.year, .month, .day], from: now)
        let todayLunar = KoreanCalendar.lunarDate(year: today.year!, month: today.month!, day: today.day!)

        VStack(spacing: 8) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                VStack(spacing: 1) {
                    Text("\(String(year))년 \(m)월").font(.headline)
                    if let l = todayLunar {
                        Text("오늘 음력 \(l.text)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .onTapGesture { month = CalendarTab.startOfMonth(now) }
                .help("눌러서 이번 달로")
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                // 머리글·빈칸·날짜의 식별자가 겹치면 SwiftUI가 칸을 빼먹으므로 문자열로 나눈다.
                ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.element) { i, w in
                    Text(w).font(.caption2.weight(.semibold))
                        .foregroundStyle(i == 0 ? .red : i == 6 ? .blue : .secondary)
                }
                ForEach((0..<lead).map { "blank\($0)" }, id: \.self) { _ in Color.clear.frame(height: 34) }
                ForEach(Array(1...days), id: \.self) { day in
                    dayCell(year: year, month: m, day: day, weekday: (lead + day - 1) % 7,
                            isToday: today.year == year && today.month == m && today.day == day)
                }
            }
        }
        .onReceive(timer) { now = $0 }
    }

    private func dayCell(year: Int, month: Int, day: Int, weekday: Int, isToday: Bool) -> some View {
        let holidays = KoreanCalendar.holiday(year: year, month: month, day: day)
        let lunar = KoreanCalendar.lunarDate(year: year, month: month, day: day)
        let red = weekday == 0 || !holidays.isEmpty
        // 음력은 1일·15일과 공휴일만 작게 적는다(나머지는 너무 빽빽해짐).
        let lunarText: String? = {
            guard let lunar else { return nil }
            if lunar.day == 1 { return "\(lunar.isLeap ? "윤" : "")\(lunar.month).1" }
            if lunar.day == 15 { return "\(lunar.month).15" }
            return nil
        }()
        return VStack(spacing: 0) {
            Text("\(day)")
                .font(.callout.weight(isToday ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(isToday ? Color.white : red ? Color.red : weekday == 6 ? Color.blue : Color.primary)
                .frame(width: 26, height: 22)
                .background(isToday ? Color.accentColor : .clear, in: Circle())
            Text(holidays.first.map { $0.substitute ? "대체" : String($0.name.prefix(3)) } ?? lunarText ?? " ")
                .font(.system(size: 8))
                .foregroundStyle(holidays.isEmpty ? Color.secondary : Color.red)
                .lineLimit(1)
        }
        .frame(height: 34)
        .help(holidays.map(\.name).joined(separator: ", ") + (lunar.map { (holidays.isEmpty ? "" : " · ") + "음력 \($0.text)" } ?? ""))
    }

    private func shift(_ months: Int) {
        if let d = cal.date(byAdding: .month, value: months, to: month) { month = d }
    }
}

private struct ToolsTab: View {
    @ObservedObject var store: FeatureStore
    let close: () -> Void

    private var tools: [(String, String, () -> Void)] {
        [
            ("화면 글자 복사", "text.viewfinder", { QuickTools.copyTextFromScreen() }),
            ("색상 추출", "eyedropper", { QuickTools.pickColor() }),
            ("클립보드 기록", "doc.on.clipboard", { ClipboardPanel.shared.show() }),
            ("새 텍스트 문서", "doc.badge.plus", { FileActions.createNewTextFile() }),
            ("한글 파일명 정리", "character.textbox", { FileActions.chooseAndNormalize() }),
            ("윈도우용 압축", "doc.zipper", { FileActions.chooseAndZip(encoding: store.zipEncoding) }),
            ("zip 풀기 (한글)", "archivebox", { FileActions.chooseAndUnzip() }),
            ("화면 잠금", "lock", { QuickTools.lockScreen() }),
            ("청소 모드", "sparkles", { CleaningMode.shared.start() }),
            ("휴지통 비우기", "trash", { QuickTools.emptyTrash() }),
            ("다른 앱 모두 종료", "xmark.circle", { QuickTools.quitApps(exceptFrontmost: true) }),
            ("활동 모니터", "waveform.path.ecg", { KeyRouter.openActivityMonitor() }),
            ("포트 관리", "network", { SettingsOpener.open?(.ports) }),
        ]
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(tools, id: \.0) { title, symbol, action in
                Button {
                    close()
                    // 패널이 닫힌 뒤에 실행해야 화면 캡처·창이 패널에 가리지 않는다.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: action)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 18))
                        Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct TogglesTab: View {
    @ObservedObject var store: FeatureStore
    @State private var dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    @State private var iconsHidden = QuickTools.desktopIconsHidden

    private let quick: [FeatureID] = [
        .hangulKey, .mouseScrollReverse, .mouseScrollReverseHorizontal, .windowSnap,
        .clipboardHistory, .quitProtection, .finderCutPaste, .showHiddenFiles, .menuBarStats,
    ]

    var body: some View {
        VStack(spacing: 8) {
            Card {
                SwitchRow(isOn: Binding(get: { dark }, set: { dark = $0; QuickTools.toggleDarkMode() })) { Text("다크 모드") }
                SwitchRow(isOn: Binding(get: { iconsHidden }, set: {
                    iconsHidden = $0
                    QuickTools.setDesktopIconsHidden($0)
                })) { Text("바탕화면 아이콘 숨기기") }
            }
            Card {
                ForEach(quick, id: \.self) { id in
                    SwitchRow(isOn: Binding(get: { store.isOn(id) }, set: { store.set(id, $0) })) {
                        HStack(spacing: 4) {
                            Text(FeatureCatalog.info(id).title).lineLimit(1)
                            if let c = store.conflict(for: id) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                                    .help("\(c.appName)에서도 켜져 있어요")
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 간단 패널에서 설정 창 특정 페이지를 열 때 쓴다.
enum SettingsOpener {
    static var open: ((SettingsView.Page) -> Void)?
}

/// 간단 패널을 화면에 띄우지 않고 이미지로 그린다.
enum PanelRenderer {
    static func render(to directory: String) {
        let store = FeatureStore()
        SystemMonitor.shared.use("render", true)
        Displays.shared.refresh()
        if let assumed = ProcessInfo.processInfo.environment["MACPYEON_RENDER_ASSUME_VERSION"] {
            Updater.shared.previewCheck(assuming: assumed)
            let icon = AppDelegate.menuBarImage(filled: false, badge: true, lines: ["CPU 12%", "RAM 67%"])
            if let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory + "/menubar-badge.png"))
            }
        }
        // 측정값과 DDC 확인이 채워질 때까지 잠깐 돌린다.
        RunLoop.main.run(until: Date().addingTimeInterval(4.5))
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for tab in PanelTab.allCases {
            UserDefaults.standard.set(tab.rawValue, forKey: "panelTab")
            let view = QuickPanelView(store: store, openSettings: { _ in }, close: {})
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(tab.rawValue).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("✓ \(url.path)")
        }
    }
}
