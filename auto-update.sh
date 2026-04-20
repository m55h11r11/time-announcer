#!/bin/bash
# Auto-update TimeAnnouncer from origin/main.
# Polls git, builds if new commits, replaces running app.
# Invoked by launchd every 60s.

set -e

REPO="/Users/mshrmnsr/claude1/time announcer"
LOG="$REPO/auto-update.log"

cd "$REPO"

# Fetch silently
git fetch origin main --quiet 2>>"$LOG"

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" = "$REMOTE" ]; then
  # No new commits
  exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] New commits detected: ${LOCAL:0:7} -> ${REMOTE:0:7}" >> "$LOG"

# Pull
git pull --ff-only origin main >>"$LOG" 2>&1

# Build
cd TimeAnnouncerBuild
if swiftc -o TimeAnnouncer main.swift \
  -framework AppKit -framework AVFoundation \
  -framework IOKit -framework CoreAudio 2>>"$LOG"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Build OK" >> "$LOG"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] BUILD FAILED — keeping old version" >> "$LOG"
  exit 1
fi

# Kill running app, swap binary, relaunch
pkill -f "TimeAnnouncer.app/Contents/MacOS/TimeAnnouncer" 2>/dev/null || true
sleep 1
cp TimeAnnouncer "../TimeAnnouncer.app/Contents/MacOS/TimeAnnouncer"
open "../TimeAnnouncer.app"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installed and relaunched" >> "$LOG"

# Optional: Telegram notification
if [ -x "$HOME/assistant/scripts/telegram-notify.sh" ]; then
  "$HOME/assistant/scripts/telegram-notify.sh" "TimeAnnouncer auto-updated to ${REMOTE:0:7}" || true
fi
