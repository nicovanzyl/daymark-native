#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/Daymark.app"
staging="$(mktemp -d "${TMPDIR:-/tmp}/daymark.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Daymark.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Info.plist "$bundle/Contents/Info.plist"
cp schedule-fixtures.json "$bundle/Contents/Resources/"
swiftc_bin="$(xcrun --find swiftc)"
"$swiftc_bin" -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$staging/module-cache" -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -warnings-as-errors -O \
    -parse-as-library Sources/*.swift -o "$bundle/Contents/MacOS/Daymark"
plutil -lint "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
"$bundle/Contents/MacOS/Daymark" --self-test
mkdir -p "$app"
/usr/bin/ditto "$bundle" "$app"
/usr/bin/codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
