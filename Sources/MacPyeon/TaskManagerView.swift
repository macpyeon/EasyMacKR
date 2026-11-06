import AppKit
import MacPyeonCore
import SwiftUI

/// 윈도우 작업 관리자처럼 프로그램별 CPU·메모리·GPU 사용량을 보고 종료한다.
struct TaskManagerView: View {
    @ObservedObject private var monitor = ProcessMonitor.shared
    @ObservedObject private var system = SystemMonitor.shared
    @State private var query = ""
    @State private var scope: Scope = .apps
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpu, order: .reverse)]
    @State private var selection: ProcessRow.ID?
    @State private var confirmForce: ProcessRow?
    @State private var adminTarget: ProcessRow?

    enum Scope: String, CaseIterable {
        case apps = "앱"
        case mine = "내 프로세스"
        case all = "모든 프로세스"
    }

    private var visibleRows: [ProcessRow] {
        monitor.rows
            .filter { row in
                switch scope {
                case .apps: return row.isApp && row.app?.activationPolicy == .regular
                case .mine: return row.isMine
                case .all: return true
                }
            }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || "\($0.id)" == query }
            .sorted(using: sortOrder)
    }

    private var selectedRow: ProcessRow? { monitor.rows.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            HStack {
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Toggle("도우미 프로세스를 앱으로 묶기", isOn: $monitor.groupByApp)
                    .toggleStyle(.checkbox)
                Spacer()
                TextField("이름 또는 PID 검색", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            .padding(10)

            Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("이름", value: \.name) { row in
                    HStack(spacing: 6) {
                        if let icon = row.app?.icon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 16)
                        }
                        Text(row.name).lineLimit(1)
                        if row.helperCount > 0 {
                            Text("+\(row.helperCount)").font(.caption).foregroundStyle(.secondary)
                                .help("도우미 프로세스 \(row.helperCount)개 포함")
                        }
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("CPU", value: \.cpu) { row in
                    Text(String(format: "%.1f%%", row.cpu * 100)).monospacedDigit()
                        .foregroundStyle(heat(row.cpu / 1.0))
                }
                .width(70)
                TableColumn("메모리", value: \.memory) { row in
                    Text(Format.memory(row.memory)).monospacedDigit()
                        .foregroundStyle(heat(Double(row.memory) / Double(max(system.memoryTotal, 1)) * 8))
                }
                .width(80)
                TableColumn("GPU", value: \.gpu) { row in
                    Text(row.gpu > 0.0005 ? String(format: "%.1f%%", row.gpu * 100) : "–").monospacedDigit()
                        .foregroundStyle(heat(row.gpu * 2))
                }
                .width(60)
                TableColumn("PID", value: \.id) { row in
                    Text("\(row.id)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("사용자", value: \.user) { row in
                    Text(row.user).foregroundStyle(.secondary)
                }
                .width(70)
            }
            .contextMenu(forSelectionType: ProcessRow.ID.self) { ids in
                if let id = ids.first, let row = monitor.rows.first(where: { $0.id == id }) {
                    Button("종료") { end(row, force: false) }.disabled(row.isProtected)
                    Button("강제 종료") { confirmForce = row }.disabled(row.isProtected)
                    if let url = row.app?.bundleURL {
                        Divider()
                        Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }

            Divider()
            HStack {
                if let row = selectedRow {
                    Text(row.isProtected ? "\(row.name) — 시스템이 멈출 수 있어 종료를 막아 두었어요" : row.name)
                        .foregroundStyle(row.isProtected ? .orange : .primary)
                        .lineLimit(1)
                } else {
                    Text("프로그램을 선택하세요").foregroundStyle(.secondary)
                }
                Spacer()
                Button("종료") { if let row = selectedRow { end(row, force: false) } }
                    .disabled(selectedRow?.isProtected ?? true)
                Button("강제 종료") { confirmForce = selectedRow }
                    .disabled(selectedRow?.isProtected ?? true)
                    .keyboardShortcut(.delete, modifiers: [.command])
            }
            .padding(10)
        }
        .frame(minWidth: 720, minHeight: 460)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmForce != nil }, set: { if !$0 { confirmForce = nil } })) {
            Button("강제 종료", role: .destructive) {
                if let row = confirmForce { end(row, force: true) }
                confirmForce = nil
            }
        } message: {
            Text("저장하지 않은 작업은 사라집니다.")
        }
        .confirmationDialog("관리자 권한이 필요해요", isPresented: Binding(get: { adminTarget != nil }, set: { if !$0 { adminTarget = nil } })) {
            Button("관리자 암호로 강제 종료", role: .destructive) {
                if let row = adminTarget { monitor.terminateAsAdmin(row) }
                adminTarget = nil
            }
        } message: {
            Text("\(adminTarget?.name ?? "") 은(는) 시스템 계정으로 실행 중이에요. 관리자 암호를 입력하면 종료할 수 있어요.")
        }
    }

    private var confirmTitle: String { "\(confirmForce?.name ?? "")을(를) 강제 종료할까요?" }

    private var summary: some View {
        HStack(spacing: 24) {
            stat("CPU", Format.percent(system.cpu), system.cpuHistory, .blue)
            stat("메모리", "\(Format.memory(system.memoryUsed)) / \(Format.memory(system.memoryTotal))", system.memoryHistory, .purple)
            if let gpu = system.gpu { stat("GPU", Format.percent(gpu), nil, .pink) }
            VStack(alignment: .leading, spacing: 2) {
                Text("부하 (1·5·15분)").font(.caption).foregroundStyle(.secondary)
                Text(system.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " · ")).monospacedDigit()
            }
            Spacer()
        }
        .padding(12)
    }

    private func stat(_ title: String, _ value: String, _ history: [Double]?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value).monospacedDigit().font(.headline)
                if let history { Sparkline(values: history, color: color).frame(width: 80, height: 20) }
            }
        }
    }

    private func heat(_ level: Double) -> Color {
        level > 0.8 ? .red : level > 0.4 ? .orange : .primary
    }

    private func end(_ row: ProcessRow, force: Bool) {
        if monitor.terminate(row, force: force) == .needsAdmin { adminTarget = row }
    }
}

/// 작업 관리자 창.
enum TaskManagerWindow {
    private static var window: NSWindow?
    private static var measuring = false

    /// 창이 보일 때만 프로세스를 잰다.
    private static func setMeasuring(_ on: Bool) {
        guard on != measuring else { return }
        measuring = on
        ProcessMonitor.shared.use(on)
        SystemMonitor.shared.use("taskManager", on)
    }

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "작업 관리자"
            w.contentView = NSHostingView(rootView: TaskManagerView())
            w.isReleasedWhenClosed = false
            w.center()
            w.contentMinSize = NSSize(width: 720, height: 460)
            w.setFrameAutosaveName("MacPyeonTaskManager2")
            if w.frame.width < 720 || w.frame.height < 460 {
                w.setContentSize(NSSize(width: 860, height: 600))
                w.center()
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                setMeasuring(false)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: w, queue: .main) { _ in
                setMeasuring(false)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: w, queue: .main) { _ in
                setMeasuring(true)
            }
            window = w
        }
        setMeasuring(true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
