#!/bin/bash
# 构建 ScreenPin.app：release 编译 + 组装 bundle + 签名。
# 优先用已在本机配置的自签名证书：
# 其 designated requirement 绑定证书，跨构建稳定，「屏幕录制」授权只需授予一次。
# 找不到证书时回退 ad-hoc 签名（DR 绑定 cdhash，每次重编译授权都会失效）。
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=ScreenPin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ScreenPin "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/ScreenPin.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/" # 语言包（zh-Hans 翻译；英文为开发语言，无需 en.lproj）

IDENTITY="ScreenPin Local Dev"
KC=~/Library/Keychains/screenpin-dev.keychain-db
if security find-certificate -c "$IDENTITY" "$KC" >/dev/null 2>&1; then
    # 由开发者在系统钥匙串中解锁，不在脚本中保存或传递密码。
    codesign --force --sign "$IDENTITY" --keychain "$KC" --identifier com.shendi.screenpin "$APP"
else
    echo "警告：未找到 $IDENTITY 证书，回退 ad-hoc 签名（重新编译后需重新授权）"
    codesign --force --sign - --identifier com.shendi.screenpin "$APP"
fi

echo "OK -> $(pwd)/$APP"

# --install：同步安装到 /Applications（覆盖旧版）
if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    echo "Installed -> /Applications/$APP"
fi
