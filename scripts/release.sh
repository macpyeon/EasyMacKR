#!/bin/zsh
# Homebrew 배포용 릴리스를 만든다.
#   ./scripts/release.sh 0.2.0 [GitHub 저장소(소유자/이름)]
#
# 결과:
#   dist/MacPyeon-<버전>.zip  → GitHub 릴리스 v<버전> 에 올릴 파일
#   Casks/macpyeon.rb         → 버전·체크섬·주소가 채워진 Homebrew cask
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?버전을 적어 주세요. 예) ./scripts/release.sh 0.2.0 owner/macpyeon}"
REPO="${2:-${GITHUB_REPO:-Han-wo/EasyMacKR}}"

# 배포판은 항상 임시 서명: 개발자 개인 인증서가 배포물에 들어가지 않게 한다.
SIGN=adhoc UNIVERSAL=1 VERSION="$VERSION" ./scripts/build-app.sh
codesign -dr - build/MacPyeon.app 2>&1 | grep -q cdhash || { echo "✗ 배포판이 임시 서명이 아니에요. 중단합니다."; exit 1; }

mkdir -p dist
ZIP="dist/MacPyeon-$VERSION.zip"
rm -f "$ZIP"
# ditto는 서명·확장 속성을 보존한 채 압축한다(앱 배포 표준 방식).
ditto -c -k --keepParent build/MacPyeon.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

URL="https://github.com/$REPO/releases/download/v#{version}/MacPyeon-#{version}.zip"
# 로컬 시험용: MACPYEON_LOCAL_URL=1 이면 이 Mac의 파일 주소를 넣는다.
if [[ "${MACPYEON_LOCAL_URL:-0}" == 1 ]]; then
  URL="file://$PWD/dist/MacPyeon-#{version}.zip"
fi

sed -e "s|__VERSION__|$VERSION|" -e "s|__SHA256__|$SHA|" -e "s|__URL__|$URL|" -e "s|__REPO__|$REPO|" \
  Casks/macpyeon.rb.template > Casks/macpyeon.rb

echo
echo "✓ $ZIP"
echo "  sha256 $SHA"
echo "✓ Casks/macpyeon.rb"
echo
echo "다음 단계:"
echo "  1) GitHub 저장소 $REPO 에 릴리스 v$VERSION 을 만들고 $ZIP 을 올리세요."
echo "  2) Casks/macpyeon.rb 를 커밋·푸시하세요."
echo "  3) 설치:  brew tap han-wo/easymackr https://github.com/$REPO && brew install --cask macpyeon"
