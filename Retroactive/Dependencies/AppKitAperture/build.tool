#!/bin/bash
# Builds AppKitShim, the AppKit reexport that supplies the link symbols macOS stripped for
# NSFlippableView / NSRegion / NSToolbarClippedItemsIndicator (used by ProKit). The output drops
# into the patched app at Contents/Frameworks/AppKit.framework/Versions/C/AppKit; its install
# name uses Versions/A so it never dedups against the real AppKit (Versions/C).
set -e
cd "$(dirname "$0")"
OUT=../../Support/AppKitAperture
rm -rf "$OUT"
mkdir -p "$OUT/Versions/C"
clang -arch x86_64 -dynamiclib AppKitAperture.m \
  -framework AppKit -framework Foundation \
  -Xlinker -reexport_framework -Xlinker AppKit \
  -install_name /System/Library/Frameworks/AppKit.framework/Versions/A/AppKit \
  -Xlinker -alias -Xlinker '_OBJC_CLASS_$_RetroFlippableView'              -Xlinker '_OBJC_CLASS_$_NSFlippableView' \
  -Xlinker -alias -Xlinker '_OBJC_CLASS_$_RetroRegion'                     -Xlinker '_OBJC_CLASS_$_NSRegion' \
  -Xlinker -alias -Xlinker '_OBJC_CLASS_$_RetroToolbarClippedItemsIndicator'    -Xlinker '_OBJC_CLASS_$_NSToolbarClippedItemsIndicator' \
  -Xlinker -alias -Xlinker '_OBJC_METACLASS_$_RetroToolbarClippedItemsIndicator' -Xlinker '_OBJC_METACLASS_$_NSToolbarClippedItemsIndicator' \
  -o "$OUT/Versions/C/AppKit"
codesign -fs - "$OUT/Versions/C/AppKit"
echo "Built $OUT/Versions/C/AppKit"
