#!/bin/zsh
# 릴리스 빌드 후 build/MacPyeon.app 으로 묶는다.
#   UNIVERSAL=1 ./scripts/build-app.sh   → Apple Silicon + Intel 범용 앱
#   VERSION=0.2.0 ./scripts/build-app.sh → 앱 버전 지정
#   SIGN=release ./scripts/build-app.sh  → 배포 전용 인증서(MacPyeon Release)로 서명(배포용)
#   SIGN=adhoc ./scripts/build-app.sh    → 인증서 없이 임시 서명
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
if [[ "${SIGN:-}" == release ]]; then
  plutil -replace MacPyeonReleaseBuild -bool YES "$APP/Contents/Info.plist"
fi
if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi

# 서명. 같은 인증서로 계속 서명해야 손쉬운 사용 권한이 업데이트 후에도 유지된다.
#  - 배포판(SIGN=release): 배포 전용 인증서 MacPyeon Release (scripts/make-release-cert.sh). 없으면 중단.
#  - 직접 빌드: 이 Mac 전용 인증서 MacPyeon Local Signing (scripts/make-signing-cert.sh)이 있으면 그것.
#    이 개인용 인증서는 배포판에 절대 쓰지 않는다.
#  - 그 밖: 임시 서명(ad-hoc).
# 이름이 겹치지 않게 인증서 지문(SHA-1)으로 고른다.
cert_hash() { security find-certificate -c "$1" -Z 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}'; }
if [[ "${SIGN:-}" == release ]]; then
  RELEASE_ID=$(cert_hash "MacPyeon Release")
  [[ -n "$RELEASE_ID" ]] || { echo "✗ 배포 인증서(MacPyeon Release)가 없어요. scripts/make-release-cert.sh 를 먼저 실행하세요."; exit 1; }
  codesign --force --deep --timestamp=none --sign "$RELEASE_ID" "$APP"
elif [[ "${SIGN:-}" != adhoc ]] && [[ -n "$(cert_hash "MacPyeon Local Signing")" ]]; then
  codesign --force --deep --sign "$(cert_hash "MacPyeon Local Signing")" "$APP"
else
  echo "  (임시 서명: 업데이트할 때마다 손쉬운 사용 권한을 다시 허용해야 해요. scripts/make-signing-cert.sh 를 한 번 실행하면 해결돼요)"
  codesign --force --deep --sign - "$APP"
fi
echo "✓ $APP ($(lipo -archs "$APP/Contents/MacOS/MacPyeon"))"
