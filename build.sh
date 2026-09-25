#!/bin/bash
# Builds "Booth Check.app" as one universal app (Apple silicon + Intel, macOS 13 or later) and zips it
# for copying to the booth Mac. The finished app needs nothing installed: SwiftUI and the Swift runtime
# ship with macOS. Building it needs the Xcode Command Line Tools on this Mac only.
#
# Usage: ./build.sh        ->  build/Booth Check.app  and  build/Booth Check.zip
set -euo pipefail
cd "$(dirname "$0")"

# A Command Line Tools update can leave the default SDK newer than the compiler. Use the first SDK this
# compiler actually accepts.
pick_sdk() {
    local probe
    probe=$(mktemp -d)
    printf 'import SwiftUI\n' > "$probe/p.swift"
    for sdk in "$(xcrun --show-sdk-path 2>/dev/null)" /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
        [ -d "$sdk" ] || continue
        if swiftc -sdk "$sdk" -typecheck "$probe/p.swift" 2>/dev/null; then echo "$sdk"; rm -rf "$probe"; return; fi
    done
    rm -rf "$probe"
    echo "No SDK works with this Swift compiler." >&2
    exit 1
}
SDK=$(pick_sdk)
echo "SDK: $SDK"

APP="build/Booth Check.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -parse-as-library -sdk "$SDK" -target "$arch-apple-macos13.0" \
        BoothCheck.swift -o "build/BoothCheck-$arch"
done
lipo -create build/BoothCheck-arm64 build/BoothCheck-x86_64 -output "$APP/Contents/MacOS/BoothCheck"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -sdk "$SDK" make_icon.swift -o build/make_icon
build/make_icon build/icon_1024.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: required for the app to run on Apple silicon at all. Not a paid Developer ID, so
# the first launch on each Mac needs right-click -> Open.
codesign --force --sign - "$APP"

(cd build && ditto -c -k --keepParent "Booth Check.app" "Booth Check.zip")
rm -rf build/BoothCheck-* build/make_icon build/AppIcon.iconset build/icon_1024.png
echo "Built: $APP"
du -sh "$APP" "build/Booth Check.zip"
lipo -info "$APP/Contents/MacOS/BoothCheck"
