#!/bin/zsh
# Reproduces the first-call figures in README.md: scripts/first-matte.sh [runs]
#
# Times prepare() to the first matte frame in a fresh test-build process. Uses no camera, sink or
# instance lock, so it's safe beside a running Janela. It excludes the wait for a reader to be
# noticed and for the camera to start. Each run gets its own bundle ID and home, because macOS
# caches the prepared model and shaders per app, which is the only way back to a true cold start.
set -e
cd "$(dirname "$0")/.."
runs=${1:-5}
work=$PWD/build.noindex/first-matte
JANELA_TEST=1 ./build_app.sh > /dev/null 2>&1

trial() {  # trial <name>: prepares a private copy and sets $exe, $home_dir
  local dir=$work/$1 id=io.github.vuca-dev.janela-fm-$$-$1
  ids+=($id)
  mkdir -p "$dir/home"; cp -R build.noindex/Janela.app "$dir/"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$dir/Janela.app/Contents/Info.plist"
  codesign --force --options runtime --entitlements Janela.entitlements -s - "$dir/Janela.app" 2> /dev/null
  exe=$dir/Janela.app/Contents/MacOS/Janela; home_dir=$dir/home
}

ids=()
cleanup() {
  rm -rf "$work"
  for id in $ids; do rm -rf "$(getconf DARWIN_USER_CACHE_DIR)$id" "$HOME/Library/Caches/$id"; done
}
trap cleanup EXIT

for i in $(seq 1 $runs); do
  trial c$i; echo "cold:       $(CFFIXED_USER_HOME=$home_dir "$exe" --first-matte)"
  trial w$i
  start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  CFFIXED_USER_HOME=$home_dir "$exe" --warm-caches
  took=$(perl -MTime::HiRes=time -e "printf '%.1f', time - $start")
  echo "after helper ($took s): $(CFFIXED_USER_HOME=$home_dir "$exe" --first-matte)"
done
