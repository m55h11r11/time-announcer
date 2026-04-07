#!/bin/bash
# Time Announcer — one-command install for macOS
set -e

echo "🕐 Installing Time Announcer..."

# Download source
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
curl -sL https://raw.githubusercontent.com/m55h11r11/time-announcer/main/main.swift -o main.swift
curl -sL https://raw.githubusercontent.com/m55h11r11/time-announcer/main/Info.plist -o Info.plist

# Compile
echo "⚙️  Compiling..."
swiftc -o TimeAnnouncer main.swift -framework AppKit -framework AVFoundation -framework IOKit

# Create .app bundle in /Applications
APP_DIR="$HOME/Applications/TimeAnnouncer.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp TimeAnnouncer "$APP_DIR/Contents/MacOS/"
cp Info.plist "$APP_DIR/Contents/"

# Clean up
rm -rf "$TMPDIR"

echo "✅ Installed to $APP_DIR"
echo "🚀 Launching..."
open "$APP_DIR"
