#!/bin/zsh
# Builds and ad-hoc signs ./build/Janela.app
set -e
cd "$(dirname "$0")"
# JANELA_TEST=1 builds a test copy with replay and demo options. Never ship that build.
FLAGS=(); [ -n "$JANELA_TEST" ] && FLAGS=(-Xswiftc -DJANELA_TEST)
swift build -c release --product Janela "${FLAGS[@]}"
swift build -c release --product janela-render
A=build.noindex/Janela.app; rm -rf $A; mkdir -p $A/Contents/{MacOS,Resources}
cp .build/release/Janela $A/Contents/MacOS/
strip -x $A/Contents/MacOS/Janela
.build/release/janela-render compile Resources/rvm.mlpackage $A/Contents/Resources/rvm.mlmodelc
cp -R scenes $A/Contents/Resources/scenes
cp assets/Janela.icns $A/Contents/Resources/Janela.icns
cat > $A/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.vuca-dev.janela</string><key>CFBundleName</key><string>Janela</string><key>CFBundleIconFile</key><string>Janela</string>
<key>CFBundleExecutable</key><string>Janela</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string><key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/>
<key>NSCameraUsageDescription</key><string>Janela places you in your background. Video stays on this Mac.</string>
</dict></plist>
P
codesign --force --options runtime --entitlements Janela.entitlements -s - $A
du -sh $A
