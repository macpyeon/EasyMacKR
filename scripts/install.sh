#!/bin/zsh
# 맥편해 설치: 빌드 → /Applications 복사 → 실행.
# 처음 실행하면 추천 설정이 자동으로 적용되고, 로그인할 때 자동 실행됩니다.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=kr.macpyeon.MacPyeon
DEST=/Applications/MacPyeon.app

./scripts/build-app.sh

if pgrep -x MacPyeon >/dev/null; then
  echo "▸ 실행 중인 맥편해 종료"
  pkill -x MacPyeon || true
  sleep 1
fi

UPGRADE=0
[[ -d "$DEST" ]] && UPGRADE=1

echo "▸ $DEST 에 설치"
rm -rf "$DEST"
cp -R build/MacPyeon.app "$DEST"

# 임시 서명일 때만 예전 권한 기록을 지운다(로컬 인증서 서명이면 권한이 그대로 유지됨).
if [[ $UPGRADE == 1 ]] && codesign -dr - "$DEST" 2>&1 | grep -q cdhash; then
  # 임시 서명 앱은 빌드할 때마다 서명이 바뀌어서, 예전 권한 기록이 남아 있으면 키보드 기능이 동작하지 않는다.
  # 기록을 지우고 다시 허용받는다.
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "  (업데이트라서 손쉬운 사용 권한을 한 번 더 허용해야 해요)"
fi

# Finder 오른쪽 클릭 > 빠른 동작 메뉴 갱신
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

open "$DEST"
echo "✓ 설치 완료. 메뉴 막대의 ⌨︎ 아이콘에서 설정을 열 수 있어요."
