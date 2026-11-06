#!/bin/zsh
# 맥편해 삭제: 바꾼 시스템 설정을 원래대로 돌린 뒤 앱을 지운다.
set -euo pipefail

BUNDLE_ID=kr.macpyeon.MacPyeon
DEST=/Applications/MacPyeon.app

pkill -x MacPyeon 2>/dev/null || true
sleep 1

if [[ -x "$DEST/Contents/MacOS/MacPyeon" ]]; then
  "$DEST/Contents/MacOS/MacPyeon" --reset
fi

rm -rf "$DEST"
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset AppleEvents "$BUNDLE_ID" >/dev/null 2>&1 || true
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Application Support/MacPyeon"   # 클립보드 기록·진단 기록
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
echo "✓ 맥편해를 삭제하고 바꾼 설정을 원래대로 돌렸어요."
