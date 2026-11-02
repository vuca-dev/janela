#!/bin/zsh
# Builds build.noindex/Janela.dmg, and stops if anything a release depends on fails.
set -e
set -o pipefail
cd "$(dirname "$0")/.."
./build_app.sh
.build/release/janela-render selftest scenes
if strings build.noindex/Janela.app/Contents/MacOS/Janela | grep -qE -- '--first-matte|--replay|--chrome-test'; then
  echo "test flags in the release build"; exit 1
fi
codesign -d --entitlements - build.noindex/Janela.app 2>&1 | grep -q com.apple.security.device.camera
codesign -dv build.noindex/Janela.app 2>&1 | grep -q 'runtime'
./scripts/make_dmg.sh
