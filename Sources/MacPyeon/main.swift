import AppKit

// `MacPyeon --reset` : 바꾼 시스템 설정을 모두 원래대로 돌리고 끝낸다(삭제 스크립트가 쓴다).
if CommandLine.arguments.contains("--reset") {
    AppController.resetEverything()
    exit(0)
}

// `MacPyeon --render-panel <폴더>` : 간단 패널의 탭별 화면을 PNG로 저장한다(확인·문서용).
if let i = CommandLine.arguments.firstIndex(of: "--render-panel"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    PanelRenderer.render(to: CommandLine.arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
