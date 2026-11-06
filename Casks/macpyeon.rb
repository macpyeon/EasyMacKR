cask "macpyeon" do
  version "0.1.2"
  sha256 "b97fea7a52b852e79e0b915f315e4aa87f6eaeafed82a01cfcd83d57ac2f9e94"

  url "https://github.com/macpyeon/EasyMacKR/releases/download/v#{version}/MacPyeon-#{version}.zip"
  name "MacPyeon"
  name "맥편해"
  desc "Korean-friendly utilities: Hangul key, Windows-style shortcuts, task manager"
  homepage "https://github.com/macpyeon/EasyMacKR"

  depends_on macos: :ventura

  app "MacPyeon.app"

  # Apple 공증(notarization)을 받지 않은 앱이라, 내려받은 표시(격리 속성)를 지워야 처음 실행이 막히지 않는다.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "/Applications/MacPyeon.app"], must_succeed: false
  end

  uninstall quit: "kr.macpyeon.MacPyeon"

  zap trash: [
    "~/Library/Application Support/MacPyeon",
    "~/Library/Preferences/kr.macpyeon.MacPyeon.plist",
  ]

  caveats <<~EOS
    처음 실행하면 추천 설정이 적용되고, 로그인할 때 자동 실행됩니다.
    키보드·마우스 기능을 쓰려면 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서
    '맥편해'를 켜 주세요.

    지우기 전에 맥편해 설정 > 일반 > '모두 끄고 원래대로'를 누르면
    바꾼 Finder·시스템 설정이 원래대로 돌아갑니다.
    (brew upgrade 때 설정이 초기화되지 않도록 자동으로 되돌리지는 않습니다)
  EOS
end
