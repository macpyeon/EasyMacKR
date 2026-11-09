import Combine
import Foundation
import MacPyeonCore

/// 키보드·마우스 기능(이벤트 탭) 상태.
enum TapStatus: Equatable {
    case off, needsPermission, starting, running, needsRestart

    var title: String {
        switch self {
        case .off: return "꺼짐"
        case .needsPermission: return "손쉬운 사용 권한 필요"
        case .starting: return "켜는 중…"
        case .running: return "동작 중"
        case .needsRestart: return "앱을 다시 시작해야 해요"
        }
    }
}

/// 사용자가 켠 기능과 옵션. UserDefaults에 저장한다. 실제 적용은 AppController가 맡는다.
final class FeatureStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published private(set) var enabled: Set<FeatureID>
    @Published var hangulKey: HangulKeyChoice {
        didSet { defaults.set(hangulKey.rawValue, forKey: Keys.hangulKey); onOptionsChange?() }
    }
    @Published var zipEncoding: ZipNameEncoding {
        didSet { defaults.set(zipEncoding.rawValue, forKey: Keys.zipEncoding) }
    }
    @Published var statItems: [StatItem] {
        didSet { defaults.set(statItems.map(\.rawValue), forKey: Keys.statItems); onOptionsChange?() }
    }
    @Published var linesPerNotch: Int {
        didSet { defaults.set(linesPerNotch, forKey: Keys.linesPerNotch); onOptionsChange?() }
    }
    /// Ctrl+Shift+Esc로 맥편해 작업 관리자를 열지(true), 활동 모니터를 열지(false).
    @Published var useOwnTaskManager: Bool {
        didSet { defaults.set(useOwnTaskManager, forKey: Keys.useOwnTaskManager) }
    }
    @Published var accessibilityGranted = false
    @Published var tapStatus: TapStatus = .off
    /// 같은 기능을 켠 다른 앱(예: Vorssaint).
    @Published var conflicts: [FeatureConflict] = []

    func conflict(for id: FeatureID) -> FeatureConflict? { conflicts.first { $0.feature == id } }
    @Published var launchAtLogin = false
    @Published var showWelcome = false

    /// (이전, 이후) 켜진 기능 목록.
    var onChange: ((Set<FeatureID>, Set<FeatureID>) -> Void)?
    var onOptionsChange: (() -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Void)?
    var onRequestAccessibility: (() -> Void)?

    enum Keys {
        static let enabled = "enabledFeatures"
        static let hangulKey = "hangulKey"
        static let zipEncoding = "zipEncoding"
        static let didFirstLaunch = "didFirstLaunch"
        static let statItems = "statItems"
        static let linesPerNotch = "linesPerNotch"
        static let useOwnTaskManager = "useOwnTaskManager"
        static let knownFeatures = "knownFeatures"
        static let terminalApp = "terminalApp"
    }

    init() {
        let saved = defaults.stringArray(forKey: Keys.enabled) ?? []
        enabled = Set(saved.compactMap(FeatureID.init(rawValue:)))
        hangulKey = HangulKeyChoice(rawValue: defaults.string(forKey: Keys.hangulKey) ?? "") ?? .rightCommand
        zipEncoding = ZipNameEncoding(rawValue: defaults.string(forKey: Keys.zipEncoding) ?? "") ?? .windowsKorean
        statItems = (defaults.stringArray(forKey: Keys.statItems)?.compactMap(StatItem.init(rawValue:))) ?? StatItem.defaults
        let lines = defaults.integer(forKey: Keys.linesPerNotch)
        linesPerNotch = lines > 0 ? lines : 3
        useOwnTaskManager = defaults.object(forKey: Keys.useOwnTaskManager) as? Bool ?? true
    }

    var isFirstLaunch: Bool { !defaults.bool(forKey: Keys.didFirstLaunch) }

    func markLaunched() { defaults.set(true, forKey: Keys.didFirstLaunch) }

    func newlyRecommendedFeatures() -> Set<FeatureID> {
        FeatureCatalog.newlyRecommended(known: defaults.stringArray(forKey: Keys.knownFeatures).map(Set.init))
    }

    func markAllFeaturesKnown() {
        defaults.set(FeatureID.allCases.map(\.rawValue).sorted(), forKey: Keys.knownFeatures)
    }

    func isOn(_ id: FeatureID) -> Bool { enabled.contains(id) }

    func set(_ id: FeatureID, _ on: Bool) {
        var next = enabled
        if on { next.insert(id) } else { next.remove(id) }
        replace(with: next)
    }

    func replace(with next: Set<FeatureID>) {
        guard next != enabled else { return }
        let old = enabled
        enabled = next
        defaults.set(next.map(\.rawValue).sorted(), forKey: Keys.enabled)
        onChange?(old, next)
    }

    func applyRecommended() { replace(with: enabled.union(FeatureCatalog.recommended)) }

    func disableAll() { replace(with: []) }

    var needsAccessibility: Bool { enabled.contains { FeatureCatalog.info($0).needsAccessibility } }

    func openTaskManager() {
        if useOwnTaskManager { TaskManagerWindow.show() } else { KeyRouter.openActivityMonitor() }
    }

    func setLaunchAtLogin(_ on: Bool) { onLaunchAtLoginChange?(on) }
    func requestAccessibility() { onRequestAccessibility?() }

    func toggleStat(_ item: StatItem) {
        if let i = statItems.firstIndex(of: item) {
            statItems.remove(at: i)
        } else {
            // 정해진 순서를 유지한다.
            statItems = StatItem.allCases.filter { statItems.contains($0) || $0 == item }
        }
    }
}
