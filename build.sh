#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")" && pwd)"
bundle="$project/dist/iPlex.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$project/Info.plist" "$bundle/Contents/Info.plist"
for asset in "$project"/Assets/*.png "$project"/Assets/*.icns; do
    if [[ -f "$asset" ]]; then cp "$asset" "$bundle/Contents/Resources/"; fi
done
ditto --norsrc --noextattr --noqtn "$project/Assets/HeaderMarks" "$bundle/Contents/Resources/HeaderMarks"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
for architecture in arm64 x86_64; do
    xcrun swiftc -parse-as-library -O -target "$architecture-apple-macosx14.0" \
        "$project"/Sources/*.swift -o "$scratch/iPlex-$architecture"
done
lipo -create "$scratch/iPlex-arm64" "$scratch/iPlex-x86_64" -output "$bundle/Contents/MacOS/iPlex"
codesign --force --sign - "$bundle"
