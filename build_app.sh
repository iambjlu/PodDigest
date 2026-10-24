#!/usr/bin/env bash
# build_app.sh — 用 Xcode 命令列工具（swiftc）打包 PodDigest.app，不需要開 Xcode
set -euo pipefail
cd "$(dirname "$0")"
OUT="build/PodDigest.app"
ARCH="$(uname -m)"

command -v swiftc >/dev/null 2>&1 || { echo "找不到 swiftc，請先執行：xcode-select --install"; exit 1; }

echo "[build] 編譯 PodDigest.app（$ARCH, macOS 14+）"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" build
if ! swiftc -O -swift-version 5 -parse-as-library -target "$ARCH-apple-macos14.0" \
      app/*.swift -o "$OUT/Contents/MacOS/PodDigest" 2> build/.build.log; then
  echo "[build] ❌ 編譯失敗，完整錯誤在 build/.build.log："
  head -40 build/.build.log
  exit 1
fi

# 內建 yt-dlp：App 搬到哪都能下載 YouTube（vendor/yt-dlp 不在就跳過，設定頁可再下載）
mkdir -p "$OUT/Contents/Resources/bin"
if [ -x vendor/yt-dlp ]; then
  cp vendor/yt-dlp "$OUT/Contents/Resources/bin/yt-dlp"
else
  echo "[build] ⚠️ 找不到 vendor/yt-dlp，App 不會內建 yt-dlp（見 README）"
fi

ICON="build/AppIcon.icns"
if [ ! -f "$ICON" ] || [ tools/make_icon.swift -nt "$ICON" ]; then
  TMP="$(mktemp -d)"
  if swift tools/make_icon.swift "$TMP/icon.png" >/dev/null 2>&1; then
    mkdir -p "$TMP/AppIcon.iconset"
    for s in 16 32 128 256 512; do
      sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
      sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$TMP/AppIcon.iconset" -o "$ICON" || echo "[build] ⚠️ 圖示產生失敗（Dock 會顯示預設圖示）"
  else
    echo "[build] ⚠️ 圖示產生失敗（Dock 會顯示預設圖示）"
  fi
  rm -rf "$TMP"
fi
[ -f "$ICON" ] && cp "$ICON" "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>tw.iambjlu.PodDigest</string>
  <key>CFBundleName</key><string>PodDigest</string>
  <key>CFBundleDisplayName</key><string>PodDigest</string>
  <key>CFBundleExecutable</key><string>PodDigest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force -s - "$OUT/Contents/Resources/bin/yt-dlp" >/dev/null 2>&1 || true
codesign --force --deep -s - "$OUT" >/dev/null 2>&1 || echo "[build] ⚠️ 簽章失敗（不影響在本機執行）"
echo "[build] ✅ 完成：$OUT"
echo "安裝：./install_app.sh（會結束舊版、換掉 /Applications/PodDigest.app 並打開）"
