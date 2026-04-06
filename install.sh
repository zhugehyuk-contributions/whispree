#!/bin/bash
# Whispree 빌드 → 설치 → 권한 리셋 → 실행 스크립트
set -e

echo "=== Whispree 종료 ==="
pkill -f "Whispree.app" 2>/dev/null || true
sleep 1

echo "=== 빌드 ==="
xcodebuild -project Whispree.xcodeproj -scheme Whispree -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3

echo "=== /Applications에 설치 ==="
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Whispree-*/Build/Products/Debug -name 'Whispree.app' -maxdepth 1)
cp -R "$APP_PATH" /Applications/

echo "=== 코드 서명 ==="
codesign --force --deep --sign - /Applications/Whispree.app
xattr -cr /Applications/Whispree.app

echo "=== 권한 리셋 (Accessibility + Input Monitoring) ==="
tccutil reset Accessibility com.whispree.app 2>/dev/null || true
tccutil reset ListenEvent com.whispree.app 2>/dev/null || true

echo "=== 실행 ==="
open /Applications/Whispree.app

echo "✓ 완료. 접근성 권한을 허용하면 자동으로 재시작됩니다."
