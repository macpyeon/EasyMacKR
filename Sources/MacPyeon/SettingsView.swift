import MacPyeonCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: FeatureStore
    @ObservedObject var navigation: SettingsNavigation

    enum Page: Hashable {
        case general, dashboard, displays, clipboard, ports
        case category(FeatureCategory)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.page) {
                Label("일반", systemImage: "sparkles").tag(Page.general)
                Section("상태·도구") {
                    Label("시스템 상태", systemImage: "gauge.with.dots.needle.33percent").tag(Page.dashboard)
                    Label("디스플레이", systemImage: "display.2").tag(Page.displays)
                    Label("클립보드 기록", systemImage: "doc.on.clipboard").tag(Page.clipboard)
                    Label("포트 관리", systemImage: "network").tag(Page.ports)
                }
                Section("기능") {
                    ForEach(FeatureCategory.allCases, id: \.self) { category in
                        Label(category.title, systemImage: category.symbol)
                            .badge(enabledCount(category))
                            .tag(Page.category(category))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch navigation.page {
            case .dashboard:
                DashboardPage()
            case .displays:
                DisplaysPage()
            case .clipboard:
                ClipboardPage(store: store)
            case .ports:
                PortsPage()
            case .general, .category:
                Form {
                    if store.tapStatus == .needsPermission || store.tapStatus == .needsRestart {
                        PermissionBanner(store: store)
                    }
                    if !store.conflicts.isEmpty {
                        ConflictBanner(store: store)
                    }
                    if case .category(let category) = navigation.page {
                        CategoryPage(store: store, category: category)
                    } else {
                        GeneralPage(store: store)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    private func enabledCount(_ category: FeatureCategory) -> Int {
        FeatureCatalog.features(in: category).filter { store.isOn($0.id) }.count
    }
}

private struct PermissionBanner: View {
    @ObservedObject var store: FeatureStore

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    if store.tapStatus == .needsRestart {
                        Text("권한은 허용됐는데 키보드 기능이 아직 안 켜졌어요").font(.headline)
                        Text("macOS가 앱을 다시 시작해야 적용하는 경우가 있어요. 그래도 안 되면 손쉬운 사용 목록에서 '맥편해'를 껐다가 다시 켜 주세요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("키보드·마우스 기능을 쓰려면 손쉬운 사용 권한이 필요해요").font(.headline)
                        Text("시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 '맥편해'를 켜 주세요. 켜면 자동으로 적용됩니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if store.tapStatus == .needsRestart {
                    Button("다시 시작") { AppController.relaunch() }
                } else {
                    Button("권한 열기") {
                        store.requestAccessibility()
                        AppController.openAccessibilitySettings()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct ConflictBanner: View {
    @ObservedObject var store: FeatureStore

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("다른 앱과 같은 기능이 동시에 켜져 있어요").font(.headline)
                    Text(store.conflicts.map { "· \(FeatureCatalog.info($0.feature).title) — \($0.appName)" }.joined(separator: "\n"))
                        .font(.callout)
                    Text("둘 다 켜면 스크롤이 두 번 뒤집혀 원래대로 돌아오거나 단축키가 두 번 실행돼요. 한쪽에서만 켜 주세요.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("맥편해 쪽 끄기") {
                    var next = store.enabled
                    store.conflicts.forEach { next.remove($0.feature) }
                    store.replace(with: next)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct GeneralPage: View {
    @ObservedObject var store: FeatureStore
    @State private var confirmReset = false

    var body: some View {
        if store.showWelcome {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("추천 설정을 적용했어요").font(.headline)
                        Text("왼쪽 메뉴에서 어떤 기능이 켜졌는지 볼 수 있어요. 필요 없는 기능을 끄면 원래 설정으로 돌아갑니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("닫기") { store.showWelcome = false }
                }
                .padding(.vertical, 4)
            }
        }

        Section("맥편해") {
            LabeledContent("켜진 기능", value: "\(store.enabled.count) / \(FeatureCatalog.all.count)개")
            Toggle("로그인할 때 자동으로 실행", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
            KeepAwakeRow()
        }

        Section {
            Picker("압축 파일 이름 방식", selection: $store.zipEncoding) {
                ForEach(ZipNameEncoding.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                Button("윈도우용으로 압축…") { FileActions.chooseAndZip(encoding: store.zipEncoding) }
                Button("한글 파일명 정리…") { FileActions.chooseAndNormalize() }
            }
        } header: {
            Text("파일 도구")
        } footer: {
            Text("Finder에서 파일을 오른쪽 클릭 > 빠른 동작(또는 서비스) 메뉴에서도 쓸 수 있어요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            HStack {
                Button("추천 설정 모두 켜기") { store.applyRecommended() }
                Spacer()
                Button("모두 끄고 원래대로", role: .destructive) { confirmReset = true }
            }
        } footer: {
            Text("끄면 맥편해가 바꾼 시스템 설정은 바꾸기 전 값으로 돌아갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("모든 기능을 끌까요?", isPresented: $confirmReset) {
            Button("모두 끄기", role: .destructive) { store.disableAll() }
        } message: {
            Text("바꾼 Finder·시스템 설정이 원래대로 돌아가고, 키보드 기능도 모두 꺼집니다.")
        }
    }
}

private struct CategoryPage: View {
    @ObservedObject var store: FeatureStore
    let category: FeatureCategory

    var body: some View {
        Section(category.title) {
            ForEach(FeatureCatalog.features(in: category)) { info in
                FeatureRow(store: store, info: info)
            }
        }
    }
}

private struct FeatureRow: View {
    @ObservedObject var store: FeatureStore
    let info: FeatureInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { store.isOn(info.id) }, set: { store.set(info.id, $0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(info.title)
                        if info.recommended { Tag(text: "추천", color: .accentColor) }
                        if info.needsAccessibility { Tag(text: "권한 필요", color: .orange) }
                        if let c = store.conflict(for: info.id) { Tag(text: "\(c.appName)에서도 켜짐", color: .red) }
                    }
                    Text(info.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = info.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)

            if info.id == .hangulKey && store.isOn(.hangulKey) {
                Picker("전환 키", selection: $store.hangulKey) {
                    ForEach(HangulKeyChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            if info.id == .taskManager && store.isOn(.taskManager) {
                Picker("열 프로그램", selection: $store.useOwnTaskManager) {
                    Text("맥편해 작업 관리자").tag(true)
                    Text("활동 모니터").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }
            if info.id == .linearScroll && store.isOn(.linearScroll) {
                Stepper("한 칸에 \(store.linesPerNotch)줄", value: $store.linesPerNotch, in: 1...10)
                    .frame(maxWidth: 220)
            }
            if info.id == .menuBarStats && store.isOn(.menuBarStats) {
                HStack {
                    ForEach(StatItem.allCases, id: \.self) { stat in
                        Toggle(stat.title, isOn: Binding(
                            get: { store.statItems.contains(stat) },
                            set: { _ in store.toggleStat(stat) }))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            if info.id == .nfcFilenames {
                Button("다른 폴더도 직접 정리…") { FileActions.chooseAndNormalize() }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}
