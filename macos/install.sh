#!/bin/bash
# ============================================================================
# CursorDrop macOS — Build & Install
#
# Run: bash install.sh
#
# Builds a native Swift app and installs it to ~/Applications/
# No dependencies required (except Xcode command line tools).
# ============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }

echo ""
echo "======================================"
echo "  CursorDrop macOS Installer"
echo "======================================"
echo ""

# Check for Xcode CLI tools
if ! xcode-select -p &>/dev/null; then
    warn "Installing Xcode command line tools..."
    xcode-select --install
    echo "Please wait for the install to finish, then run this script again."
    exit 1
fi
info "Xcode CLI tools found"

# Check for Swift
if ! command -v swift &>/dev/null; then
    err "Swift not found. Install Xcode or Xcode CLI tools."
    exit 1
fi
info "Swift found"

# Copy to a clean build directory (avoids issues with spaces/special chars in folder names)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$HOME/.cache/cursordrop-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/Sources/CursorDrop"

# Find the files wherever they are
MAIN_SWIFT=$(find "$SCRIPT_DIR" -name "main.swift" -type f 2>/dev/null | head -1)
PKG_SWIFT=$(find "$SCRIPT_DIR" -name "Package.swift" -type f 2>/dev/null | head -1)

if [ -z "$MAIN_SWIFT" ] || [ -z "$PKG_SWIFT" ]; then
    err "Could not find main.swift and Package.swift in $(basename "$SCRIPT_DIR")"
    err "Make sure install.sh, Package.swift, and main.swift are in the same folder (or subfolders)"
    exit 1
fi

cp "$PKG_SWIFT" "$BUILD_DIR/"
cp "$MAIN_SWIFT" "$BUILD_DIR/Sources/CursorDrop/"
info "Copied to clean build directory"

cd "$BUILD_DIR"

warn "Building CursorDrop..."
swift build -c release 2>&1 | tail -5

BUILD_PATH=$(swift build -c release --show-bin-path 2>/dev/null)
BINARY="$BUILD_PATH/CursorDrop"

if [ ! -f "$BINARY" ]; then
    err "Build failed — binary not found"
    exit 1
fi
info "Built successfully"

# Create .app bundle
APP_DIR="$HOME/Applications/CursorDrop.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/CursorDrop"

# Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>CursorDrop</string>
    <key>CFBundleDisplayName</key>
    <string>CursorDrop</string>
    <key>CFBundleIdentifier</key>
    <string>com.cursordrop.app</string>
    <key>CFBundleVersion</key>
    <string>1.1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
    <key>CFBundleExecutable</key>
    <string>CursorDrop</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

info "App bundle created: ~/Applications/CursorDrop.app"

# Create watch folder
mkdir -p "$HOME/CursorDrop"
info "Watch folder: ~/CursorDrop/"

# Create config dir
mkdir -p "$HOME/.config/cursordrop"

# Add to Login Items via AppleScript
osascript -e '
tell application "System Events"
    try
        delete login item "CursorDrop"
    end try
    make login item at end with properties {path:"'$APP_DIR'", hidden:false}
end tell
' 2>/dev/null && info "Added to Login Items" || warn "Could not add to Login Items (add manually in System Settings)"

# Kill existing instance if running
pkill -f "CursorDrop.app" 2>/dev/null || true
sleep 1

# Reset accessibility permission (binary hash changes on rebuild)
tccutil reset Accessibility com.cursordrop.app 2>/dev/null
info "Accessibility permission reset (will prompt on launch)"

# Launch
open "$APP_DIR"
info "CursorDrop launched"

echo ""
echo "======================================"
echo "  CursorDrop installed!"
echo "======================================"
echo ""
echo "  ⚠  Grant Accessibility access when prompted"
echo "     (or: System Settings → Privacy & Security → Accessibility)"
echo ""
echo "  Usage:"
echo "    • Drag files onto the floating pill"
echo "    • Ctrl+Cmd+V to paste clipboard"
echo "    • ~/CursorDrop/ — watch folder for LocalSend"
echo "    • Right-click pill for settings"
echo "    • ⬆ menubar icon to paste"
echo ""
echo "  Optional: brew install ffmpeg (for video frame extraction)"
echo ""
