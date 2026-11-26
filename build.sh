#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")" && pwd)"
"$project/fetch-video-dependencies.sh" mac
bundle="$project/dist/iPlex.app"
frameworks="$bundle/Contents/Frameworks"
mkdir -p "$frameworks"
kit="$project/Dependencies/VLCKit.xcframework/macos-arm64_x86_64"
# Existing updaters reject symlinks. The VLCKit Mach-O has no runtime framework resources.
rm -rf "$frameworks/VLCKit.framework"
library="$frameworks/libVLCKit.dylib"
cp "$kit/VLCKit.framework/Versions/A/VLCKit" "$library"
install_name_tool -id @rpath/libVLCKit.dylib "$library"
codesign --force --sign - "$library"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$project/Info.plist" "$bundle/Contents/Info.plist"
for asset in "$project"/Assets/*.png "$project"/Assets/*.icns; do
    if [[ -f "$asset" ]]; then cp "$asset" "$bundle/Contents/Resources/"; fi
done
ditto --norsrc --noextattr --noqtn "$project/Assets/HeaderMarks" "$bundle/Contents/Resources/HeaderMarks"
ditto --norsrc --noextattr --noqtn "$project/Assets/GlassBackgrounds" "$bundle/Contents/Resources/GlassBackgrounds"
cp "$project"/Assets/VideoLAN-*.txt "$bundle/Contents/Resources/"
cp "$project/Assets/install-update.sh" "$bundle/Contents/Resources/install-update.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
for architecture in arm64 x86_64; do
    xcrun swiftc -parse-as-library -O -target "$architecture-apple-macosx14.0" \
        -F "$kit" -L "$frameworks" -lVLCKit -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        "$project"/Sources/*.swift -o "$scratch/iPlex-$architecture"
done
lipo -create "$scratch/iPlex-arm64" "$scratch/iPlex-x86_64" -output "$bundle/Contents/MacOS/iPlex"
codesign --force --sign - "$bundle"

codesign --verify --deep --strict "$bundle"
