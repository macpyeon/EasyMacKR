#!/bin/zsh
# 릴리스 빌드 후 build/MacPyeon.app 으로 묶는다.
#   UNIVERSAL=1 ./scripts/build-app.sh   → Apple Silicon + Intel 범용 앱
#   VERSION=0.2.0 ./scripts/build-app.sh → 앱 버전 지정
#   SIGN=adhoc ./scripts/build-app.sh    → 개인 인증서를 쓰지 않고 임시 서명(배포용)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/MacPyeon.app
echo "▸ 빌드 중…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/MacPyeon"

if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  echo "▸ Intel용 빌드 중…"
  swift build -c release --triple x86_64-apple-macosx13.0
  mkdir -p build
  lipo -create "$BIN" .build/x86_64-apple-macosx/release/MacPyeon -output build/MacPyeon-universal
  BIN=build/MacPyeon-universal
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacPyeon"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# VERSION을 안 주면 가장 최근 릴리스 태그(v0.1.1 → 0.1.1)를 쓴다. 직접 빌드한 앱이
# 자기를 옛 버전으로 알고 "새 버전이 나왔어요"를 잘못 띄우지 않게.
if [[ -z "${VERSION:-}" ]]; then
  VERSION=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)
fi
# 배포판 표시: 앱 안 업데이트(zip으로 바꾸기)는 배포판에서만 한다(직접 빌드한 앱을 덮어쓰지 않게).
if [[ "${SIGN:-}" == adhoc ]]; then
  plutil -replace MacPyeonReleaseBuild -bool YES "$APP/Contents/Info.plist"
fi
if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi

# 로컬 서명 인증서(scripts/make-signing-cert.sh)가 있으면 그걸로 서명한다.
# 서명이 매번 같아서 손쉬운 사용 권한이 업데이트 후에도 유지된다. 없으면 임시 서명(ad-hoc).
IDENTITY="MacPyeon Local Signing"
# 배포판(SIGN=adhoc)에는 개발자 개인 인증서를 절대 쓰지 않는다.
if [[ "${SIGN:-}" != adhoc ]] && security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "  (임시 서명: 업데이트할 때마다 손쉬운 사용 권한을 다시 허용해야 해요. scripts/make-signing-cert.sh 를 한 번 실행하면 해결돼요)"
  codesign --force --deep --sign - "$APP"
fi
echo "✓ $APP ($(lipo -archs "$APP/Contents/MacOS/MacPyeon"))"
