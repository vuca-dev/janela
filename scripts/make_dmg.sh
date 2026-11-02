#!/bin/zsh
# Packages build.noindex/Janela.app as build.noindex/Janela.dmg, with an Applications shortcut.
set -e
cd "$(dirname "$0")/.."
A=build.noindex/Janela.app; D=build.noindex/Janela.dmg
codesign --verify --strict --deep $A
S=$(mktemp -d); trap 'rm -rf $S' EXIT
ditto $A $S/Janela.app
ln -s /Applications $S/Applications
rm -f $D
hdiutil create -volname Janela -srcfolder $S -fs HFS+ -format UDZO -ov $D -quiet
hdiutil verify $D -quiet
shasum -a 256 $D
