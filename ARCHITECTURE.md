# TimeAnnouncer — Architecture Reference

> **Maintenance rule**: Every time `main.swift` is modified, this file must be updated in the same session.
> This is the single source of truth for understanding the codebase.
>
> **Baseline**: v4.4 — `TimeAnnouncerBuild/main.swift` (2144 lines)

---

## Table of Contents

1. [App Identity](#1-app-identity)
2. [File & Directory Structure](#2-file--directory-structure)
3. [Class & Type Inventory](#3-class--type-inventory)
4. [State Model](#4-state-model)
5. [UI Architecture](#5-ui-architecture)
6. [Threading Model](#6-threading-model)
7. [Audio Pipeline](#7-audio-pipeline)
8. [Timer System](#8-timer-system)
9. [Hotkey System](#9-hotkey-system)
10. [Lid Detection](#10-lid-detection)
11. [Launch at Login](#11-launch-at-login)
12. [Log System](#12-log-system)
13. [External Dependencies](#13-external-dependencies)
14. [Known Limitations & Improvement Opportunities](#14-known-limitations--improvement-opportunities)

---

## 1. App Identity

| Property | Value |
|----------|-------|
| **Name** | Time Announcer |
| **Version** | v4.4 |
| **Bundle ID** | `com.mshrmnsr.timeannouncer` |
| **LaunchAgent label** | `com.mshrmnsr.timeannouncer` |
| **macOS target** | macOS 11+ (uses `kIOMainPortDefault`, `kAudioObjectPropertyElementMain`) |
| **Language** | Swift (single-file, no Xcode project) |
| **Architecture** | Single `main.swift` compiled with `swiftc` — no SPM, no Xcode |

**Build command:**
```bash
pkill -f TimeAnnouncer; sleep 1
cd "/Users/mshrmnsr/claude1/time announcer/TimeAnnouncerBuild"
swiftc -o TimeAnnouncer main.swift \
    -framework AppKit \
    -framework AVFoundation \
    -framework IOKit \
    -framework CoreAudio
cp TimeAnnouncer "../TimeAnnouncer.app/Contents/MacOS/TimeAnnouncer"
open "../TimeAnnouncer.app"
```

**What the app does:** Announces the current time at configurable intervals (5/10/15/30 min) using the macOS `say` command, with a pre-speech chime. Designed for ADHD time-blindness. Runs silently in the menu bar or as a floating HUD panel.

---

## 2. File & Directory Structure

```
/Users/mshrmnsr/claude1/time announcer/
├── TimeAnnouncer.app/
│   └── Contents/
│       ├── Info.plist                    — Bundle metadata (LSUIElement=YES hides from Dock)
│       └── MacOS/
│           └── TimeAnnouncer             — Compiled binary (copied from Build/)
├── TimeAnnouncerBuild/
│   ├── main.swift                        — Entire application source (~2144 lines)
│   └── announcer.log                     — Runtime log (created on first launch, appended)
├── ARCHITECTURE.md                       — This file
└── install.sh                            — Optional install script
```

**Key paths at runtime:**
- Log file: resolved relative to the running binary's `.app` bundle at startup (lines 9–23)
  - Formula: `{parent of .app}/TimeAnnouncerBuild/announcer.log`
  - Fallback: next to the binary itself
- LaunchAgent: `~/Library/LaunchAgents/com.mshrmnsr.timeannouncer.plist`
- Temp AIFF: `NSTemporaryDirectory() + "timeannouncer_speech.aiff"` (created + deleted per announcement)

---

## 3. Class & Type Inventory

### Top-level free functions (lines 1–177)

| Function | Lines | Purpose |
|----------|-------|---------|
| `logPath` (computed let) | 9–23 | Resolves log file path at launch |
| `logTimestampFormatter` | 25–29 | ISO 8601 with fractional seconds (reused) |
| `logEvent(_:)` | 31–42 | Appends a timestamped line to `announcer.log` via `logQueue` |
| `isLidClosed()` | 46–54 | Queries IOKit `IOPMrootDomain` for `AppleClamshellState` |
| `logQueue` | 58 | Serial `DispatchQueue` for thread-safe log writes |
| `caGetDefaultOutputDevice()` | 63–73 | CoreAudio: returns current default output device ID |
| `caGetDeviceName(_:)` | 76–88 | CoreAudio: returns display name of a device |
| `caGetTransportType(_:)` | 91–101 | CoreAudio: returns transport type (built-in / USB / BT / virtual) |
| `caGetDeviceVolume(_:)` | 104–114 | CoreAudio: returns output volume 0.0–1.0 (-1 if unsupported) |
| `caIsOutputMuted(_:)` | 117–127 | CoreAudio: checks hardware mute state |
| `caFindBuiltInSpeakers()` | 130–157 | Enumerates all audio devices to find built-in output |
| `caSetDefaultOutputDevice(_:)` | 160–170 | CoreAudio: sets the default output device |

### Enum (line 174)

```swift
enum DisplayMode: String {
    case menuBar = "menuBar"           // NSStatusItem + NSPopover
    case floatingWindow = "floatingWindow"  // NSPanel (always-on-top HUD)
}
```

### Class: `AppDelegate` (line 181)

Conforms to: `NSObject`, `NSApplicationDelegate`, `NSWindowDelegate`, `AVSpeechSynthesizerDelegate`, `NSPopoverDelegate`

**Key methods by MARK section:**

| MARK | Lines (approx.) | Key methods |
|------|----------------|-------------|
| App Launch | 291–328 | `applicationDidFinishLaunching` — full initialization sequence |
| Preferences | 361–401 | `loadPreferences()`, `savePreference(_:value:)` |
| Build Window | 403–968 | `buildWindow()` — programmatic NSWindow + 3-tab NSTabView |
| Log Refresh | 970–999 | `startLogRefreshTimer()` |
| Menu Bar | 1000–1224 | `setupMenuBarMode()`, `togglePopover(_:)` |
| Settings Window | 1195–1225 | `openSettingsWindow()` |
| Floating Window | 1225–1360 | `setupFloatingMode()` — NSPanel HUD with hover transparency |
| Mode Switching | 1361–1388 | `switchDisplayMode(to:)` |
| UI Update | 1405–1547 | `startUIUpdateTimer()`, `refreshUI()` (includes smart status-bar label since v4.4) |
| Scheduling | 1549–1585 | `scheduleNextAnnouncement()` — primary DispatchSourceTimer |
| Watchdog | 1587–1678 | `startWatchdog()`, `startBackupWatchdog()`, `watchdogTick()`, `registerLidNotification()`, `handlePowerNotification()` |
| Hotkeys | 1679–1728 | `registerGlobalHotkey()`, `handleHotkeyEvent(_:)` |
| Speech | 1730–1956 | `speakTime()`, `announceNowAction()`, `getAudioState()`, `speak(_:)` |
| Screen Sleep | 1958–1973 | `screenDidSleep()`, `screenDidWake()` |
| Actions | 1975–2107 | `toggleEnabled()`, `muteFor(minutes:)`, `unmuteAction()`, launch-at-login helpers, etc. |
| Cleanup | 2108–2127 | `applicationWillTerminate(_:)` — releases all resources |

### Bootstrap (lines 2129–2144)

```swift
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Build main menu (Cmd+Q)
app.run()
```

---

## 4. State Model

### UserDefaults Keys

All keys use `UserDefaults.standard`. Loaded in `loadPreferences()` (line 363), saved individually via `savePreference(_:value:)` (line 395).

| Key | Swift Type | Default | Description |
|-----|-----------|---------|-------------|
| `TAIntervalMinutes` | `Int` | `5` | Announcement interval (5, 10, 15, or 30 min) |
| `TAActiveStartHour` | `Int` | `7` | Active hours start (0–23, 24h) |
| `TAActiveEndHour` | `Int` | `23` | Active hours end (0–23, 24h) |
| `TAVoiceIdentifier` | `String?` | `nil` | AVSpeechSynthesisVoice identifier |
| `TAVoiceName` | `String?` | `nil` | Human-readable voice name (for `say -v`) |
| `TAHourlyChime` | `Bool` | `true` | Play Tink.aiff at top-of-hour before speaking |
| `TAChimeVolume` | `Float` | `2.5` | Pre-speech Glass.aiff volume (afplay -v scale: 0=off, 2.5=loud) |
| `TAAllDay` | `Bool` | `true` | Ignore active hours window (speak 24/7) |
| `TAVolume` | `Int` | `100` | App speech volume 0–100 (stored as %, converted to 0.0–1.0) |
| `TAHotkeyAnnounce` | `String` | `"t"` | Letter for Ctrl+Shift+? to trigger announcement |
| `TAHotkeyMute` | `String` | `"m"` | Letter for Ctrl+Shift+? to toggle mute (15 min) |
| `TAHotkeyOpen` | `String` | `"a"` | Letter for Ctrl+Shift+? to open UI |
| `TADisplayMode` | `String` | `"menuBar"` | `DisplayMode.rawValue` — persists between launches |

### Runtime Properties (not persisted)

| Property | Type | Description |
|----------|------|-------------|
| `lastAnnouncedSlot` | `String?` | `"HH:MM"` slot key — prevents duplicate announcements |
| `screenAwake` | `Bool` | Set by `NSWorkspace.screensDidSleep/Wake` notifications |
| `lidOpen` | `Bool` | Current clamshell state (polled + IOKit notification) |
| `enabled` | `Bool` | Master on/off toggle |
| `isMuted` | `Bool` | Temporary mute state |
| `muteEndDate` | `Date?` | When the mute timer expires |
| `sayProcess` | `Process?` | Currently running `say` or `afplay` process (for termination) |
| `recordingHotkeyFor` | `String?` | `"announce"/"mute"/"open"` while capturing a new hotkey |

### Computed Properties

```swift
var inActiveHours: Bool {
    if allDayEnabled { return true }
    // Handles overnight ranges (e.g. 22:00–06:00) correctly
    if activeStartHour <= activeEndHour {
        return hour >= activeStartHour && hour < activeEndHour
    } else {
        return hour >= activeStartHour || hour < activeEndHour
    }
}

var canSpeak: Bool {
    return enabled && !isMuted && screenAwake && lidOpen && inActiveHours
}
```

---

## 5. UI Architecture

### Main Settings Window (always built, shown on demand)

- **Size**: 360 × 580 pt, `.titled + .closable + .miniaturizable`
- **3 tabs via NSTabView**:

| Tab | Contents |
|-----|----------|
| **Main** | Status label, next-announce countdown, lid indicator, Enable/Disable button, Announce Now button, volume slider (0–100%), mute duration popup, Mute/Unmute buttons, mute-remaining label |
| **Settings** | Interval popup (5/10/15/30 min), All Day checkbox, Start/End hour popups, Voice popup (populated from AVSpeechSynthesisVoice.speechVoices()), Hourly chime checkbox, Chime volume slider, Start at Login checkbox, Hotkey buttons (Ctrl+Shift+?) for announce/mute/open, Display Mode segmented control |
| **Log** | NSScrollView + NSTextView (monospace) showing last N lines from announcer.log, auto-refreshed every 5s |

- **Menu bar mode behavior**: Window hides itself (`window.orderOut(nil)`) when popover opens/closes. Returns to `.accessory` activation policy when window closes.
- **Floating mode behavior**: Settings window is shown via `openSettingsWindow()` when Dock icon is clicked or hotkey triggers.

### Menu Bar Mode (`.menuBar`)

- **NSStatusItem** with `NSStatusBar.system.statusItem(withLength: .variableLength)`
- **Smart countdown title** (updated every 1 s in `refreshUI()`):

  | State | Label |
  |-------|-------|
  | Active, speaking allowed | `⏰ 4m` — minutes until next announcement (rounded up). Shows `⏰ <1m` in the final minute. |
  | Muted (temporary) | `🔇 3m` — minutes of mute remaining. Falls back to `🔇` if `muteEndDate` is `nil`. |
  | Disabled (master switch off) | `⏸` |
  | Lid closed | `💤` |
  | Outside active hours | `😴` |

  Button uses a monospaced-digit font so the width doesn't jitter as the count decrements. The title is only reassigned when it changes, to avoid unnecessary redraws.
- **NSPopover** (transient behavior) contains the full 3-tab settings window content
- Shown/hidden via `togglePopover(_:)` — triggered by status bar click or Ctrl+Shift+A hotkey
- App activation policy: `.accessory` (no Dock icon) when popover is closed

### Floating Window Mode (`.floatingWindow`)

- **NSPanel** with `.nonactivatingPanel + .hudWindow + .utilityWindow`
- **Level**: `.floating` — always on top
- **Content**: Minimal HUD — current time (large), next-announcement countdown (small), status dot (green=active / red=muted or off)
- **Hover transparency**: Fully opaque when mouse hovers, semi-transparent otherwise (`alphaValue` animation via `NSTrackingArea`)
- **Position**: Draggable, position not persisted between sessions
- **Settings access**: Ctrl+Shift+A opens the full settings window as a separate panel

---

## 6. Threading Model

### Threads & Queues

| Queue / Thread | Type | Purpose |
|---------------|------|---------|
| **Main thread** | OS main queue | All UI, NSTimer callbacks, IOKit notifications, timer event handlers, `speakTime()` entry |
| **`speechQueue`** | Serial `DispatchQueue` (`.userInitiated`) | All blocking speech operations: `getAudioState()`, osascript, `say` render, `afplay` playback |
| **`logQueue`** | Serial `DispatchQueue` (default QoS) | `FileHandle` writes to `announcer.log` — prevents corruption from concurrent writes |
| **`backupWatchdog`** | `DispatchSource` on global utility queue | 7s backup timer — dispatches `watchdogTick()` back to main thread |

### 6 Timers

| Timer | Type | Interval | Purpose |
|-------|------|----------|---------|
| `primaryTimer` | `DispatchSourceTimer` | Computed to next slot | Fires exactly at announcement boundary (wall-clock aligned) |
| `watchdogTimer` | `NSTimer` (RunLoop `.common`) | 5 s | Polls lid state, catches missed announcements within grace window |
| `backupWatchdog` | `DispatchSourceTimer` | 7 s | Independent timer — backs up `watchdogTimer` in case RunLoop stalls |
| `muteTimer` | `NSTimer` | Fires at `muteEndDate` | Clears `isMuted` when temporary mute expires |
| `uiUpdateTimer` | `NSTimer` | 1 s | Updates the next-announce countdown and floating panel display |
| `logRefreshTimer` | `NSTimer` | 5 s | Re-reads `announcer.log` into the Log tab NSTextView |

**Timer setup sequence** (called from `applicationDidFinishLaunching`):
1. `scheduleNextAnnouncement()` — starts `primaryTimer`
2. `startWatchdog()` — starts `watchdogTimer`
3. `startBackupWatchdog()` — starts `backupWatchdog`
4. `startUIUpdateTimer()` — starts `uiUpdateTimer`
5. `startLogRefreshTimer()` — starts `logRefreshTimer`

**All timers** cancelled in `applicationWillTerminate` (line 2086).

---

## 7. Audio Pipeline

The `speak(_:)` function (line 1799) runs on `speechQueue`. It is a 10-phase pipeline:

```
Phase 1  Kill in-progress speech
         → synthesizer.stopSpeaking(at: .immediate)
         → sayProcess?.terminate(); sayProcess = nil
         (On MAIN thread, before dispatching to speechQueue)

Phase 2  Capture values for background block
         → voiceName, appVol (speechVolume), chimeVol (chimeVolume)
         (Thread-safe snapshot before handing off)

─── speechQueue.async ─────────────────────────────────────────────────────

Phase 3  CoreAudio audio state query (< 1ms — no process spawning)
         → caGetDefaultOutputDevice() → caGetDeviceName() → caGetDeviceVolume()
         → caIsOutputMuted() → caGetTransportType()
         Returns: (vol: Int, muted: Bool, device: String, isVirtual: Bool)

Phase 4  Fix volume if too low or muted
         → Only if audio.muted OR audio.vol < 60
         → osascript: "set volume without output muted" + "set volume output volume 65"
         → waitUntilExit() — blocking in background queue

Phase 5  Force built-in speakers if virtual device
         → caFindBuiltInSpeakers() → caSetDefaultOutputDevice()
         → Prevents announcements playing through BlackHole, Loopback, etc.

Phase 6  Lid check before chime
         → isLidClosed() — fast IOKit query
         → if closed: return (silent abort, no log)

Phase 7  Pre-speech chime (non-blocking)
         → NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff")
         → volume = min(1.0, chimeVol / 3.0)  (maps afplay 0–3 scale → NSSound 0–1 scale)
         → chime.play() dispatched on main thread via DispatchQueue.main.sync
         → Thread.sleep(0.4 s) — gap between chime and speech

Phase 8  Lid check before render
         → isLidClosed() again — lid may have closed during the 0.4s chime gap

Phase 9  Render speech to AIFF file
         → /usr/bin/say -v {voiceName} -r 180 -o /tmp/timeannouncer_speech.aiff "{text}"
         → sayProcess updated on main thread (for cancellation)
         → Verifies output file size > 100 bytes (guards against empty renders)
         → Logs: SPEECH_RENDER, SPEECH_RENDER_FAIL

Phase 10 Lid check, then play with volume compensation
         → isLidClosed() one final time
         → Volume compensation:
              sysVol  = max(audio.vol, 60)          // minimum 60 prevents div/0
              comp    = min(4.0, max(1.5, 100.0 / sysVol))  // range: 1.5x–4.0x
              afplayVol = appVol * comp
         → /usr/bin/afplay -v {afplayVol} /tmp/timeannouncer_speech.aiff
         → waitUntilExit()
         → Logs: SPEECH_PLAY, SPEECH_DONE (with duration), SPEECH_PLAY_FAIL
         → Temp file deleted after playback
```

**Hourly chime variant** (`speakTime()`, line 1735): At exact hour boundary (`slotMinute == 0`), plays `Tink.aiff` first (if `hourlyChimeEnabled`), then calls `speak()` after 0.6 s. Non-hour slots call `speak()` directly.

---

## 8. Timer System

### Primary Timer (`primaryTimer` — `DispatchSourceTimer`)

Aligns to wall-clock announcement slots, not elapsed time:

```swift
let minutesUntilNext = announcementInterval - (minute % announcementInterval)
var secondsUntilNext = Double(minutesUntilNext * 60 - second)
// Fires at: DispatchWallTime(timeIntervalSince1970: targetTime)
```

- **One-shot**: fires once, then calls `scheduleNextAnnouncement()` to reschedule
- **Cancelled and recreated** on: display mode change, interval change, screen wake, `enabled` toggle

### Watchdog (`watchdogTimer` — NSTimer, 5s)

`watchdogTick()` responsibilities:
1. Poll `isLidClosed()` — update `lidOpen`, log `LID_CLOSED/OPENED`, stop speech
2. Update `muteTimer` countdown
3. Catch missed announcements within a grace window:
   - `graceWindow = min(120, announcementInterval * 60 / 2)` (seconds)
   - If `currentSlot != lastAnnouncedSlot` and within grace window → `speakTime()`

### Backup Watchdog (`backupWatchdog` — `DispatchSourceTimer`, 7s)

Runs on a global utility queue. Dispatches `watchdogTick()` to main thread. Purpose: survive RunLoop stalls that would freeze the NSTimer-based watchdog. The 7s interval is offset from 5s to avoid synchronization.

### Triple Redundancy Rationale

- **primaryTimer**: Accurate wall-clock timing (prevents drift)
- **watchdogTimer**: Catches missed slots (lid/sleep edge cases, timer cancellation bugs)
- **backupWatchdog**: Catches RunLoop stalls that would freeze `watchdogTimer`

---

## 9. Hotkey System

### Registration (line 1656)

Two monitors registered via `NSEvent`:
- `globalKeyMonitor` — `addGlobalMonitorForEvents(matching: .keyDown)` — fires when other apps are focused
- `localKeyMonitor` — `addLocalMonitorForEvents(matching: .keyDown)` — fires when app is focused, can consume event

### Modifier requirement

All hotkeys require **Ctrl+Shift** (line 1686):
```swift
guard event.modifierFlags.contains([.control, .shift]) else { return }
```

### Default hotkeys

| Action | Default | Effect |
|--------|---------|--------|
| Announce now | Ctrl+Shift+T | Calls `announceNowAction()` — ignores `canSpeak`, always speaks |
| Toggle mute | Ctrl+Shift+M | `muteFor(minutes: 15)` or `unmuteAction()` |
| Open UI | Ctrl+Shift+A | Toggles popover (menu bar mode) or opens settings window (floating mode) |

### Hotkey recording flow

1. User clicks one of the 3 hotkey buttons (`hkAnnounceBtn`, `hkMuteBtn`, `hkOpenBtn`)
2. `recordingHotkeyFor` is set to `"announce"/"mute"/"open"`
3. Button title changes to `"Press a key..."`, global monitor is suppressed
4. Next key press captured by `localKeyMonitor`:
   - Escape → `cancelRecording()` — restores previous key
   - Any other letter → `finishRecordingHotkey(key:)` — updates hotkey + saves to UserDefaults
5. Conflict detection: if the new key matches an existing hotkey, the assignment is rejected

### Accessibility permission

`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` called once at startup. Without it, `globalKeyMonitor` fires but events are silently dropped by the OS.

---

## 10. Lid Detection

4-layer system — ordered from fastest to most reliable:

| Layer | Mechanism | Trigger | Lines |
|-------|-----------|---------|-------|
| **1. IOKit notification** | `IOServiceAddInterestNotification` on `IOPMrootDomain` | Instantaneous hardware event | 1585–1612 |
| **2. Watchdog poll** | `isLidClosed()` called every 5s | Catches missed IOKit notifications | 1614–1645 |
| **3. Pre-speech check** | `isLidClosed()` at start of `speakTime()` | Eliminates stale `lidOpen` cache | 1709–1717 |
| **4. Pre-chime + pre-playback checks** | `isLidClosed()` twice inside `speak()` | Eliminates race where lid closes during chime gap or render | 1834, 1848, 1884 |

**`isLidClosed()` implementation:**
```swift
func isLidClosed() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else { return false }
    defer { IOObjectRelease(service) }
    if let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) {
        return (prop.takeRetainedValue() as? Bool) ?? false
    }
    return false
}
```

Memory management: `takeRetainedValue()` bridges the CF object to Swift ARC, which calls `CFRelease` when it goes out of scope. `defer { IOObjectRelease(service) }` releases the IO service handle. No leaks.

**NSWorkspace fallback**: `screensDidSleepNotification` / `screensDidWakeNotification` also update `screenAwake` (not `lidOpen`) — these are secondary signals used by `canSpeak` but not by the audio pipeline's lid checks.

---

## 11. Launch at Login

**Mechanism**: LaunchAgent plist written to `~/Library/LaunchAgents/`.

**Plist location**: `~/Library/LaunchAgents/com.mshrmnsr.timeannouncer.plist`

**Plist structure**:
```xml
<dict>
    <key>Label</key>
    <string>com.mshrmnsr.timeannouncer</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>/Users/mshrmnsr/claude1/time announcer/TimeAnnouncer.app</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
```

**Enable flow**: Checkbox `.on` → `writeLaunchAgentPlist()` → serializes dict → writes to plist path
**Disable flow**: Checkbox `.off` → `FileManager.default.removeItem(atPath:)` on plist path
**State detection**: `FileManager.default.fileExists(atPath: launchAgentPath)` — checkbox initialized from this at settings build time

**Note**: `launchd` will pick up the plist automatically on next user login. No `launchctl load` call needed — `open -a` invocation means the app starts via standard macOS app launching, not as a background daemon.

---

## 12. Log System

**File**: `{parent of .app bundle}/TimeAnnouncerBuild/announcer.log`
- Determined at process launch (lines 9–23)
- Created if missing, appended if existing

**Format**: `ISO8601 fractional-seconds EVENTTYPE [fields...]`
```
2026-04-07T10:30:00.123+0300 LAUNCH v4.3 lid=open interval=5min hours=7-23 mode=menuBar logPath=...
2026-04-07T10:30:00.456+0300 ANNOUNCE slot=10:30 delay=0s text="10 30"
2026-04-07T10:30:00.789+0300 SPEECH_RENDER text="10 30" voice=Samantha sysVol=75% muted=false device="MacBook Pro Speakers" virtual=false
2026-04-07T10:30:01.234+0300 SPEECH_PLAY text="10 30" size=12345b afplayVol=2.0x comp=1.5x
2026-04-07T10:30:02.100+0300 SPEECH_DONE text="10 30" dur=1.9s
```

**Thread safety**: All writes go through `logQueue` (serial `DispatchQueue`). `FileHandle.seekToEndOfFile()` is used to append; file handle opened and closed per write (no persistent handle state).

**Event types**:

| Event | Meaning |
|-------|---------|
| `LAUNCH` | App started — includes version, lid state, interval, active hours, display mode |
| `ANNOUNCE` | Time slot triggered — includes slot, delay from slot start, text, hourly flag |
| `AUDIO_FIX` | Volume was below 60% or muted — shows before/after |
| `SPEECH_RENDER` | `say` process started — includes text, voice, audio state |
| `SPEECH_RENDER_FAIL` | `say` process failed — exit code, stderr |
| `SPEECH_PLAY` | `afplay` started — file size, volume multiplier |
| `SPEECH_DONE` | `afplay` finished — duration. `SUSPECT_SHORT` appended if < 0.3s |
| `SPEECH_PLAY_FAIL` | `afplay` failed — exit code, stderr |
| `LID_CLOSED` | Clamshell closed — source in parens: `(IOKit notification)`, `(detected at timer)`, `(detected at speak)` |
| `LID_OPENED` | Clamshell opened |
| `SCREEN_SLEEP` | Display sleep detected |
| `SCREEN_WAKE` | Display wake detected |

**Log tab**: The Settings window Log tab reads the log file every 5 seconds (`logRefreshTimer`) and displays the last N lines in an NSTextView with monospace font.

---

## 13. External Dependencies

### Frameworks (linked at compile time)

| Framework | Used for |
|-----------|---------|
| **AppKit** | NSApplication, NSWindow, NSPanel, NSStatusItem, NSPopover, NSEvent (hotkeys), NSWorkspace (screen sleep/wake), NSSound (chime) |
| **AVFoundation** | `AVSpeechSynthesizer` (fallback / voice enumeration), `AVSpeechSynthesisVoice` (populating voice list) |
| **IOKit** | `IOPMrootDomain` lid state query, `IOServiceAddInterestNotification` for hardware events |
| **CoreAudio** | `AudioObjectGetPropertyData/SetPropertyData` — volume, mute, device name, transport type, built-in speaker detection |

### External Binaries (spawned as child processes)

| Binary | Path | Usage |
|--------|------|-------|
| `say` | `/usr/bin/say` | Renders speech to AIFF: `say -v {voice} -r 180 -o {tmpFile} "{text}"` |
| `afplay` | `/usr/bin/afplay` | Plays AIFF with volume: `afplay -v {vol} {tmpFile}` |
| `osascript` | `/usr/bin/osascript` | Sets system volume when too low: `set volume without output muted` + `set volume output volume {n}` |

**Note**: `say` and `afplay` are Apple-private tools bundled with macOS. They cannot be distributed separately. `AVSpeechSynthesizer` is available as a fallback but `say`+`afplay` produce higher-quality output with better voice selection and pitch control.

---

## 14. Known Limitations & Improvement Opportunities

### Current Limitations

1. **No system audio awareness**: Volume auto-fix triggers on any low-volume situation, even when user intentionally set volume low. No way to distinguish "user chose quiet" from "accidentally low."

2. **No Do Not Disturb / Focus Mode awareness**: Announces during macOS Focus modes (Work, Sleep, Personal) — can be embarrassing or disruptive in meetings.

3. **No calendar integration**: Announces while user is in a video call or meeting. No EventKit query to detect active events.

4. **No onboarding**: First launch is silent — no welcome screen, no explanation of accessibility permission requirement for hotkeys. Users who don't grant accessibility can't use hotkeys and don't know why.

5. **Opaque skip behavior**: When an announcement is skipped (lid closed, muted, outside active hours), there is no visual feedback in the UI. User can't tell why silence happened without reading the log.

6. ~~**Menu bar label is static**: Clock emoji only — no glanceable countdown to next announcement.~~ **Done in v4.4** — status-bar title is now a smart countdown (`⏰ 4m`, `🔇 3m`, `⏸`, `💤`, `😴`) driven by `refreshUI()`.

7. **No announcement history or stats**: Log is raw text. No way to see "how many announcements today?" or build an accountability streak.

8. **App path is hardcoded in LaunchAgent**: Plist uses `NSHomeDirectory() + "/claude1/time announcer/TimeAnnouncer.app"` — breaks if the app is moved.

### Top 5 Improvements to Reach 10/10

#### Improvement 1: Calendar-Aware Silence (UX +2, Features +1)
- **Problem**: App announces at 2:00 PM while user is in a meeting — disruptive.
- **Solution**: Check macOS Calendar via `EventKit`. If there's an active event marked "Busy" or with a conferencing link, skip the announcement silently and log `SKIPPED reason=meeting`.
- **API**: `EKEventStore` + `EKCalendar` — standard Swift, no third-party dependency.
- **Effort**: Medium. Requires calendar permission prompt.

#### ~~Improvement 2: Smart Menu Bar Label~~ ✅ Shipped in v4.4
- **Was**: Menu bar showed only a static clock emoji.
- **Now**: Status-bar title reflects app state — `⏰ Xm` active, `🔇 Xm` muted, `⏸` disabled, `💤` lid closed, `😴` outside active hours. Updated every 1 s in `refreshUI()` (only reassigned when the string changes).
- **Implementation**: `setupMenuBarMode()` seeds the title + a monospaced-digit font; `refreshUI()` recomputes the label alongside the existing countdown.

#### Improvement 3: First-Run Onboarding + Permission Flow (UX +2)
- **Problem**: First launch is cold — accessibility permission fails silently, hotkeys don't work, user confused.
- **Solution**: On first launch (detect via `UserDefaults.bool(forKey: "TAHasLaunched")`), show a 3-step NSWindowController:
  1. "Allow accessibility access" → `System Settings > Privacy > Accessibility` with polling for grant
  2. "Choose interval" — 5/10/15/30 picker
  3. "Test your voice" — plays sample
- **Effort**: Medium.

#### Improvement 4: Do Not Disturb + Focus Mode Integration (Features +1, UX +0.5)
- **Problem**: App announces during Focus modes, ignoring the system-level "I want silence" signal.
- **Solution**: Check `com.apple.notificationcenterui.donotdisturb` defaults (macOS 12 and earlier) or `NSFocusFilterIntent` (macOS 13+). If DND/Focus is active, skip or whisper (20% volume, no chime).
- **Effort**: Low-Medium. API exists, just needs a `canSpeak` guard.

#### Improvement 5: Announcement History + Stats (Features +1.5)
- **Problem**: Raw log is developer-only. No accountability loop for the user.
- **Solution**: Parse log into a stats view: announcements heard today, skipped, streak (days with all announcements heard). Weekly bar chart via Core Graphics. Optional CSV export.
- **Effort**: Medium. No new dependencies — just log parsing + basic drawing.
- **Impact**: High for ADHD users — visible streaks create a positive feedback loop.

---

*Last updated: v4.4 — 2026-04-20 (Improvement #2: smart menu-bar label)*
*Next update required when: any change to main.swift*
