#!/bin/zsh
# 编译成 build/Easy-Pi.app。只用系统自带的 swiftc，不装任何东西。
#
# 为什么要先在临时目录里拼好再搬过来：这个仓库在 iCloud 里，
# iCloud 会往 .app 上贴 com.apple.FinderInfo 之类的扩展属性，
# codesign 见到就报 "resource fork, Finder information, or similar detritus"。
# 在本地磁盘（/var/folders）签名，再把签好的整包搬回来，签名照样有效。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Easy-Pi"
BIN="EasyPi"
APP="build/${APP_NAME}.app"
WEBUI_DIR="../.."

if ! command -v swiftc >/dev/null 2>&1; then
  echo "没找到 swiftc。先装 Xcode Command Line Tools：xcode-select --install" >&2
  exit 1
fi

WORK="$(mktemp -d)/${APP_NAME}.app"
mkdir -p "$WORK/Contents/MacOS" "$WORK/Contents/Resources"

echo "编译 Swift 源码…"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  -o "$WORK/Contents/MacOS/$BIN" Sources/*.swift

cp Info.plist "$WORK/Contents/Info.plist"

# 图标：优先拿 webui 项目里的母图 SVG 渲一张 1024 的 png，再打包成 icns。
# 母图 SVG 没写 width/height，sips 渲不出大图，这里临时补上。
SVG="$WEBUI_DIR/public/icons/logo-pwa.svg"
PNG_FALLBACK="$WEBUI_DIR/public/icons/icon-512.png"
if [ -f "$SVG" ] || [ -f "$PNG_FALLBACK" ]; then
  TMP="$(dirname "$WORK")"
  ICONSET="$TMP/AppIcon.iconset"
  MASTER="$TMP/master.png"
  mkdir -p "$ICONSET"
  made=0
  if [ -f "$SVG" ]; then
    sed 's|<svg |<svg width="1024" height="1024" |' "$SVG" > "$TMP/master.svg"
    if sips -s format png "$TMP/master.svg" --out "$MASTER" >/dev/null 2>&1; then
      made=1
    fi
  fi
  if [ "$made" -eq 0 ] && [ -f "$PNG_FALLBACK" ]; then
    cp "$PNG_FALLBACK" "$MASTER"
    made=1
  fi
  if [ "$made" -eq 1 ]; then
    for size in 16 32 128 256 512; do
      sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
      sips -z "$((size * 2))" "$((size * 2))" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$WORK/Contents/Resources/AppIcon.icns"
  fi
fi

# 本机自用签名，不需要开发者账号
codesign --force --sign - "$WORK" >/dev/null 2>&1 || echo "⚠️  本地签名失败，不影响自己用"

rm -rf "$APP"
mkdir -p build
ditto "$WORK" "$APP"
rm -rf "$(dirname "$WORK")"

# iCloud 会往 .app 上贴扩展属性，strict 校验会因此报 detritus，跟签名本身无关。
if codesign -dvv "$APP" 2>&1 | grep -q "Info.plist=not bound"; then
  echo "✓ $APP（只有链接器签名，本机可用）"
else
  echo "✓ $APP（已签名）"
fi
