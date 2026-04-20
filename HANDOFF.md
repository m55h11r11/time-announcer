# Session Handoff — TimeAnnouncer

> Temporary file. Delete when the cloud session picks up context.
> Created: 2026-04-20 (handoff from local Claude Code session)

---

## What This Repo Is

**TimeAnnouncer v4.3** — single-file Swift macOS menu-bar app that speaks the time at configurable intervals. Built with `swiftc` directly (no Xcode).

- **Source:** `TimeAnnouncerBuild/main.swift` (2119 lines)
- **Runnable bundle:** `TimeAnnouncer.app/`
- **Architecture reference:** `ARCHITECTURE.md` (14 sections — READ THIS FIRST)
- **Install script:** `install.sh`
- **Helper scripts:** `announce_time.sh`, `TimeAnnouncerBuild/benchmark.sh`, `TimeAnnouncerBuild/test_announcer.sh`

---

## Current State

- **v4.3 is deployed and stable.** All 8 prior critical/high/medium bugs FIXED.
- **v4.3 residual-bug audit done.** 3 suspected residual bugs (R1 division-by-zero, R2 IOKit leak, R3 speakingNow flag) were investigated and all verified as false positives — v4.3 already handles them. No code changes needed.
- **ARCHITECTURE.md just written.** 29.3 KB, covers 14 sections: app identity, file structure, types & line numbers, state model (13 UserDefaults keys), UI (3-tab settings + menu bar + floating window), threading (queues + 6 timers), audio pipeline (10-phase `speak()`), triple-redundant timers, hotkey system, 4-layer lid detection, launch-at-login, log system, external deps, known limitations.
- **Initial commit pushed.** Repo was formerly v4.2 flat structure; history was force-pushed to v4.3 reorganized layout. `README.md` and `install.sh` preserved from v4.2.

---

## Build & Run

```bash
pkill -f TimeAnnouncer; sleep 1
cd TimeAnnouncerBuild
swiftc -o TimeAnnouncer main.swift -framework AppKit -framework AVFoundation -framework IOKit -framework CoreAudio
cp TimeAnnouncer "../TimeAnnouncer.app/Contents/MacOS/TimeAnnouncer"
open "../TimeAnnouncer.app"
```

> ⚠️ **Cloud sandbox cannot build or run this.** No macOS frameworks, no GUI. You can only edit source, review architecture, open PRs. Build+verify happens locally.

---

## Pending Work / Candidate Next Steps

From the v4.3 improvement plan (see `/Users/mshrmnsr/.claude/plans/jolly-gliding-spark.md` — **not in repo**, local only). Top 5 suggested improvements to reach 10/10:

1. **Calendar-aware silence** — check EventKit before announcing; skip if in a meeting marked Busy.
2. **Smart menu-bar label** — show `⏰ 4m` or `⏰ 12:00` instead of a generic icon. One-line change: `statusItem.button?.title = " \(nextLabel)"`.
3. **First-run onboarding** — 3-step welcome sheet (accessibility permission, interval picker, test voice). Gated on `UserDefaults.bool(forKey: "TAHasLaunched")`.
4. **Do Not Disturb / Focus-mode integration** — skip or whisper when Focus is active.
5. **Announcement history + stats** — parse log into counts, streaks, weekly chart.

Pick one, implement, open PR.

---

## Key Constraints

- Single-file Swift architecture. Do **not** split `main.swift` into multiple files — the build command and install flow assume one file.
- Every change to `main.swift` must update `ARCHITECTURE.md` in the same commit (maintenance rule stated in that file).
- Bump version string in the `LAUNCH` log line (currently `v4.3`) when shipping.
- No external dependencies — pure AppKit / CoreAudio / IOKit / AVFoundation + shell tools (`say`, `afplay`, `osascript`).

---

## What You Cannot Do in the Cloud Session

- Build the app (no `swiftc`, no macOS frameworks).
- Run the app (no GUI).
- Test audio pipeline / lid detection / hotkeys (all need real macOS hardware).
- Access local MCPs (TickTick, Gmail, Calendar).

→ **Cloud session scope: code edits, architecture review, PRs.** Local build/verify stays on the Mac.

---

## First Prompt Suggestion for Cloud Session

> "Read `ARCHITECTURE.md` and `HANDOFF.md`. Then pick Improvement #2 (smart menu-bar label) from the pending list and implement it in `TimeAnnouncerBuild/main.swift`. Update `ARCHITECTURE.md` to reflect the change. Open a PR."

---

Delete this file after the cloud session has read it.
