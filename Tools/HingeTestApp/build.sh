#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$DIR/HingeTestApp.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE"

SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)

echo "Building HingeTestApp for iOS Simulator (SDK: $SDK_PATH)..."
swiftc \
    -target arm64-apple-ios27.2-simulator \
    -sdk "$SDK_PATH" \
    -parse-as-library \
    "$DIR/main.swift" \
    -o "$APP_BUNDLE/HingeTestApp" \
    -framework UIKit \
    -framework SwiftUI \
    -framework CoreMotion

cp "$DIR/Info.plist" "$APP_BUNDLE/Info.plist"
echo "Build complete: $APP_BUNDLE"

if [ -n "$1" ]; then
    UDID="$1"
    echo "Installing to simulator $UDID..."
    xcrun simctl install "$UDID" "$APP_BUNDLE"
    echo "Launching com.example.HingeTestApp..."
    xcrun simctl launch --terminate-running-process "$UDID" com.example.HingeTestApp
fi
