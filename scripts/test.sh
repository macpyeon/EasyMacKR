#!/bin/zsh
# Xcode 없이 Command Line Tools만 있어도 swift-testing 테스트가 돌도록 경로를 잡아 준다.
set -e
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
if [[ -d "$DEV/Frameworks/Testing.framework" ]]; then
  exec swift test \
    -Xswiftc -F$DEV/Frameworks \
    -Xlinker -F$DEV/Frameworks \
    -Xlinker -rpath -Xlinker $DEV/Frameworks \
    -Xlinker -rpath -Xlinker $DEV/usr/lib "$@"
else
  exec swift test "$@"
fi
