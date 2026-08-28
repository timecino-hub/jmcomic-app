#!/bin/sh
# jmcomic-ios 构建自检脚本（Task 2 验收命令）
# 用法：./build.sh   成功标准：退出码 0
set -e

cd "$(dirname "$0")"

exec env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project jmcomic-ios.xcodeproj \
             -scheme JMComic-iOS \
             -destination 'generic/platform=iOS Simulator' \
             build "$@"
