#!/bin/sh
set -eu

cd "$(dirname "$0")" || exit 1
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build --sdk "$SDK" -Xswiftc -target -Xswiftc arm64-apple-ios13.0-simulator > /tmp/bods_build.log 2>&1
echo "BODragScroll simulator build succeeded"
