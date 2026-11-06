import Foundation

/// 설정 화면의 분류.
public enum FeatureCategory: String, CaseIterable, Sendable {
    case korean
    case windows
    case mouse
    case window
    case clipboard
    case monitor
    case finder
    case system

    public var title: String {
        switch self {
        case .korean: return "한국어"
        case .windows: return "윈도우처럼"
        case .mouse: return "마우스·스크롤"
        case .window: return "창·도구 단축키"
        case .clipboard: return "클립보드"
        case .monitor: return "모니터링"
        case .finder: return "Finder"
        case .system: return "시스템"
        }
    }

    public var symbol: String {
        switch self {
        case .korean: return "character.bubble"
        case .windows: return "macwindow.on.rectangle"
        case .mouse: return "computermouse"
        case .window: return "rectangle.split.2x1"
        case .clipboard: return "doc.on.clipboard"
        case .monitor: return "gauge.with.dots.needle.33percent"
        case .finder: return "folder"
        case .system: return "gearshape"
        }
    }
}

/// 켜고 끌 수 있는 기능 하나.
public enum FeatureID: String, CaseIterable, Sendable {
    // 한국어
    case hangulKey
    case capsLockHangul
    case escToEnglish
    case wonToBacktick
    case nfcFilenames
    case disableAutoCorrect

    // 윈도우처럼
    case taskManager
    case finderF2Rename
    case finderCutPaste
    case finderDeleteKey
    case finderEnterOpens
    case finderNewTextFile
    case homeEndKeys
    case finderPasteImage

    // 마우스·스크롤
    case mouseScrollReverse
    case mouseScrollReverseHorizontal
    case linearScroll
    case mouseSideButtons

    // 창·도구
    case windowSnap
    case quitProtection
    case toolShortcuts

    // 클립보드
    case clipboardHistory
    case plainTextPaste
    case cleanURLs

    // 모니터링
    case menuBarStats
    case systemAlerts

    // Finder
    case showExtensions
    case showPathBar
    case showStatusBar
    case foldersFirst
    case searchCurrentFolder
    case noExtensionWarning
    case showHiddenFiles
    case noDSStoreExternal

    // 시스템
    case keyRepeat
    case screenshotNoShadow
    case dockNoDelay
}

/// 기능이 어떤 방식으로 동작하는지. 적용·해제 경로가 여기서 갈린다.
public enum FeatureKind: Sendable, Equatable {
    /// 키보드·마우스 이벤트를 가로채 바꾼다. 손쉬운 사용 권한이 필요하다.
    case eventTap
    /// ~/Library/KeyBindings/DefaultKeyBinding.dict 에 항목을 쓴다.
    case keyBinding
    /// 시스템 defaults 값을 바꾼다. 끄면 원래 값으로 되돌린다.
    case defaults
    /// 앱이 백그라운드에서 따로 돌리는 작업(폴더 감시, 키 리매핑 등).
    case service
}

public struct FeatureInfo: Sendable, Identifiable {
    public let id: FeatureID
    public let category: FeatureCategory
    public let kind: FeatureKind
    public let title: String
    public let detail: String
    /// 처음 설치할 때 자동으로 켤지.
    public let recommended: Bool
    /// 적용 후 사용자가 알아야 할 점(예: 앱을 다시 열어야 적용).
    public let note: String?

    /// 키보드 단축키를 쓰는 기능은 손쉬운 사용 권한이 필요하다.
    public var needsAccessibility: Bool {
        kind == .eventTap || id == .capsLockHangul || id == .clipboardHistory
    }
}

