#!/bin/sh
# 构建 iPhone + iPad 通用的未签名 IPA。
# 需要 macOS + Xcode；产物仍需用个人 Apple ID / 开发者证书签名后才能安装。
set -eu

cd "$(dirname "$0")"

output_path="${1:-dist/JMComic-iPadOS-unsigned.ipa}"
case "$output_path" in
  /*) output_abs="$output_path" ;;
  *) output_abs="$(pwd)/$output_path" ;;
esac
derived_path="build-ipados"
stage_path="$(mktemp -d "${TMPDIR:-/tmp}/jmcomic-ipados.XXXXXX")"
trap 'rm -rf "$stage_path"' EXIT HUP INT TERM

env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project jmcomic-ios.xcodeproj \
             -scheme JMComic-iOS \
             -destination 'generic/platform=iOS' \
             -derivedDataPath "$derived_path" \
             -configuration Release \
             CODE_SIGNING_ALLOWED=NO \
             CODE_SIGNING_REQUIRED=NO \
             CODE_SIGN_IDENTITY="" \
             DEVELOPMENT_TEAM="" \
             build

app_path="$(find "$derived_path/Build/Products" -type d -name '*.app' | head -1)"
if [ -z "$app_path" ]; then
  echo "未找到构建后的 .app" >&2
  exit 1
fi

mkdir -p "$stage_path/Payload" "$(dirname "$output_abs")"
cp -R "$app_path" "$stage_path/Payload/"
(
  cd "$stage_path"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$output_abs"
)

echo "已生成：$output_path"
