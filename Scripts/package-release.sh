#!/bin/bash
set -euo pipefail
ORBIT_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
export ORBIT_RUNTIME="${ORBIT_RUNTIME:-$ORBIT_PROJECT/.build/orbit-release}"
cd "$ORBIT_PROJECT"
"$ORBIT_PROJECT/Scripts/build.sh" --arch arm64 --arch x86_64

ORBIT_APP="$ORBIT_PROJECT/dist/Orbit.app"
ORBIT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ORBIT_APP/Contents/Info.plist")"
ORBIT_NAME="Orbit-$ORBIT_VERSION-universal"
for ORBIT_BINARY in "$ORBIT_APP/Contents/MacOS/Orbit" "$ORBIT_APP/Contents/Helpers/OrbitFanAgent" "$ORBIT_APP/Contents/Helpers/OrbitUpdateAgent"; do
    lipo "$ORBIT_BINARY" -verify_arch arm64 x86_64
done

ORBIT_STAGE="$(mktemp -d "$ORBIT_RUNTIME/package.XXXXXX")"
trap 'rm -rf "$ORBIT_STAGE"' EXIT
ditto "$ORBIT_APP" "$ORBIT_STAGE/Orbit.app"
ln -s /Applications "$ORBIT_STAGE/Applications"
cat > "$ORBIT_STAGE/安装说明.txt" <<'EOF'
将 Orbit.app 拖入 Applications，然后从“应用程序”启动。
系统要求：macOS 14 或更新版本，支持 Apple Silicon 和 Intel。

签名、公证状态及功能限制以此版本的 Release 说明为准：
https://github.com/Simonlau4/orbit-mac/releases

如果 macOS 提示无法验证开发者，请先核对下载包的 SHA-256。
确认来源后，可在“系统设置 → 隐私与安全性”中选择“仍要打开”。
https://support.apple.com/102445
EOF

cd "$ORBIT_PROJECT/dist"
ditto -c -k --sequesterRsrc --keepParent Orbit.app "$ORBIT_NAME.zip"
hdiutil create -volname "Orbit $ORBIT_VERSION" -srcfolder "$ORBIT_STAGE" -ov -format UDZO "$ORBIT_NAME.dmg"
hdiutil verify "$ORBIT_NAME.dmg"
shasum -a 256 "$ORBIT_NAME.dmg" "$ORBIT_NAME.zip" > SHA256SUMS.txt
printf '\n发布包：%s/dist/%s.{dmg,zip}\n' "$ORBIT_PROJECT" "$ORBIT_NAME"
