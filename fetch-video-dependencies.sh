#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")" && pwd)"
destination="$project/Dependencies"
mkdir -p "$destination"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mode="${1:-all}"
case "$mode" in all|apple|mac|windows) ;; *) echo "Usage: $0 [all|apple|mac|windows]" >&2; exit 2 ;; esac

fetch() {
    local url="$1" file="$2" digest="$3"
    curl --fail --location --retry 2 --output "$file" "$url"
    printf '%s  %s\n' "$digest" "$file" | shasum -a 256 -c -
}

apple() {
    local product="$1" digest="$2" archive="$scratch/$1.tar.xz"
    if [[ -d "$destination/$product.xcframework" && -f "$destination/VLCKit-LICENSE.txt" ]]; then return; fi
    fetch "https://download.videolan.org/cocoapods/prod/$product-3.7.3-319ed2c0-79128878.tar.xz" "$archive" "$digest"
    mkdir -p "$scratch/$product"
    tar -xf "$archive" -C "$scratch/$product"
    local framework=("$scratch/$product/"*"/$product.xcframework")
    local license=("$scratch/$product/"*"/COPYING.txt")
    cp "${license[0]}" "$destination/VLCKit-LICENSE.txt"
    ditto "${framework[0]}" "$destination/$product.xcframework"
}

if [[ "$mode" != windows ]]; then
    apple VLCKit 019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d
    if [[ "$mode" != mac ]]; then
        apple MobileVLCKit 0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9
        apple TVVLCKit b5f90c226ed54d9dc1c03901c60dc7749b74a53caace2c3047e4c0b7a063e46c
    fi
fi
if [[ "$mode" == all || "$mode" == windows ]]; then
    package="$destination/VideoLAN.LibVLC.Windows.3.0.24.nupkg"
    if [[ ! -f "$package" ]]; then
        fetch "https://api.nuget.org/v3-flatcontainer/videolan.libvlc.windows/3.0.24/videolan.libvlc.windows.3.0.24.nupkg" \
            "$scratch/Windows.nupkg" 3da3f37ee2b2b10e5c788d830a3b513658c36521ea1b0f966ed86eb69f41ef3c
        mv "$scratch/Windows.nupkg" "$package"
    fi
fi
