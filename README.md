# Time Announcer

A macOS menu bar app that speaks the current time at regular intervals (every 5, 10, 15, or 30 minutes).

## Features

- **Two display modes**: Menu Bar (status item + popover) or Floating Window (always-on-top)
- **Spoken time announcements** via macOS text-to-speech
- **Nuclear audio fix**: auto-boosts system volume, compensates with amplification, detects virtual audio devices
- **Global hotkeys**: Ctrl+Shift+T (announce), Ctrl+Shift+M (mute), Ctrl+Shift+A (open)
- **Lid detection**: pauses when MacBook lid is closed
- **Configurable schedule**: active hours, all-day mode
- **Voice selection**: choose any installed macOS voice
- **Hourly chime**: optional Glass sound on the hour
- **Start at login**: launch agent support
- **Detailed logging**: full audio diagnostics for debugging

## Build

Single-file Swift — no Xcode needed:

```bash
swiftc -o TimeAnnouncer main.swift -framework AppKit -framework AVFoundation -framework IOKit
```

## Install

```bash
# Create the .app bundle
mkdir -p TimeAnnouncer.app/Contents/MacOS
cp Info.plist TimeAnnouncer.app/Contents/
cp TimeAnnouncer TimeAnnouncer.app/Contents/MacOS/

# Launch
open TimeAnnouncer.app
```

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon or Intel Mac

## License

MIT
