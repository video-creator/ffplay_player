#!/bin/bash
# Build Flutter macOS app for arm64 architecture

set -e

# Navigate to the example/macos directory
cd "$(dirname "$0")/example/macos"

# Build using xcodebuild with arm64 architecture
echo "Building for arm64..."
xcodebuild -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build \
    build

echo ""
echo "Build successful!"
echo "App location: $(pwd)/build/Build/Products/Debug/ffplay_player_example.app"
echo ""
echo "To run: open build/Build/Products/Debug/ffplay_player_example.app"
