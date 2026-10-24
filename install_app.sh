#!/usr/bin/env bash
# install_app.sh — 編譯 → 結束舊的 → 換掉 /Applications/PodDigest.app → 打開
set -euo pipefail
cd "$(dirname "$0")"
./build_app.sh
if pgrep -x PodDigest >/dev/null 2>&1; then
  echo "[install] 結束執行中的 PodDigest…"
  osascript -e 'quit app "PodDigest"' >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do pgrep -x PodDigest >/dev/null 2>&1 || break; sleep 1; done
  pgrep -x PodDigest >/dev/null 2>&1 && { echo "[install] ⚠️ PodDigest 還沒結束，請手動結束後再跑一次"; exit 1; }
fi
rm -rf /Applications/PodDigest.app
cp -R build/PodDigest.app /Applications/
open /Applications/PodDigest.app
sleep 3
pgrep -x PodDigest >/dev/null 2>&1 && echo "[install] ✅ 已安裝並打開 /Applications/PodDigest.app" \
  || { echo "[install] ⚠️ App 沒有在運行"; exit 1; }