public enum FeatureCatalog {
    public static let all: [FeatureInfo] = [
        // MARK: 한국어
        FeatureInfo(
            id: .hangulKey, category: .korean, kind: .eventTap,
            title: "한/영 전환 키 만들기",
            detail: "오른쪽 ⌘(또는 오른쪽 ⌥)만 눌렀다 떼면 한/영이 바뀝니다. 다른 키와 같이 누르면 원래대로 동작해요. 윈도우용 키보드의 한/영 키도 인식합니다.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .capsLockHangul, category: .korean, kind: .service,
            title: "Caps Lock 즉시 한/영 전환",
            detail: "Caps Lock으로 한/영을 바꿀 때 생기는 지연과 씹힘을 없앱니다. 대신 Caps Lock(대문자 고정)은 쓸 수 없어요.",
            recommended: false, note: "켜는 동안만 적용되고, 앱을 끄면 원래 Caps Lock으로 돌아옵니다."),
        FeatureInfo(
            id: .escToEnglish, category: .korean, kind: .eventTap,
            title: "Esc 누르면 영문으로",
            detail: "한글 입력 중 Esc를 누르면 영문으로 바뀝니다. Vim·터미널을 쓰는 개발자에게 편해요.",
            recommended: false, note: nil),
        FeatureInfo(
            id: .wonToBacktick, category: .korean, kind: .keyBinding,
            title: "₩ 대신 ` (백틱) 입력",
            detail: "한글 자판에서 ` 키를 누르면 ₩ 대신 ` 가 입력됩니다. 마크다운·코드 작성할 때 편해요.",
            recommended: true, note: "이미 열려 있는 앱은 다시 열어야 적용됩니다. (일부 앱은 지원하지 않음)"),
        FeatureInfo(
            id: .nfcFilenames, category: .korean, kind: .service,
            title: "한글 파일명 자소 분리 자동 정리",
            detail: "데스크탑·다운로드 폴더에 생기는 파일 이름을 NFC로 바꿔서, 윈도우나 웹에 올렸을 때 'ㅎㅏㄴㄱㅡㄹ'처럼 깨지지 않게 합니다.",
            recommended: true, note: "처음 켤 때 데스크탑·다운로드 폴더 접근을 허용해 주세요."),
        FeatureInfo(
            id: .disableAutoCorrect, category: .korean, kind: .defaults,
            title: "자동 수정·자동 대문자 끄기",
            detail: "맞춤법 자동 수정, 첫 글자 자동 대문자, 스페이스 두 번에 마침표, 둥근 따옴표 변환을 끕니다. 한글 입력할 때 단어가 멋대로 바뀌는 걸 막아요.",
            recommended: true, note: "이미 열려 있는 앱은 다시 열어야 적용됩니다."),

        // MARK: 윈도우처럼
        FeatureInfo(
            id: .taskManager, category: .windows, kind: .eventTap,
            title: "작업 관리자 열기 (Ctrl+⌘+Delete)",
            detail: "Ctrl+⌘+Delete 또는 Ctrl+Shift+Esc로 작업 관리자를 엽니다. 프로그램별 CPU·메모리·GPU 사용량을 보고 종료·강제 종료할 수 있어요.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .finderF2Rename, category: .windows, kind: .eventTap,
            title: "F2로 이름 바꾸기",
            detail: "Finder에서 파일을 고르고 F2를 누르면 바로 이름을 바꿉니다. fn 없이 눌러도 돼요.",
            recommended: true, note: "Finder에서 파일을 고른 상태일 때만 F2(밝기 올리기 키)가 이름 바꾸기로 바뀌고, 다른 곳에서는 밝기 키 그대로예요."),
        FeatureInfo(
            id: .finderCutPaste, category: .windows, kind: .eventTap,
            title: "잘라내기·붙여넣기 (⌘X → ⌘V)",
            detail: "Finder에서 ⌘X로 잘라낸 뒤 ⌘V로 붙여넣으면 파일이 이동합니다.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .finderDeleteKey, category: .windows, kind: .eventTap,
            title: "지우기 키로 휴지통에 버리기",
            detail: "Finder에서 파일을 고르고 지우기(delete) 키만 누르면 휴지통으로 옮깁니다. 이름을 바꾸는 중에는 원래대로 글자를 지워요. 실수했으면 ⌘Z로 되돌릴 수 있어요.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .finderEnterOpens, category: .windows, kind: .eventTap,
            title: "Enter로 파일 열기",
            detail: "Finder에서 Enter를 누르면 이름 바꾸기 대신 파일·폴더를 엽니다. (이름 바꾸기는 F2)",
            recommended: false, note: nil),
        FeatureInfo(
            id: .finderNewTextFile, category: .windows, kind: .eventTap,
            title: "새 텍스트 문서 만들기 (Ctrl+⌥+N)",
            detail: "Finder에서 Ctrl+⌥+N을 누르면 지금 보고 있는 폴더에 '새 텍스트 문서.txt'를 만들고 바로 이름을 바꿀 수 있게 합니다.",
            recommended: true, note: "처음 사용할 때 Finder 제어 허용 창이 뜹니다."),
        FeatureInfo(
            id: .homeEndKeys, category: .windows, kind: .keyBinding,
            title: "Home / End 키로 줄 처음·끝 이동",
            detail: "글을 쓸 때 Home·End가 줄의 처음과 끝으로 이동합니다. Shift를 같이 누르면 선택, Ctrl을 같이 누르면 문서 처음·끝입니다.",
            recommended: true, note: "이미 열려 있는 앱은 다시 열어야 적용됩니다."),
        FeatureInfo(
            id: .finderPasteImage, category: .windows, kind: .eventTap,
            title: "복사한 이미지를 파일로 붙여넣기",
            detail: "스크린샷이나 웹 이미지를 복사한 뒤 Finder에서 ⌘V를 누르면 지금 폴더에 PNG 파일로 저장됩니다.",
            recommended: true, note: nil),

        // MARK: 마우스·스크롤
        FeatureInfo(
            id: .mouseScrollReverse, category: .mouse, kind: .eventTap,
            title: "마우스 세로 스크롤 반대로",
            detail: "트랙패드는 그대로 두고, 휠 마우스만 윈도우처럼 위아래 방향을 뒤집습니다.",
            recommended: false, note: "'자연스러운 스크롤'이 켜져 있을 때 쓰세요."),
        FeatureInfo(
            id: .mouseScrollReverseHorizontal, category: .mouse, kind: .eventTap,
            title: "마우스 가로 스크롤 반대로",
            detail: "틸트 휠·가로 휠의 좌우 방향을 뒤집습니다. 트랙패드는 그대로예요.",
            recommended: false, note: nil),
        FeatureInfo(
            id: .linearScroll, category: .mouse, kind: .eventTap,
            title: "휠 한 칸에 일정하게 스크롤",
            detail: "휠을 빨리 돌려도 한 칸에 정해진 줄 수만큼만 움직입니다. 윈도우처럼 예측 가능한 스크롤이에요.",
            recommended: false, note: nil),
        FeatureInfo(
            id: .mouseSideButtons, category: .mouse, kind: .eventTap,
            title: "마우스 옆 버튼으로 뒤로/앞으로",
            detail: "마우스 옆 버튼(4·5번)으로 Finder와 브라우저(Safari, Chrome, 웨일, Edge, Firefox 등)에서 뒤로·앞으로 갑니다.",
            recommended: true, note: nil),

        // MARK: 창·도구
        FeatureInfo(
            id: .windowSnap, category: .window, kind: .eventTap,
            title: "창 배치 단축키",
            detail: "⌃⌥← / → 왼쪽·오른쪽 절반, ⌃⌥↑ 또는 ⌃⌥↩ 최대화, ⌃⌥↓ 원래대로, ⌃⌥⇧↑ / ↓ 위·아래 절반, ⌃⌥C 가운데, ⌃⌥⌘← / → 다른 모니터로.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .quitProtection, category: .window, kind: .eventTap,
            title: "⌘Q 실수로 종료 방지",
            detail: "⌘Q를 한 번 누르면 안내만 뜨고, 1초 안에 한 번 더 눌러야 앱이 종료됩니다. ⌘W 누르려다 앱이 꺼지는 걸 막아요.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .toolShortcuts, category: .window, kind: .eventTap,
            title: "도구 단축키",
            detail: "⌃⌥T 화면 글자 복사(한국어 OCR), ⌃⌥P 화면 색상 추출, ⌃⌥M 마이크 음소거 켜기/끄기.",
            recommended: true, note: "화면 글자 복사는 처음에 화면 기록 권한을 물어봅니다."),

        // MARK: 클립보드
        FeatureInfo(
            id: .clipboardHistory, category: .clipboard, kind: .service,
            title: "클립보드 기록 (⌃⌥V)",
            detail: "복사한 글과 이미지를 기억해 두고, ⌃⌥V로 목록을 열어 골라 붙여넣습니다. 윈도우의 Win+V와 같아요.",
            recommended: false, note: "글은 이 Mac에만 저장되고(이미지는 메모리에만), 끄면 기록을 지웁니다. 비밀번호 관리자처럼 '숨김' 표시를 하는 앱의 내용은 저장하지 않아요."),
        FeatureInfo(
            id: .plainTextPaste, category: .clipboard, kind: .eventTap,
            title: "서식 없이 붙여넣기 (⌘⌥⇧V)",
            detail: "어느 앱에서든 글꼴·색 같은 서식을 빼고 글자만 붙여넣습니다. 클립보드 원래 내용은 그대로 남아요.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .cleanURLs, category: .clipboard, kind: .service,
            title: "링크 추적 코드 자동 제거",
            detail: "복사한 링크에서 utm_, fbclid, gclid 같은 추적 파라미터를 지웁니다.",
            recommended: false, note: nil),

        // MARK: 모니터링
        FeatureInfo(
            id: .menuBarStats, category: .monitor, kind: .service,
            title: "메뉴 막대에 시스템 상태 표시",
            detail: "CPU, 메모리, 네트워크, 배터리 같은 수치를 메뉴 막대에 띄웁니다. 보여 줄 항목은 아래에서 고르세요.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .systemAlerts, category: .monitor, kind: .service,
            title: "시스템 경고 알림",
            detail: "CPU가 오래 바쁠 때, 메모리가 부족할 때, 디스크가 10GB 아래로 남았을 때, 배터리가 15% 아래일 때, Mac이 뜨거울 때 알려 줍니다.",
            recommended: false, note: "처음 켤 때 알림 허용 창이 뜹니다."),

        // MARK: Finder
        FeatureInfo(
            id: .showExtensions, category: .finder, kind: .defaults,
            title: "파일 확장자 항상 보기",
            detail: "모든 파일 이름 뒤에 .pdf, .hwp 같은 확장자를 보여 줍니다.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .showPathBar, category: .finder, kind: .defaults,
            title: "경로 막대 보기",
            detail: "Finder 창 아래에 현재 폴더 경로를 보여 줍니다.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .showStatusBar, category: .finder, kind: .defaults,
            title: "상태 막대 보기",
            detail: "Finder 창 아래에 항목 수와 남은 용량을 보여 줍니다.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .foldersFirst, category: .finder, kind: .defaults,
            title: "폴더를 항상 위에 정렬",
            detail: "이름순으로 정렬할 때 윈도우처럼 폴더를 파일보다 먼저 보여 줍니다.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .searchCurrentFolder, category: .finder, kind: .defaults,
            title: "검색은 현재 폴더에서",
            detail: "Finder 검색창에 입력하면 Mac 전체가 아니라 지금 폴더 안에서 찾습니다.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .noExtensionWarning, category: .finder, kind: .defaults,
            title: "확장자 바꿀 때 경고 끄기",
            detail: "파일 확장자를 바꿀 때마다 뜨는 확인 창을 없앱니다.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .showHiddenFiles, category: .finder, kind: .defaults,
            title: "숨김 파일 보기",
            detail: ".으로 시작하는 숨김 파일도 보여 줍니다. (⌘⇧. 으로도 잠깐 켤 수 있어요)",
            recommended: false, note: nil),
        FeatureInfo(
            id: .noDSStoreExternal, category: .finder, kind: .defaults,
            title: "USB·네트워크 드라이브에 .DS_Store 안 만들기",
            detail: "USB나 공유 폴더를 윈도우에서 열었을 때 .DS_Store, ._ 파일이 잔뜩 보이는 걸 줄입니다.",
            recommended: true, note: "다시 로그인하면 완전히 적용됩니다."),

        // MARK: 시스템
        FeatureInfo(
            id: .keyRepeat, category: .system, kind: .defaults,
            title: "키 꾹 누르면 연속 입력",
            detail: "영문 키를 꾹 누르면 악센트 선택 창 대신 같은 글자가 계속 입력됩니다.",
            recommended: true, note: "이미 열려 있는 앱은 다시 열어야 적용됩니다."),
        FeatureInfo(
            id: .screenshotNoShadow, category: .system, kind: .defaults,
            title: "창 스크린샷 그림자 없애기",
            detail: "⌘⇧4 → 스페이스로 창을 찍을 때 들어가는 큰 그림자를 없앱니다.",
            recommended: true, note: nil),
        FeatureInfo(
            id: .dockNoDelay, category: .system, kind: .defaults,
            title: "Dock 자동 숨김 지연 없애기",
            detail: "Dock 자동 숨김을 쓸 때 마우스를 내리면 바로 나타나게 합니다.",
            recommended: false, note: nil),
    ]

    private static let byID: [FeatureID: FeatureInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func info(_ id: FeatureID) -> FeatureInfo { byID[id]! }

    public static func features(in category: FeatureCategory) -> [FeatureInfo] {
        all.filter { $0.category == category }
    }

    public static var recommended: Set<FeatureID> { Set(all.filter(\.recommended).map(\.id)) }
}

/// 한/영 전환에 쓸 단독 키.
/// 메뉴 막대에 띄울 수치.
public enum StatItem: String, CaseIterable, Sendable {
    case cpu, gpu, memory, network, battery, disk

    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "메모리"
        case .network: return "네트워크"
        case .battery: return "배터리"
        case .disk: return "디스크"
        }
    }

    public static let defaults: [StatItem] = [.cpu, .memory]
}

public enum HangulKeyChoice: String, CaseIterable, Sendable {
    case rightCommand
    case rightOption

    public var title: String {
        switch self {
        case .rightCommand: return "오른쪽 ⌘"
        case .rightOption: return "오른쪽 ⌥"
        }
    }
}
