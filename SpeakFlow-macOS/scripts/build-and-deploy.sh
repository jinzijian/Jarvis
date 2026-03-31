#!/bin/bash
set -euo pipefail

# Build SpeakFlow and deploy to /Applications.
#
# Uses the "SpeakFlow Dev" self-signed certificate from Keychain.
# NOTE: Self-signed certs don't have a TeamIdentifier, so macOS TCC tracks
# permissions by CDHash. Every rebuild that changes the binary will reset
# permissions (microphone, screen recording, accessibility). The script
# detects this and reminds you to re-grant. The real fix is an Apple
# Developer certificate ($99/yr) which gives a stable TeamIdentifier.
#
# Usage:
#   ./scripts/build-and-deploy.sh          # Release build + deploy
#   ./scripts/build-and-deploy.sh build    # Build only
#   ./scripts/build-and-deploy.sh deploy   # Deploy only (uses last build)

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="SpeakFlow"
CONFIG="Release"
DERIVED_DATA="$REPO_DIR/build"
BUILD_DIR="$DERIVED_DATA/Build/Products/$CONFIG"
APP_NAME="SpeakFlow.app"
DEST="/Applications/$APP_NAME"

build() {
    echo "==> Generating Xcode project..."
    cd "$REPO_DIR"
    xcodegen generate 2>/dev/null || true

    echo "==> Building $SCHEME ($CONFIG)..."
    xcodebuild \
        -project "$REPO_DIR/SpeakFlow.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGN_IDENTITY="SpeakFlow Dev" \
        build | tail -5

    echo "==> Build complete: $BUILD_DIR/$APP_NAME"
}

deploy() {
    local src="$BUILD_DIR/$APP_NAME"

    if [ ! -d "$src" ]; then
        echo "ERROR: No build found at $src — run build first."
        exit 1
    fi

    # Check if binary actually changed
    local needs_permission_reset=false
    if [ -d "$DEST" ]; then
        local old_hash new_hash
        old_hash=$(codesign -dv --verbose=4 "$DEST" 2>&1 | grep "^CDHash=" | cut -d= -f2 || true)
        new_hash=$(codesign -dv --verbose=4 "$src" 2>&1 | grep "^CDHash=" | cut -d= -f2 || true)
        if [ "$old_hash" != "$new_hash" ]; then
            needs_permission_reset=true
        fi
    else
        needs_permission_reset=true
    fi

    if [ ! -d "$DEST" ]; then
        echo "==> First install: copying to $DEST"
        cp -R "$src" "$DEST"
    else
        echo "==> Updating $DEST in-place..."
        rsync -a --delete "$src/" "$DEST/"
    fi

    echo "==> Deployed to $DEST"

    if $needs_permission_reset; then
        echo ""
        echo "========================================="
        echo "  ⚠  Ad-hoc signing: CDHash changed."
        echo "  You need to re-grant permissions:"
        echo ""
        echo "  System Settings → Privacy & Security →"
        echo "    • Microphone → enable SpeakFlow"
        echo "    • Screen Recording → enable SpeakFlow"
        echo "    • Accessibility → enable SpeakFlow"
        echo "    • App Management → enable SpeakFlow"
        echo "========================================="
        echo ""
        echo "  Tip: Get an Apple Developer certificate"
        echo "  to avoid this on every rebuild."
        echo "========================================="

        # Open System Settings to the right page
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null || true
    fi
}

run() {
    local src="$BUILD_DIR/$APP_NAME"
    if [ ! -d "$src" ]; then
        echo "ERROR: No build found at $src — run build first."
        exit 1
    fi
    echo "==> Running from build directory (no deploy, no permission reset)..."
    open "$src"
}

case "${1:-all}" in
    build)  build ;;
    deploy) deploy ;;
    run)    build && run ;;
    all)    build && deploy ;;
    *)      echo "Usage: $0 [build|deploy|run|all]"
            echo "  build   - Build only"
            echo "  deploy  - Deploy to /Applications (will reset permissions)"
            echo "  run     - Build + run from build dir (no permission reset)"
            echo "  all     - Build + deploy to /Applications"
            exit 1 ;;
esac
