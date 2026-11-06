import MacPyeonCore
import SwiftUI

// MARK: - 시스템 상태

struct DashboardPage: View {
    @ObservedObject private var m = SystemMonitor.shared

    var body: some View {
        Form {
            Section("처리") {
                MetricRow(title: "CPU", value: Format.percent(m.cpu), history: m.cpuHistory, color: .blue)
                if let gpu = m.gpu {
                    LabeledContent("GPU", value: Format.percent(gpu))
                }
                MetricRow(title: "메모리",
                          value: "\(Format.memory(m.memoryUsed)) / \(Format.memory(m.memoryTotal))",
                          history: m.memoryHistory, color: .purple)
                LabeledContent("메모리 압박", value: m.memoryPressure >= 4 ? "위험" : m.memoryPressure >= 2 ? "주의" : "정상")
                LabeledContent("발열 상태", value: m.thermal.title)
                LabeledContent("칩 온도 (평균 / 최고)", value: [m.temperatures.chipAverage, m.temperatures.chipMax]
                    .map { $0.map { String(format: "%.0f°C", $0) } ?? "–" }.joined(separator: " / "))
                if let ssd = m.temperatures.ssd { LabeledContent("SSD 온도", value: String(format: "%.0f°C", ssd)) }
                LabeledContent("부하 (1·5·15분 평균)",
                               value: m.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " · ")
                                   + " / 코어 \(ProcessInfo.processInfo.activeProcessorCount)개")
            }

            if let b = m.battery {
                Section("배터리") {
                    LabeledContent("잔량", value: Format.percent(b.percent) + (b.isCharging ? " · 충전 중" : b.onAC ? " · 전원 연결됨" : ""))
                    if let min = b.minutesRemaining {
                        LabeledContent(b.isCharging ? "완충까지" : "남은 시간", value: Format.duration(minutes: min))
                    }
                    if let health = b.health { LabeledContent("배터리 성능(최대 용량)", value: Format.percent(health)) }
                    if let cycles = b.cycleCount { LabeledContent("충전 횟수", value: "\(cycles)회") }
                    if let t = b.temperature { LabeledContent("온도", value: String(format: "%.1f°C", t)) }
                    if let w = b.watts, abs(w) > 0.05 {
                        LabeledContent(w > 0 ? "충전 전력" : "소비 전력", value: String(format: "%.1fW", abs(w)))
                    }
                    if let adapter = b.adapterWatts { LabeledContent("전원 어댑터", value: "\(adapter)W") }
                }
            }

            Section("저장 공간·네트워크") {
                LabeledContent("디스크", value: "\(Format.bytes(m.diskFree)) 남음 / \(Format.bytes(m.diskTotal))")
                MetricRow(title: "받기", value: Format.rate(m.netIn), history: normalized(m.netInHistory), color: .green)
                MetricRow(title: "보내기", value: Format.rate(m.netOut), history: normalized(m.netOutHistory), color: .orange)
                LabeledContent("이번 세션", value: "↓\(Format.bytes(m.netSessionIn))  ↑\(Format.bytes(m.netSessionOut))")
                LabeledContent("내부 IP", value: m.localIP ?? "연결 안 됨")
            }

            Section("CPU 많이 쓰는 앱") {
                if m.topProcesses.isEmpty {
                    Text("불러오는 중…").foregroundStyle(.secondary)
                }
                ForEach(m.topProcesses) { p in
                    HStack {
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", p.cpu)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("작업 관리자 열기") { TaskManagerWindow.show() }
                    Button("활동 모니터 열기") { KeyRouter.openActivityMonitor() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { SystemMonitor.shared.use("dashboard", true) }
        .onDisappear { SystemMonitor.shared.use("dashboard", false) }
    }

    private func normalized(_ values: [Double]) -> [Double] {
        let peak = max(values.max() ?? 0, 1)
        return values.map { $0 / peak }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    let history: [Double]
    let color: Color

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Sparkline(values: history, color: color).frame(width: 160, height: 26)
            Text(value).monospacedDigit().frame(minWidth: 120, alignment: .trailing)
        }
    }
}

/// 0...1 값을 작은 꺾은선으로 그린다.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let n = max(values.count - 1, 1)
            let points = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(n), y: geo.size.height * (1 - CGFloat(min(max(v, 0), 1))))
            }
            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                }
                .fill(color.opacity(0.15))
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, lineWidth: 1.5)
            }
        }
    }
}

// MARK: - 디스플레이

struct DisplaysPage: View {
    @ObservedObject private var displays = Displays.shared

