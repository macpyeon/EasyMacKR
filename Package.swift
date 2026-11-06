// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacPyeon",
    platforms: [.macOS(.v13)],
    targets: [
        // 순수 로직(키 규칙, 한글 파일명, zip 작성, 설정 카탈로그). UI·시스템 API 없이 테스트 가능.
        .target(name: "MacPyeonCore"),
        // 메뉴 막대 앱 본체.
        .executableTarget(
            name: "MacPyeon",
            dependencies: ["MacPyeonCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(name: "MacPyeonCoreTests", dependencies: ["MacPyeonCore"]),
    ]
)
