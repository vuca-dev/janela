#!/bin/zsh
# Builds build.noindex/Janela.dmg, and stops if anything a release depends on fails.
set -e
set -o pipefail
cd "$(dirname "$0")/.."
./build_app.sh
.build/release/janela-render selftest scenes
A=build.noindex/Janela.app
# Whole outputs are held in variables: grep -q in a pipe can fail under pipefail by closing it early.
flags=$(strings $A/Contents/MacOS/Janela)
if [[ $flags == *--first-matte* || $flags == *--replay* || $flags == *--chrome-test* ]]; then
  echo "test flags in the release build"; exit 1
fi
sig=$(codesign -dv --entitlements - $A 2>&1)
[[ $sig == *com.apple.security.device.camera* ]] || { echo "camera entitlement missing"; exit 1; }
[[ $sig == *runtime* ]] || { echo "hardened runtime missing"; exit 1; }
./scripts/make_dmg.sh