    var body: some View {
        Form {
            ForEach(displays.list) { d in
                Section(d.name + (d.isBuiltin ? " (내장)" : "") + (d.isMain ? " · 주 화면" : "")) {
                    LabeledContent("해상도", value: d.resolutionText)
                    LabeledContent("보이는 크기", value: d.looksLikeText)
                    LabeledContent("주사율", value: d.refreshRate > 0 ? "\(Int(d.refreshRate.rounded()))Hz" : "알 수 없음")
                    BrightnessRow(display: d)
                }
            }
            Section {
                HStack {
                    Button("디스플레이 설정 열기") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                    }
                    Button("화면 끄기") { QuickTools.sleepDisplays() }
                }
            } footer: {
                Text("내장 화면은 macOS 밝기를, 외장 모니터는 케이블(DDC)로 모니터 자체 밝기를 바꿔요. DDC를 지원하지 않는 모니터는 화면을 반투명하게 덮어 어둡게 하고, 앱을 끄면 원래대로 돌아와요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { displays.refresh() }
    }
}

// MARK: - 클립보드

struct ClipboardPage: View {
    @ObservedObject var store: FeatureStore
    @ObservedObject private var history = ClipboardHistory.shared
    @State private var query = ""

    var body: some View {
        Form {
            if !store.isOn(.clipboardHistory) {
                Section {
                    HStack {
                        Text("클립보드 기록이 꺼져 있어요.")
                        Spacer()
                        Button("켜기") { store.set(.clipboardHistory, true) }
                    }
                }
            }
            Section {
                TextField("검색", text: $query)
                let items = history.items.filter { query.isEmpty || ($0.text?.localizedCaseInsensitiveContains(query) ?? false) }
                if items.isEmpty { Text("기록이 없어요").foregroundStyle(.secondary) }
                ForEach(items) { item in
                    HStack {
                        if let data = item.image, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(height: 40)
                        } else {
                            Text(item.preview).lineLimit(2)
                        }
                        Spacer()
                        Button { history.togglePin(item) } label: {
                            Image(systemName: item.pinned ? "pin.fill" : "pin")
                        }
                        .buttonStyle(.borderless)
                        .help(item.pinned ? "고정 해제" : "고정")
                        Button { history.remove(item) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("기록 (\(history.items.count)개)")
            } footer: {
                Text("⌃⌥V로 어디서든 목록을 열 수 있어요. 고정한 항목은 지워지지 않아요. 비밀번호 관리자가 복사한 내용은 저장하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("고정 안 한 항목 지우기") { history.clear(keepPinned: true) }
                    Button("모두 지우기", role: .destructive) { history.clear(keepPinned: false) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 포트

struct PortsPage: View {
    @State private var ports: [ListeningPort] = []
    @State private var loading = false

    var body: some View {
        Form {
            Section {
                if ports.isEmpty && !loading { Text("열려 있는 포트가 없어요").foregroundStyle(.secondary) }
                ForEach(ports) { port in
                    HStack {
                        Text(port.port).monospacedDigit().font(.body.weight(.semibold)).frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(port.process)
                            Text("PID \(port.pid) · \(port.address)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("종료") {
                            PortManager.stop(port.pid)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reload() }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("연결을 기다리는 포트")
                    Spacer()
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
            } footer: {
                Text("개발 서버가 포트를 붙잡고 안 놓아줄 때 여기서 끄세요. 내 계정으로 실행한 프로그램만 보입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func reload() {
        loading = true
        DispatchQueue.global().async {
            let list = PortManager.list()
            DispatchQueue.main.async {
                ports = list
                loading = false
            }
        }
    }
}

// MARK: - 잠자기 방지

struct KeepAwakeRow: View {
    @ObservedObject private var keep = KeepAwake.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("잠자기 방지")
                if keep.isOn {
                    Text(keep.until.map { "\(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short))까지 켜짐" } ?? "끌 때까지 켜짐")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu(keep.isOn ? "켜짐" : "꺼짐") {
                Button("끌 때까지") { keep.start(minutes: 0) }
                Button("30분") { keep.start(minutes: 30) }
                Button("1시간") { keep.start(minutes: 60) }
                Button("2시간") { keep.start(minutes: 120) }
                Button("4시간") { keep.start(minutes: 240) }
                if keep.isOn {
                    Divider()
                    Button("끄기") { keep.stop() }
                }
            }
            .fixedSize()
        }
    }
}

// MARK: - 밝기 슬라이더 (설정 화면·간단 패널 공용)

struct BrightnessRow: View {
    let display: DisplayInfo
    @ObservedObject private var displays = Displays.shared

    var body: some View {
        let method = displays.methods[display.id] ?? .checking
        let value = displays.brightness[display.id] ?? 1
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "sun.max")
                Text("밝기")
                Spacer()
                Text(Format.percent(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: Binding(get: { value }, set: { displays.setBrightness($0, for: display.id) }), in: 0...1)
                    .disabled(method == .checking)
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
            }
            Text(method.title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
