import Cocoa
import AVFoundation
import IOKit

// MARK: - Logging

// Resolve log path relative to the running binary's .app bundle
let logPath: String = {
    let exe = ProcessInfo.processInfo.arguments[0]
    // e.g. /Users/foo/mydir/TimeAnnouncer.app/Contents/MacOS/TimeAnnouncer
    // → /Users/foo/mydir/TimeAnnouncerBuild/announcer.log
    if let range = exe.range(of: "/TimeAnnouncer.app/") {
        let parentDir = String(exe[exe.startIndex..<range.lowerBound])
        let buildDir = parentDir + "/TimeAnnouncerBuild"
        if !FileManager.default.fileExists(atPath: buildDir) {
            try? FileManager.default.createDirectory(atPath: buildDir, withIntermediateDirectories: true)
        }
        return buildDir + "/announcer.log"
    }
    // Fallback: next to the binary itself
    return (exe as NSString).deletingLastPathComponent + "/announcer.log"
}()

func logEvent(_ message: String) {
    let ts = ISO8601DateFormatter()
    ts.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
    let line = "\(ts.string(from: Date())) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

// MARK: - Clamshell (Lid) Detection via IOKit

func isLidClosed() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else { return false }
    defer { IOObjectRelease(service) }
    if let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) {
        return (prop.takeRetainedValue() as? Bool) ?? false
    }
    return false
}

// MARK: - Display Mode

enum DisplayMode: String {
    case menuBar = "menuBar"
    case floatingWindow = "floatingWindow"
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AVSpeechSynthesizerDelegate, NSPopoverDelegate {

    var window: NSWindow!
    var tabView: NSTabView!

    // Display mode
    var displayMode: DisplayMode = .menuBar
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var floatingPanel: NSPanel?
    var floatingTimeLabel: NSTextField?
    var floatingNextLabel: NSTextField?
    var floatingStatusDot: NSTextField?
    var modeSegment: NSSegmentedControl!

    // Main tab UI
    var statusLabel: NSTextField!
    var nextAnnounceLabel: NSTextField!
    var lidLabel: NSTextField!
    var toggleButton: NSButton!
    var announceNowButton: NSButton!
    var volumeSlider: NSSlider!
    var volumeLabel: NSTextField!
    var mutePopup: NSPopUpButton!
    var muteButton: NSButton!
    var unmuteButton: NSButton!
    var muteRemainingLabel: NSTextField!

    // Settings tab UI
    var intervalPopup: NSPopUpButton!
    var allDayCheckbox: NSButton!
    var startHourPopup: NSPopUpButton!
    var endHourPopup: NSPopUpButton!
    var voicePopup: NSPopUpButton!
    var hourlyChimeCheckbox: NSButton!
    var startAtLoginCheckbox: NSButton!
    var hotkeyStatusLabel: NSTextField!

    // Log tab UI
    var logScrollView: NSScrollView!
    var logTextView: NSTextView!
    var logRefreshTimer: Timer?

    // Timers
    var primaryTimer: DispatchSourceTimer?
    var watchdogTimer: Timer?
    var backupWatchdog: DispatchSourceTimer?
    var muteTimer: Timer?
    var uiUpdateTimer: Timer?

    // IOKit lid notification
    var notifyPort: IONotificationPortRef?
    var notifier: io_object_t = 0

    // Global hotkey monitors
    var globalKeyMonitor: Any?
    var localKeyMonitor: Any?

    // Configurable hotkeys (single letter, always Ctrl+Shift+key)
    var hotkeyAnnounce: String = "t"
    var hotkeyMute: String = "m"
    var hotkeyOpen: String = "a"
    var recordingHotkeyFor: String? = nil  // "announce", "mute", or "open" when recording

    // Hotkey UI buttons
    var hkAnnounceBtn: NSButton!
    var hkMuteBtn: NSButton!
    var hkOpenBtn: NSButton!

    // State
    var lastAnnouncedSlot: String?
    var screenAwake: Bool = true
    var lidOpen: Bool = true
    var enabled: Bool = true
    var isMuted: Bool = false
    var muteEndDate: Date?
    var speechVolume: Float = 1.0
    var synthesizer = AVSpeechSynthesizer()
    var speechDidStart: Bool = false
    var sayProcess: Process? = nil

    // Configurable settings
    var announcementInterval: Int = 5
    var activeStartHour: Int = 7
    var activeEndHour: Int = 23
    var selectedVoiceIdentifier: String? = nil
    var selectedVoiceName: String? = nil
    var hourlyChimeEnabled: Bool = true
    var allDayEnabled: Bool = true

    let launchAgentPath = NSHomeDirectory() + "/Library/LaunchAgents/com.mshrmnsr.timeannouncer.plist"

    var inActiveHours: Bool {
        if allDayEnabled { return true }
        let hour = Calendar.current.component(.hour, from: Date())
        if activeStartHour <= activeEndHour {
            return hour >= activeStartHour && hour < activeEndHour
        } else {
            return hour >= activeStartHour || hour < activeEndHour
        }
    }

    var canSpeak: Bool {
        return enabled && !isMuted && screenAwake && lidOpen && inActiveHours
    }

    // MARK: - App Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        synthesizer.delegate = self
        loadPreferences()
        buildWindow()

        // Screen sleep/wake (secondary to IOKit)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(screenDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screenDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)

        lidOpen = !isLidClosed()
        logEvent("LAUNCH v4.2 lid=\(lidOpen ? "open" : "closed") interval=\(announcementInterval)min hours=\(activeStartHour)-\(activeEndHour) mode=\(displayMode.rawValue) logPath=\(logPath)")

        scheduleNextAnnouncement()
        startWatchdog()
        startBackupWatchdog()
        registerLidNotification()
        registerGlobalHotkey()
        startUIUpdateTimer()
        startLogRefreshTimer()

        // Initialize display mode
        switch displayMode {
        case .menuBar:
            window.orderOut(nil)
            setupMenuBarMode()
        case .floatingWindow:
            window.orderOut(nil)
            setupFloatingMode()
        }

        if lidOpen && inActiveHours { announceNowAction() }
        refreshUI()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            switch displayMode {
            case .menuBar:
                if let button = statusItem?.button {
                    togglePopover(button)
                }
            case .floatingWindow:
                floatingPanel?.orderFront(nil)
            }
        }
        return true
    }

    // Window delegate: when settings window closes in menu bar mode, go back to accessory
    func windowWillClose(_ notification: Notification) {
        if displayMode == .menuBar {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if !(self.popover?.isShown ?? false) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    // MARK: - Preferences

    func loadPreferences() {
        let defaults = UserDefaults.standard
        let savedInterval = defaults.integer(forKey: "TAIntervalMinutes")
        announcementInterval = savedInterval > 0 ? savedInterval : 5

        activeStartHour = defaults.object(forKey: "TAActiveStartHour") as? Int ?? 7
        activeEndHour = defaults.object(forKey: "TAActiveEndHour") as? Int ?? 23

        selectedVoiceIdentifier = defaults.string(forKey: "TAVoiceIdentifier")
        selectedVoiceName = defaults.string(forKey: "TAVoiceName")
        // Validate saved voice still exists
        if let voiceId = selectedVoiceIdentifier,
           AVSpeechSynthesisVoice(identifier: voiceId) == nil {
            selectedVoiceIdentifier = nil
            selectedVoiceName = nil
        }

        hourlyChimeEnabled = defaults.object(forKey: "TAHourlyChime") as? Bool ?? true
        allDayEnabled = defaults.object(forKey: "TAAllDay") as? Bool ?? true

        let savedVolume = defaults.integer(forKey: "TAVolume")
        if savedVolume > 0 { speechVolume = Float(savedVolume) / 100.0 }

        hotkeyAnnounce = defaults.string(forKey: "TAHotkeyAnnounce") ?? "t"
        hotkeyMute = defaults.string(forKey: "TAHotkeyMute") ?? "m"
        hotkeyOpen = defaults.string(forKey: "TAHotkeyOpen") ?? "a"

        displayMode = DisplayMode(rawValue: defaults.string(forKey: "TADisplayMode") ?? "") ?? .menuBar
    }

    func savePreference(_ key: String, value: Any?) {
        if let v = value {
            UserDefaults.standard.set(v, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Build Window

    func buildWindow() {
        let w: CGFloat = 360
        let h: CGFloat = 580

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Time Announcer"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        // Tab view
        tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let mainTab = NSTabViewItem(identifier: "main")
        mainTab.label = "Main"
        let mainView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h - 30))
        mainTab.view = mainView
        buildMainTab(mainView)

        let settingsTab = NSTabViewItem(identifier: "settings")
        settingsTab.label = "Settings"
        let settingsView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h - 30))
        settingsTab.view = settingsView
        buildSettingsTab(settingsView)

        let logTab = NSTabViewItem(identifier: "log")
        logTab.label = "Log"
        let logView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h - 30))
        logTab.view = logView
        buildLogTab(logView)

        tabView.addTabViewItem(mainTab)
        tabView.addTabViewItem(settingsTab)
        tabView.addTabViewItem(logTab)

        window.contentView = tabView
        // Don't show window here — display mode setup will decide visibility
    }

    // MARK: - Group Box Helper

    func makeGroupBox(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, title: String = "") -> NSBox {
        let box = NSBox(frame: NSRect(x: x, y: y, width: width, height: height))
        box.boxType = .custom
        box.fillColor = NSColor.controlBackgroundColor
        box.cornerRadius = 10
        box.borderWidth = 0
        box.titlePosition = .noTitle
        box.contentViewMargins = NSSize(width: 0, height: 0)
        parent.addSubview(box)
        return box
    }

    // MARK: - Main Tab

    func buildMainTab(_ view: NSView) {
        let w = view.frame.width
        let h = view.frame.height
        let margin: CGFloat = 16
        let boxW = w - margin * 2
        var y = h - 16

        // ── Status Group ──
        let statusBoxH: CGFloat = 76
        y -= statusBoxH
        let statusBox = makeGroupBox(in: view, x: margin, y: y, width: boxW, height: statusBoxH)
        let sv = statusBox.contentView!

        statusLabel = makeLabel(in: sv, x: 14, y: statusBoxH - 28, width: boxW - 28, height: 22, fontSize: 16, bold: true)
        statusLabel.alignment = .center

        nextAnnounceLabel = makeLabel(in: sv, x: 14, y: statusBoxH - 50, width: boxW - 28, height: 16, fontSize: 12)
        nextAnnounceLabel.alignment = .center
        nextAnnounceLabel.textColor = .secondaryLabelColor

        lidLabel = makeLabel(in: sv, x: 14, y: statusBoxH - 68, width: boxW - 28, height: 14, fontSize: 11)
        lidLabel.alignment = .center
        lidLabel.textColor = .tertiaryLabelColor

        y -= 10

        // ── Actions Group ──
        let actionsBoxH: CGFloat = 72
        y -= actionsBoxH
        let actionsBox = makeGroupBox(in: view, x: margin, y: y, width: boxW, height: actionsBoxH)
        let av = actionsBox.contentView!
        let btnW = boxW - 28

        toggleButton = NSButton(frame: NSRect(x: 14, y: actionsBoxH - 36, width: btnW, height: 28))
        toggleButton.bezelStyle = .rounded
        toggleButton.title = "Turn Off"
        toggleButton.target = self
        toggleButton.action = #selector(toggleEnabled)
        av.addSubview(toggleButton)

        announceNowButton = NSButton(frame: NSRect(x: 14, y: 8, width: btnW, height: 28))
        announceNowButton.bezelStyle = .rounded
        announceNowButton.title = "Announce Now"
        announceNowButton.target = self
        announceNowButton.action = #selector(announceNowAction)
        av.addSubview(announceNowButton)

        y -= 10

        // ── Volume Group ──
        let volumeBoxH: CGFloat = 58
        y -= volumeBoxH
        let volumeBox = makeGroupBox(in: view, x: margin, y: y, width: boxW, height: volumeBoxH)
        let vv = volumeBox.contentView!

        let volTitle = makeLabel(in: vv, x: 14, y: volumeBoxH - 24, width: 60, height: 18, fontSize: 13, bold: true)
        volTitle.stringValue = "Volume"

        volumeLabel = makeLabel(in: vv, x: boxW - 60, y: volumeBoxH - 24, width: 46, height: 18, fontSize: 13)
        volumeLabel.alignment = .right
        volumeLabel.stringValue = "\(Int(speechVolume * 100))%"

        volumeSlider = NSSlider(frame: NSRect(x: 14, y: 8, width: boxW - 28, height: 20))
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.integerValue = Int(speechVolume * 100)
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.isContinuous = true
        vv.addSubview(volumeSlider)

        y -= 10

        // ── Mute Group ──
        let muteBoxH: CGFloat = 68
        y -= muteBoxH
        let muteBox = makeGroupBox(in: view, x: margin, y: y, width: boxW, height: muteBoxH)
        let mv = muteBox.contentView!

        let muteTitle = makeLabel(in: mv, x: 14, y: muteBoxH - 26, width: 65, height: 18, fontSize: 13, bold: true)
        muteTitle.stringValue = "Mute for"

        mutePopup = NSPopUpButton(frame: NSRect(x: 82, y: muteBoxH - 28, width: 110, height: 24))
        mutePopup.addItems(withTitles: ["15 min", "30 min", "1 hour", "2 hours"])
        mv.addSubview(mutePopup)

        muteButton = NSButton(frame: NSRect(x: boxW - 80, y: muteBoxH - 28, width: 66, height: 28))
        muteButton.bezelStyle = .rounded
        muteButton.title = "Mute"
        muteButton.target = self
        muteButton.action = #selector(muteAction)
        mv.addSubview(muteButton)

        muteRemainingLabel = makeLabel(in: mv, x: 14, y: 8, width: boxW - 100, height: 16, fontSize: 11)
        muteRemainingLabel.textColor = .systemOrange
        muteRemainingLabel.stringValue = ""

        unmuteButton = NSButton(frame: NSRect(x: boxW - 90, y: 4, width: 76, height: 28))
        unmuteButton.bezelStyle = .rounded
        unmuteButton.title = "Unmute"
        unmuteButton.target = self
        unmuteButton.action = #selector(unmuteAction)
        unmuteButton.isHidden = true
        mv.addSubview(unmuteButton)
    }

    // MARK: - Settings Tab

    func buildSettingsTab(_ view: NSView) {
        let w = view.frame.width
        let h = view.frame.height
        let margin: CGFloat = 16
        let boxW = w - margin * 2
        var y = h - 16

        // ── Display Mode Group ──
        let modeBoxH: CGFloat = 44
        y -= modeBoxH
        let modeBox = makeGroupBox(in: view, x: margin, y: y, width: boxW, height: modeBoxH)
        let modev = modeBox.contentView!

        let modeTitle = makeLabel(in: modev, x: 14, y: 12, width: 90, height: 18, fontSize: 13, bold: true)
        modeTitle.stringValue = "Display"

        modeSegment = NSSegmentedControl(frame: NSRect(x: 100, y: 8, width: 210, height: 26))
        modeSegment.segmentCount = 2
        modeSegment.setLabel("☰ Menu Bar", forSegment: 0)
        modeSegment.setLabel("🔲 Floating", forSegment: 1)
        modeSegment.setWidth(100, forSegment: 0)
        modeSegment.setWidth(100, forSegment: 1)
        modeSegment.selectedSegment = displayMode == .menuBar ? 0 : 1
        modeSegment.target = self
        modeSegment.action = #selector(modeSegmentChanged)
        modev.addSubview(modeSegment)

        y -= 10

        // ── Interval Group ──
        let intervalBoxH: CGFloat = 40
        y -= intervalBoxH
        let intervalBox = makeGroupBox(in: view, x: margin, y: y, width: boxW, height: intervalBoxH)
        let iv = intervalBox.contentView!

        let intervalTitle = makeLabel(in: iv, x: 14, y: 10, width: 120, height: 18, fontSize: 13, bold: true)
        intervalTitle.stringValue = "Announce every"

        intervalPopup = NSPopUpButton(frame: NSRect(x: 140, y: 6, width: 100, height: 24))
        intervalPopup.addItems(withTitles: ["5 min", "10 min", "15 min", "30 min"])
        let intervalMap = [5: 0, 10: 1, 15: 2, 30: 3]
        intervalPopup.selectItem(at: intervalMap[announcementInterval] ?? 0)
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        iv.addSubview(intervalPopup)

        y -= 10

        // ── Schedule Group ──
        let scheduleBoxH: CGFloat = 72
        y -= scheduleBoxH
        let scheduleBox = makeGroupBox(in: view, x: margin, y: y, width: boxW, height: scheduleBoxH)
        let schv = scheduleBox.contentView!

        let hoursTitle = makeLabel(in: schv, x: 14, y: scheduleBoxH - 26, width: 100, height: 18, fontSize: 13, bold: true)
        hoursTitle.stringValue = "Active hours"

        allDayCheckbox = NSButton(frame: NSRect(x: 130, y: scheduleBoxH - 26, width: 120, height: 18))
        allDayCheckbox.setButtonType(.switch)
        allDayCheckbox.title = "All day"
        allDayCheckbox.state = allDayEnabled ? .on : .off
        allDayCheckbox.target = self
        allDayCheckbox.action = #selector(allDayToggled)
        schv.addSubview(allDayCheckbox)

        let fromLabel = makeLabel(in: schv, x: 14, y: 10, width: 40, height: 18, fontSize: 12)
        fromLabel.stringValue = "From:"

        startHourPopup = NSPopUpButton(frame: NSRect(x: 55, y: 6, width: 95, height: 24))
        for hr in 0..<24 { startHourPopup.addItem(withTitle: formatHour(hr)) }
        startHourPopup.selectItem(at: activeStartHour)
        startHourPopup.target = self
        startHourPopup.action = #selector(activeHoursChanged)
        startHourPopup.isEnabled = !allDayEnabled
        schv.addSubview(startHourPopup)

        let toLabel = makeLabel(in: schv, x: 160, y: 10, width: 25, height: 18, fontSize: 12)
        toLabel.stringValue = "To:"

        endHourPopup = NSPopUpButton(frame: NSRect(x: 185, y: 6, width: 95, height: 24))
        for hr in 0..<24 { endHourPopup.addItem(withTitle: formatHour(hr)) }
        endHourPopup.selectItem(at: activeEndHour)
        endHourPopup.target = self
        endHourPopup.action = #selector(activeHoursChanged)
        endHourPopup.isEnabled = !allDayEnabled
        schv.addSubview(endHourPopup)

        y -= 10

        // ── Voice Group ──
        let voiceBoxH: CGFloat = 76
        y -= voiceBoxH
        let voiceBox = makeGroupBox(in: view, x: margin, y: y, width: boxW, height: voiceBoxH)
        let voicev = voiceBox.contentView!

        let voiceTitle = makeLabel(in: voicev, x: 14, y: voiceBoxH - 26, width: 50, height: 18, fontSize: 13, bold: true)
        voiceTitle.stringValue = "Voice"

        voicePopup = NSPopUpButton(frame: NSRect(x: 66, y: voiceBoxH - 28, width: boxW - 80, height: 24))
        populateVoicePicker()
        voicePopup.target = self
        voicePopup.action = #selector(voiceChanged)
        voicev.addSubview(voicePopup)

        hourlyChimeCheckbox = NSButton(frame: NSRect(x: 14, y: 10, width: boxW - 28, height: 18))
        hourlyChimeCheckbox.setButtonType(.switch)
        hourlyChimeCheckbox.title = "Play chime at the hour"
        hourlyChimeCheckbox.state = hourlyChimeEnabled ? .on : .off
        hourlyChimeCheckbox.target = self
        hourlyChimeCheckbox.action = #selector(hourlyChimeToggled)
        voicev.addSubview(hourlyChimeCheckbox)

        y -= 10

        // ── System Group ──
        let systemBoxH: CGFloat = 188
        y -= systemBoxH
        let systemBox = makeGroupBox(in: view, x: margin, y: y, width: boxW, height: systemBoxH)
        let sysv = systemBox.contentView!

        startAtLoginCheckbox = NSButton(frame: NSRect(x: 14, y: systemBoxH - 28, width: boxW - 28, height: 18))
        startAtLoginCheckbox.setButtonType(.switch)
        startAtLoginCheckbox.title = "Start at login"
        startAtLoginCheckbox.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
        startAtLoginCheckbox.target = self
        startAtLoginCheckbox.action = #selector(toggleStartAtLogin)
        sysv.addSubview(startAtLoginCheckbox)

        let hotkeyTitle = makeLabel(in: sysv, x: 14, y: systemBoxH - 52, width: 200, height: 18, fontSize: 13, bold: true)
        hotkeyTitle.stringValue = "Global Hotkeys (⌃⇧ + key)"

        // Hotkey row 1: Announce time
        let hk1Label = makeLabel(in: sysv, x: 14, y: systemBoxH - 76, width: 150, height: 20, fontSize: 11)
        hk1Label.stringValue = "Announce time"
        hkAnnounceBtn = makeHotkeyButton(in: sysv, x: boxW - 90, y: systemBoxH - 78, key: hotkeyAnnounce)
        hkAnnounceBtn.tag = 1
        hkAnnounceBtn.target = self
        hkAnnounceBtn.action = #selector(startRecordingHotkey(_:))

        // Hotkey row 2: Toggle mute
        let hk2Label = makeLabel(in: sysv, x: 14, y: systemBoxH - 102, width: 150, height: 20, fontSize: 11)
        hk2Label.stringValue = "Toggle mute"
        hkMuteBtn = makeHotkeyButton(in: sysv, x: boxW - 90, y: systemBoxH - 104, key: hotkeyMute)
        hkMuteBtn.tag = 2
        hkMuteBtn.target = self
        hkMuteBtn.action = #selector(startRecordingHotkey(_:))

        // Hotkey row 3: Open app
        let hk3Label = makeLabel(in: sysv, x: 14, y: systemBoxH - 128, width: 150, height: 20, fontSize: 11)
        hk3Label.stringValue = "Open app window"
        hkOpenBtn = makeHotkeyButton(in: sysv, x: boxW - 90, y: systemBoxH - 130, key: hotkeyOpen)
        hkOpenBtn.tag = 3
        hkOpenBtn.target = self
        hkOpenBtn.action = #selector(startRecordingHotkey(_:))

        hotkeyStatusLabel = makeLabel(in: sysv, x: 14, y: 8, width: boxW - 28, height: 14, fontSize: 10)
        hotkeyStatusLabel.textColor = .tertiaryLabelColor

        // Clickable link to open Accessibility settings
        let openSettingsBtn = NSButton(frame: NSRect(x: boxW - 80, y: 6, width: 66, height: 18))
        openSettingsBtn.bezelStyle = .inline
        openSettingsBtn.title = "Fix it →"
        openSettingsBtn.font = NSFont.systemFont(ofSize: 10)
        openSettingsBtn.target = self
        openSettingsBtn.action = #selector(openAccessibilitySettings)
        sysv.addSubview(openSettingsBtn)

        updateAccessibilityStatus()
    }

    func makeHotkeyButton(in parent: NSView, x: CGFloat, y: CGFloat, key: String) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: y, width: 76, height: 24))
        btn.bezelStyle = .rounded
        btn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        btn.title = formatHotkey(key)
        parent.addSubview(btn)
        return btn
    }

    func formatHotkey(_ key: String) -> String {
        return "⌃⇧\(key.uppercased())"
    }

    @objc func startRecordingHotkey(_ sender: NSButton) {
        // Determine which action we're recording for
        switch sender.tag {
        case 1: recordingHotkeyFor = "announce"
        case 2: recordingHotkeyFor = "mute"
        case 3: recordingHotkeyFor = "open"
        default: return
        }
        sender.title = "Press key…"
        sender.isHighlighted = true
    }

    func isHotkeyAvailable(_ key: String, excluding action: String) -> Bool {
        if action != "announce" && hotkeyAnnounce == key { return false }
        if action != "mute" && hotkeyMute == key { return false }
        if action != "open" && hotkeyOpen == key { return false }
        return true
    }

    func flashButtonRed(_ button: NSButton) {
        let original = button.title
        button.contentTintColor = .systemRed
        button.title = "In use!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            button.contentTintColor = nil
            button.title = original
        }
    }

    func finishRecordingHotkey(key: String) {
        guard let action = recordingHotkeyFor else { return }
        let lowKey = key.lowercased()

        // Only accept single letters and digits
        guard lowKey.count == 1, lowKey.first!.isLetter || lowKey.first!.isNumber else {
            cancelRecording()
            return
        }

        // Conflict check
        if !isHotkeyAvailable(lowKey, excluding: action) {
            // Find which button to flash
            let btn: NSButton
            switch action {
            case "announce": btn = hkAnnounceBtn
            case "mute": btn = hkMuteBtn
            case "open": btn = hkOpenBtn
            default: cancelRecording(); return
            }
            flashButtonRed(btn)
            recordingHotkeyFor = nil
            // Restore original key display after flash
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.updateHotkeyButtonTitles()
            }
            return
        }

        // Apply the new key
        switch action {
        case "announce":
            hotkeyAnnounce = lowKey
            savePreference("TAHotkeyAnnounce", value: lowKey)
        case "mute":
            hotkeyMute = lowKey
            savePreference("TAHotkeyMute", value: lowKey)
        case "open":
            hotkeyOpen = lowKey
            savePreference("TAHotkeyOpen", value: lowKey)
        default: break
        }

        recordingHotkeyFor = nil
        updateHotkeyButtonTitles()
    }

    func cancelRecording() {
        recordingHotkeyFor = nil
        updateHotkeyButtonTitles()
    }

    func updateHotkeyButtonTitles() {
        hkAnnounceBtn.title = formatHotkey(hotkeyAnnounce)
        hkMuteBtn.title = formatHotkey(hotkeyMute)
        hkOpenBtn.title = formatHotkey(hotkeyOpen)
    }

    @objc func openAccessibilitySettings() {
        // Reset the TCC prompt so user gets a fresh ask
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Also open System Settings directly
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func formatHour(_ h: Int) -> String {
        if h == 0 { return "12:00 AM" }
        if h < 12 { return "\(h):00 AM" }
        if h == 12 { return "12:00 PM" }
        return "\(h - 12):00 PM"
    }

    func populateVoicePicker() {
        // Only allow real human-sounding voices (whitelist approach)
        let realVoices: Set<String> = [
            "Daniel", "Samantha", "Karen", "Moira", "Rishi",
            "Aman", "Tara", "Tessa"
        ]

        let voices = AVSpeechSynthesisVoice.speechVoices()
        let langPrefix = Locale.current.language.languageCode?.identifier ?? "en"
        let filtered = voices.filter {
            $0.language.hasPrefix(langPrefix) && realVoices.contains($0.name)
        }
        let sorted = filtered.sorted { $0.name < $1.name }

        voicePopup.removeAllItems()
        voicePopup.addItem(withTitle: "System Default")
        voicePopup.lastItem?.representedObject = nil

        var selectedIndex = 0
        for (i, voice) in sorted.enumerated() {
            let quality = voice.quality == .enhanced ? " (Enhanced)" : ""
            voicePopup.addItem(withTitle: "\(voice.name)\(quality)")
            voicePopup.lastItem?.representedObject = voice.identifier as NSString
            if voice.identifier == selectedVoiceIdentifier {
                selectedIndex = i + 1  // +1 for "System Default"
            }
        }
        voicePopup.selectItem(at: selectedIndex)
    }

    func updateAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        hotkeyStatusLabel.stringValue = trusted
            ? "✅ Accessibility: Granted"
            : "⚠️ Accessibility: Not granted — hotkeys won't work outside this app"
        hotkeyStatusLabel.textColor = trusted ? .systemGreen : .systemOrange
    }

    // MARK: - Log Tab

    func buildLogTab(_ view: NSView) {
        let w = view.frame.width
        let h = view.frame.height
        let btnBarH: CGFloat = 36

        // Button bar at bottom
        let shareBtn = NSButton(frame: NSRect(x: 16, y: 8, width: 80, height: 28))
        shareBtn.bezelStyle = .rounded
        shareBtn.title = "Share…"
        shareBtn.target = self
        shareBtn.action = #selector(shareLog)
        view.addSubview(shareBtn)

        let clearBtn = NSButton(frame: NSRect(x: 102, y: 8, width: 80, height: 28))
        clearBtn.bezelStyle = .rounded
        clearBtn.title = "Clear Log"
        clearBtn.target = self
        clearBtn.action = #selector(clearLog)
        view.addSubview(clearBtn)

        let scrollView = NSScrollView(frame: NSRect(x: 16, y: btnBarH + 4, width: w - 32, height: h - btnBarH - 16))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        view.addSubview(scrollView)

        logScrollView = scrollView
        logTextView = textView
        refreshLogView()
    }

    @objc func shareLog() {
        let fileURL = URL(fileURLWithPath: logPath)
        guard FileManager.default.fileExists(atPath: logPath) else { return }
        let picker = NSSharingServicePicker(items: [fileURL])
        picker.show(relativeTo: .zero, of: window.contentView!, preferredEdge: .minY)
    }

    @objc func clearLog() {
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        logEvent("LOG_CLEARED")
        refreshLogView()
    }

    func startLogRefreshTimer() {
        logRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.tabView.selectedTabViewItem?.identifier as? String == "log" {
                self.refreshLogView()
            }
        }
        RunLoop.main.add(logRefreshTimer!, forMode: .common)
    }

    func refreshLogView() {
        guard let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: "\n")
        let tail = lines.suffix(200).joined(separator: "\n")

        let sv = logScrollView!
        let tv = logTextView!
        let visibleRect = sv.contentView.bounds
        let contentHeight = tv.frame.height
        let wasAtBottom = visibleRect.origin.y + visibleRect.height >= contentHeight - 20

        tv.string = tail

        if wasAtBottom {
            tv.scrollToEndOfDocument(nil)
        }
    }

    // MARK: - Menu Bar Mode

    func setupMenuBarMode() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: "Time Announcer")
            button.target = self
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 340)
        popover?.behavior = .transient
        popover?.animates = true
        popover?.delegate = self

        let vc = NSViewController()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 340))
        buildPopoverContent(v)
        vc.view = v
        popover?.contentViewController = vc

        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func teardownMenuBarMode() {
        popover?.close()
        popover = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    @objc func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusBarContextMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    func togglePopover(_ sender: NSView) {
        guard let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func showStatusBarContextMenu(_ sender: NSView) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Announce Now", action: #selector(announceNowAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        if isMuted {
            menu.addItem(NSMenuItem(title: "Unmute", action: #selector(unmuteAction), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Mute 15 min", action: #selector(quickMuteAction), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Settings…", action: #selector(openSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        let switchItem = NSMenuItem(title: "Switch to Floating Window", action: #selector(switchToFloatingMode), keyEquivalent: "")
        menu.addItem(switchItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // Reset so left-click still works
    }

    func buildPopoverContent(_ v: NSView) {
        let w = v.frame.width
        var y = v.frame.height - 16

        // Status
        let popStatusLabel = NSTextField(frame: NSRect(x: 16, y: y - 22, width: w - 32, height: 22))
        popStatusLabel.isEditable = false; popStatusLabel.isBordered = false; popStatusLabel.drawsBackground = false
        popStatusLabel.font = NSFont.boldSystemFont(ofSize: 15)
        popStatusLabel.tag = 100  // We'll find it by tag in refreshUI
        v.addSubview(popStatusLabel)
        y -= 30

        // Next announcement
        let popNextLabel = NSTextField(frame: NSRect(x: 16, y: y - 16, width: w - 32, height: 16))
        popNextLabel.isEditable = false; popNextLabel.isBordered = false; popNextLabel.drawsBackground = false
        popNextLabel.font = NSFont.systemFont(ofSize: 11)
        popNextLabel.textColor = .secondaryLabelColor
        popNextLabel.tag = 101
        v.addSubview(popNextLabel)
        y -= 28

        // Separator
        let sep1 = NSBox(frame: NSRect(x: 16, y: y, width: w - 32, height: 1))
        sep1.boxType = .separator
        v.addSubview(sep1)
        y -= 16

        // Toggle + Announce Now buttons
        let toggleBtn = NSButton(frame: NSRect(x: 16, y: y - 28, width: 120, height: 28))
        toggleBtn.bezelStyle = .rounded
        toggleBtn.title = enabled ? "Turn Off" : "Turn On"
        toggleBtn.target = self
        toggleBtn.action = #selector(toggleEnabled)
        toggleBtn.tag = 102
        v.addSubview(toggleBtn)

        let annBtn = NSButton(frame: NSRect(x: 146, y: y - 28, width: 138, height: 28))
        annBtn.bezelStyle = .rounded
        annBtn.title = "Announce Now"
        annBtn.target = self
        annBtn.action = #selector(announceNowAction)
        v.addSubview(annBtn)
        y -= 42

        // Volume
        let volTitle = NSTextField(frame: NSRect(x: 16, y: y - 14, width: 55, height: 14))
        volTitle.isEditable = false; volTitle.isBordered = false; volTitle.drawsBackground = false
        volTitle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        volTitle.stringValue = "Volume"
        v.addSubview(volTitle)

        let popVolSlider = NSSlider(frame: NSRect(x: 72, y: y - 16, width: w - 130, height: 20))
        popVolSlider.minValue = 0; popVolSlider.maxValue = 100
        popVolSlider.integerValue = Int(speechVolume * 100)
        popVolSlider.target = self
        popVolSlider.action = #selector(popoverVolumeChanged(_:))
        popVolSlider.tag = 103
        v.addSubview(popVolSlider)

        let popVolLabel = NSTextField(frame: NSRect(x: w - 50, y: y - 14, width: 40, height: 14))
        popVolLabel.isEditable = false; popVolLabel.isBordered = false; popVolLabel.drawsBackground = false
        popVolLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        popVolLabel.alignment = .right
        popVolLabel.tag = 104
        v.addSubview(popVolLabel)
        y -= 30

        // Mute
        let muteBtn = NSButton(frame: NSRect(x: 16, y: y - 28, width: 100, height: 28))
        muteBtn.bezelStyle = .rounded
        muteBtn.title = isMuted ? "Unmute" : "Mute 15m"
        muteBtn.target = self
        muteBtn.action = #selector(popoverMuteToggle)
        muteBtn.tag = 105
        v.addSubview(muteBtn)

        let muteStatus = NSTextField(frame: NSRect(x: 120, y: y - 24, width: w - 136, height: 16))
        muteStatus.isEditable = false; muteStatus.isBordered = false; muteStatus.drawsBackground = false
        muteStatus.font = NSFont.systemFont(ofSize: 11)
        muteStatus.textColor = .systemOrange
        muteStatus.tag = 106
        v.addSubview(muteStatus)
        y -= 42

        // Separator
        let sep2 = NSBox(frame: NSRect(x: 16, y: y, width: w - 32, height: 1))
        sep2.boxType = .separator
        v.addSubview(sep2)
        y -= 16

        // Open Settings button
        let settingsBtn = NSButton(frame: NSRect(x: 16, y: y - 28, width: w - 32, height: 28))
        settingsBtn.bezelStyle = .rounded
        settingsBtn.title = "Open Settings…"
        settingsBtn.target = self
        settingsBtn.action = #selector(openSettingsWindow)
        v.addSubview(settingsBtn)
    }

    @objc func popoverVolumeChanged(_ sender: NSSlider) {
        speechVolume = Float(sender.integerValue) / 100.0
        savePreference("TAVolume", value: sender.integerValue)
        volumeSlider.integerValue = sender.integerValue
        refreshUI()
    }

    @objc func popoverMuteToggle() {
        if isMuted {
            unmuteAction()
        } else {
            quickMuteAction()
        }
    }

    @objc func quickMuteAction() {
        isMuted = true
        muteEndDate = Date().addingTimeInterval(15 * 60)
        muteTimer?.invalidate()
        muteTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { [weak self] _ in
            self?.unmuteAction()
        }
        logEvent("MUTED duration=15min")
        refreshUI()
    }

    @objc func openSettingsWindow() {
        popover?.close()
        // Temporarily become regular app to show window
        if displayMode == .menuBar {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Select Settings tab
        tabView.selectTabViewItem(at: 1)
    }

    @objc func switchToFloatingMode() {
        switchDisplayMode(to: .floatingWindow)
    }

    @objc func switchToMenuBarMode() {
        switchDisplayMode(to: .menuBar)
    }

    // NSPopoverDelegate
    func popoverDidClose(_ notification: Notification) {
        // If in menu bar mode and main window is not visible, go back to accessory
        if displayMode == .menuBar && !window.isVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Floating Window Mode

    func setupFloatingMode() {
        let panelW: CGFloat = 220
        let panelH: CGFloat = 88

        floatingPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        floatingPanel?.title = "Time"
        floatingPanel?.level = .floating
        floatingPanel?.isFloatingPanel = true
        floatingPanel?.hidesOnDeactivate = false
        floatingPanel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel?.isReleasedWhenClosed = false
        floatingPanel?.isMovableByWindowBackground = true

        let content = floatingPanel!.contentView!
        content.wantsLayer = true

        // Status dot
        floatingStatusDot = NSTextField(frame: NSRect(x: 10, y: panelH - 42, width: 16, height: 20))
        floatingStatusDot?.isEditable = false; floatingStatusDot?.isBordered = false; floatingStatusDot?.drawsBackground = false
        floatingStatusDot?.font = NSFont.systemFont(ofSize: 14)
        content.addSubview(floatingStatusDot!)

        // Time label (big)
        floatingTimeLabel = NSTextField(frame: NSRect(x: 26, y: panelH - 46, width: panelW - 36, height: 30))
        floatingTimeLabel?.isEditable = false; floatingTimeLabel?.isBordered = false; floatingTimeLabel?.drawsBackground = false
        floatingTimeLabel?.font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        content.addSubview(floatingTimeLabel!)

        // Next announcement label
        floatingNextLabel = NSTextField(frame: NSRect(x: 10, y: 6, width: panelW - 20, height: 16))
        floatingNextLabel?.isEditable = false; floatingNextLabel?.isBordered = false; floatingNextLabel?.drawsBackground = false
        floatingNextLabel?.font = NSFont.systemFont(ofSize: 11)
        floatingNextLabel?.textColor = .secondaryLabelColor
        content.addSubview(floatingNextLabel!)

        // Right-click context menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Announce Now", action: #selector(announceNowAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Settings…", action: #selector(openSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Switch to Menu Bar", action: #selector(switchToMenuBarMode), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        content.menu = menu

        // Position top-right
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            floatingPanel?.setFrameOrigin(NSPoint(x: sf.maxX - panelW - 20, y: sf.maxY - panelH - 20))
        }

        NSApp.setActivationPolicy(.regular)
        floatingPanel?.orderFront(nil)
    }

    func teardownFloatingMode() {
        floatingPanel?.orderOut(nil)
        floatingPanel = nil
        floatingTimeLabel = nil
        floatingNextLabel = nil
        floatingStatusDot = nil
    }

    // MARK: - Mode Switching

    func switchDisplayMode(to mode: DisplayMode) {
        guard mode != displayMode else { return }
        let old = displayMode
        displayMode = mode
        savePreference("TADisplayMode", value: mode.rawValue)

        // Tear down old
        switch old {
        case .menuBar: teardownMenuBarMode()
        case .floatingWindow: teardownFloatingMode()
        }

        // Set up new
        switch mode {
        case .menuBar:
            window.orderOut(nil)
            setupMenuBarMode()
        case .floatingWindow:
            window.orderOut(nil)
            setupFloatingMode()
        }

        // Sync the segment control
        modeSegment?.selectedSegment = mode == .menuBar ? 0 : 1

        logEvent("MODE_SWITCH to=\(mode.rawValue)")
        refreshUI()
    }

    // MARK: - Helpers

    func makeLabel(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 20, fontSize: CGFloat, bold: Bool = false) -> NSTextField {
        let label = NSTextField(frame: NSRect(x: x, y: y, width: width, height: height))
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        label.stringValue = ""
        parent.addSubview(label)
        return label
    }

    // MARK: - UI Refresh

    func startUIUpdateTimer() {
        uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
        RunLoop.main.add(uiUpdateTimer!, forMode: .common)
    }

    func refreshUI() {
        // Status
        if !enabled {
            statusLabel.stringValue = "⏸ Disabled"
            statusLabel.textColor = .secondaryLabelColor
        } else if isMuted {
            statusLabel.stringValue = "🔇 Muted"
            statusLabel.textColor = .systemOrange
        } else if !lidOpen {
            statusLabel.stringValue = "💤 Lid Closed"
            statusLabel.textColor = .secondaryLabelColor
        } else if !inActiveHours {
            statusLabel.stringValue = "😴 Outside active hours"
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = "🔊 Active"
            statusLabel.textColor = .systemGreen
        }

        // Next announcement countdown
        let now = Date()
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: now)
        let second = calendar.component(.second, from: now)
        let secsUntilNext = (announcementInterval - (minute % announcementInterval)) * 60 - second
        let mins = secsUntilNext / 60
        let secs = secsUntilNext % 60
        nextAnnounceLabel.stringValue = "Next: \(mins)m \(secs)s  (every \(announcementInterval) min)"

        // Lid state
        lidLabel.stringValue = lidOpen ? "Lid: Open" : "Lid: Closed — announcements paused"

        // Toggle button
        toggleButton.title = enabled ? "Turn Off" : "Turn On"

        // Mute remaining
        if isMuted, let endDate = muteEndDate {
            let remaining = Int(endDate.timeIntervalSinceNow)
            if remaining <= 0 {
                unmuteAction()
            } else {
                let m = remaining / 60
                let s = remaining % 60
                muteRemainingLabel.stringValue = "Muted — \(m)m \(s)s remaining"
                unmuteButton.isHidden = false
            }
        } else {
            muteRemainingLabel.stringValue = ""
            unmuteButton.isHidden = true
        }

        // Volume label
        volumeLabel.stringValue = "\(Int(speechVolume * 100))%"

        // Refresh accessibility status (checks live)
        updateAccessibilityStatus()

        // ── Update floating panel ──
        if let fp = floatingPanel, fp.isVisible {
            let df = DateFormatter()
            df.dateFormat = "h:mm:ss a"
            floatingTimeLabel?.stringValue = df.string(from: Date())
            floatingNextLabel?.stringValue = "Next in \(mins)m \(secs)s"
            if canSpeak {
                floatingStatusDot?.stringValue = "🟢"
            } else if !enabled {
                floatingStatusDot?.stringValue = "⏸"
            } else if isMuted {
                floatingStatusDot?.stringValue = "🔇"
            } else {
                floatingStatusDot?.stringValue = "💤"
            }
        }

        // ── Update popover controls ──
        if let pop = popover, pop.isShown, let v = pop.contentViewController?.view {
            if let statusLbl = v.viewWithTag(100) as? NSTextField {
                statusLbl.stringValue = statusLabel.stringValue
                statusLbl.textColor = statusLabel.textColor
            }
            if let nextLbl = v.viewWithTag(101) as? NSTextField {
                nextLbl.stringValue = "Next: \(mins)m \(secs)s"
            }
            if let togBtn = v.viewWithTag(102) as? NSButton {
                togBtn.title = enabled ? "Turn Off" : "Turn On"
            }
            if let slider = v.viewWithTag(103) as? NSSlider {
                slider.integerValue = Int(speechVolume * 100)
            }
            if let volLbl = v.viewWithTag(104) as? NSTextField {
                volLbl.stringValue = "\(Int(speechVolume * 100))%"
            }
            if let muteBtn = v.viewWithTag(105) as? NSButton {
                muteBtn.title = isMuted ? "Unmute" : "Mute 15m"
            }
            if let muteLbl = v.viewWithTag(106) as? NSTextField {
                if isMuted, let endDate = muteEndDate {
                    let rem = Int(endDate.timeIntervalSinceNow)
                    muteLbl.stringValue = "Muted — \(rem/60)m \(rem%60)s"
                } else {
                    muteLbl.stringValue = ""
                }
            }
        }

        // ── Update status bar icon tooltip ──
        statusItem?.button?.toolTip = "Time Announcer — " + (canSpeak ? "Active" : (enabled ? (isMuted ? "Muted" : "Paused") : "Off"))
    }

    // MARK: - Timer Scheduling

    func scheduleNextAnnouncement() {
        primaryTimer?.cancel()
        primaryTimer = nil

        let now = Date()
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: now)
        let second = calendar.component(.second, from: now)

        let minutesUntilNext = announcementInterval - (minute % announcementInterval)
        var secondsUntilNext = Double(minutesUntilNext * 60 - second)
        if secondsUntilNext <= 0 { secondsUntilNext += Double(announcementInterval * 60) }

        let targetTime = now.addingTimeInterval(secondsUntilNext)

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        let wallTime = DispatchWallTime(timespec: timespec(
            tv_sec: Int(targetTime.timeIntervalSince1970), tv_nsec: 0
        ))
        timer.schedule(wallDeadline: wallTime)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Live lid check before speaking
            if isLidClosed() {
                if self.lidOpen {
                    self.lidOpen = false
                    logEvent("LID_CLOSED (detected at timer)")
                    if self.synthesizer.isSpeaking { self.synthesizer.stopSpeaking(at: .immediate) }
                }
            } else {
                self.speakTime()
            }
            self.scheduleNextAnnouncement()
        }
        timer.resume()
        primaryTimer = timer
    }

    func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    func startBackupWatchdog() {
        backupWatchdog?.cancel()
        backupWatchdog = nil
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(wallDeadline: .now() + 7, repeating: 7, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.watchdogTick() }
        }
        timer.resume()
        backupWatchdog = timer
    }

    func registerLidNotification() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return }
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notifyPort else { IOObjectRelease(service); return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { (refcon, _, _, _) in
            guard let refcon = refcon else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            delegate.handlePowerNotification()
        }, selfPtr, &notifier)
        IOObjectRelease(service)
    }

    func handlePowerNotification() {
        let wasLidOpen = lidOpen
        lidOpen = !isLidClosed()
        if wasLidOpen && !lidOpen {
            logEvent("LID_CLOSED (IOKit notification)")
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        }
        if !wasLidOpen && lidOpen {
            logEvent("LID_OPENED (IOKit notification)")
            scheduleNextAnnouncement()
        }
        refreshUI()
    }

    func watchdogTick() {
        // Poll physical lid sensor
        let wasLidOpen = lidOpen
        lidOpen = !isLidClosed()

        if wasLidOpen && !lidOpen {
            logEvent("LID_CLOSED")
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        }
        if !wasLidOpen && lidOpen {
            logEvent("LID_OPENED")
            scheduleNextAnnouncement()
        }

        if isMuted { updateMuteTimer() }

        // Catch missed announcements
        guard canSpeak else { return }

        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let second = calendar.component(.second, from: now)
        let slotMinute = minute - (minute % announcementInterval)
        let currentSlot = String(format: "%02d:%02d", hour, slotMinute)

        if currentSlot != lastAnnouncedSlot {
            let secondsIntoSlot = (minute - slotMinute) * 60 + second
            let graceWindow = min(120, announcementInterval * 60 / 2)
            if secondsIntoSlot < graceWindow { speakTime() }
            scheduleNextAnnouncement()
        }
    }

    func updateMuteTimer() {
        guard let endDate = muteEndDate else { return }
        if endDate.timeIntervalSinceNow <= 0 { unmuteAction() }
    }

    // MARK: - Global Hotkey

    func registerGlobalHotkey() {
        // Request accessibility permission (shows prompt on first run)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            // Ignore global hotkeys while recording a new key
            if self.recordingHotkeyFor != nil { return }
            self.handleHotkeyEvent(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // If recording, capture the key for assignment
            if self.recordingHotkeyFor != nil {
                if let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 {
                    if event.keyCode == 53 { // Escape
                        self.cancelRecording()
                    } else {
                        self.finishRecordingHotkey(key: chars)
                    }
                }
                return nil  // Consume the event
            }
            self.handleHotkeyEvent(event)
            return event
        }
    }

    func handleHotkeyEvent(_ event: NSEvent) {
        guard event.modifierFlags.contains([.control, .shift]) else { return }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return }

        if chars == hotkeyAnnounce {
            announceNowAction()
        } else if chars == hotkeyMute {
            if isMuted { unmuteAction() } else {
                // Quick mute for 15 min via hotkey
                isMuted = true
                muteEndDate = Date().addingTimeInterval(15 * 60)
                muteTimer?.invalidate()
                muteTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { [weak self] _ in
                    self?.unmuteAction()
                }
                refreshUI()
            }
        } else if chars == hotkeyOpen {
            switch displayMode {
            case .menuBar:
                if let button = statusItem?.button {
                    togglePopover(button)
                }
            case .floatingWindow:
                openSettingsWindow()
            }
        }
    }

    // MARK: - Speech

    func speakTime() {
        // LIVE hardware check — eliminates race with cached state
        if isLidClosed() {
            if lidOpen {
                lidOpen = false
                logEvent("LID_CLOSED (detected at speak)")
                if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
                sayProcess?.terminate(); sayProcess = nil
            }
            return
        }
        guard canSpeak else { return }

        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let slotMinute = minute - (minute % announcementInterval)
        let currentSlot = String(format: "%02d:%02d", hour, slotMinute)

        guard currentSlot != lastAnnouncedSlot else { return }
        lastAnnouncedSlot = currentSlot

        var displayHour = hour % 12
        if displayHour == 0 { displayHour = 12 }

        let secondsIntoSlot = (minute - slotMinute) * 60 + Calendar.current.component(.second, from: now)

        if slotMinute == 0 {
            // Hourly — simple "X o'clock"
            let text = "\(displayHour) o'clock"
            logEvent("ANNOUNCE slot=\(currentSlot) delay=\(secondsIntoSlot)s text=\"\(text)\" hourly=true")

            if hourlyChimeEnabled {
                if let chime = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true) {
                    chime.play()
                } else {
                    NSSound.beep()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.speak(text)
                }
            } else {
                speak(text)
            }
        } else {
            let text = "\(displayHour) \(slotMinute)"
            logEvent("ANNOUNCE slot=\(currentSlot) delay=\(secondsIntoSlot)s text=\"\(text)\"")
            speak(text)
        }
    }

    @objc func announceNowAction() {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)

        var displayHour = hour % 12
        if displayHour == 0 { displayHour = 12 }

        let text = minute == 0 ? "\(displayHour) o'clock" : "\(displayHour) \(minute)"
        speak(text)
    }

    /// Query macOS system audio state via osascript — returns (volume 0-100, muted, outputDevice)
    private func getAudioState() -> (vol: Int, muted: Bool, device: String) {
        // Single osascript call for volume+muted (fast)
        let volProc = Process()
        volProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        volProc.arguments = ["-e", "output volume of (get volume settings) & \",\" & output muted of (get volume settings)"]
        let volPipe = Pipe()
        volProc.standardOutput = volPipe
        volProc.standardError = Pipe()
        let volStr: String
        do {
            try volProc.run()
            volProc.waitUntilExit()
            volStr = String(data: volPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch { volStr = "error" }

        // Get output device via CoreAudio name (faster than system_profiler)
        let devProc = Process()
        devProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        devProc.arguments = ["-e", "do shell script \"system_profiler SPAudioDataType 2>/dev/null | grep -B1 'Default Output Device: Yes' | head -1 | sed 's/^ *//' | sed 's/://g'\""]
        let devPipe = Pipe()
        devProc.standardOutput = devPipe
        devProc.standardError = Pipe()
        let devStr: String
        do {
            try devProc.run()
            devProc.waitUntilExit()
            devStr = String(data: devPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        } catch { devStr = "error" }

        let parts = volStr.split(separator: ",")
        let volume = parts.count > 0 ? Int(parts[0].trimmingCharacters(in: .whitespaces)) ?? -1 : -1
        let muted = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) == "true" : false
        return (volume, muted, devStr)
    }

    /// Force audio to built-in speakers if a virtual device (Loom, BlackHole, etc.) has stolen the output
    private func ensureBuiltInSpeakers(_ currentDevice: String) {
        let virtuals = ["loom", "blackhole", "soundflower", "loopback", "obs", "virtual"]
        let isVirtual = virtuals.contains(where: { currentDevice.lowercased().contains($0) })
        if isVirtual {
            logEvent("AUDIO_DEVICE_FIX switching from \"\(currentDevice)\" to built-in speakers")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // SwitchAudioSource isn't guaranteed — use osascript to set output to internal
            proc.arguments = ["-e", "do shell script \"SwitchAudioSource -s 'MacBook Pro Speakers' 2>/dev/null || true\""]
            proc.standardError = Pipe()
            proc.standardOutput = Pipe()
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    /// NUCLEAR AUDIO FIX — Three-phase speech with volume compensation.
    ///
    /// Root cause analysis:
    /// - macOS `say` and `afplay` ALWAYS exit 0, even when audio route is dead
    /// - System volume at 38% makes speech inaudible in any ambient noise
    /// - Loom virtual audio device can silently steal output
    /// - Speech is < 1 second — easy to miss entirely
    ///
    /// Fix:
    /// 1. Force unmute + raise system volume to minimum 50% before speaking
    /// 2. Force audio to built-in speakers if virtual device detected
    /// 3. Render speech to AIFF file (verifiable)
    /// 4. Play via afplay with AMPLIFICATION (compensates for low system volume)
    /// 5. Play a pre-speech "tick" sound as audio canary
    /// 6. Log actual playback duration vs expected — flag suspiciously short plays
    private func speak(_ text: String) {
        // Kill any in-progress speech
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if let prev = sayProcess, prev.isRunning { prev.terminate() }
        sayProcess = nil

        // ── Step 1: Check and fix audio state ──
        let audio = getAudioState()
        let audioTag = "sysVol=\(audio.vol)% muted=\(audio.muted) device=\"\(audio.device)\""

        // Force unmute + minimum 60% system volume
        if audio.muted || audio.vol < 60 {
            let targetVol = max(65, audio.vol)
            logEvent("AUDIO_FIX boosting from \(audioTag) → \(targetVol)%")
            let fixProc = Process()
            fixProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            fixProc.arguments = ["-e", "set volume without output muted", "-e", "set volume output volume \(targetVol)"]
            fixProc.standardError = Pipe()
            try? fixProc.run()
            fixProc.waitUntilExit()
        }

        // ── Step 2: Force built-in speakers if virtual device detected ──
        ensureBuiltInSpeakers(audio.device)

        // ── Step 3: Pre-speech alert chime ──
        // Play a LOUD, distinctive system sound before speaking.
        // The default `say` voice is monotone and easily missed — this chime
        // grabs attention so the user knows speech is coming.
        let chimeProc = Process()
        chimeProc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        chimeProc.arguments = ["-v", "2.5", "/System/Library/Sounds/Glass.aiff"]
        chimeProc.standardError = Pipe()
        try? chimeProc.run()
        chimeProc.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.2)

        // ── Step 4: Render speech to AIFF file ──
        let tmpFile = NSTemporaryDirectory() + "timeannouncer_speech.aiff"
        let sayProc = Process()
        sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var sayArgs = [String]()
        if let voiceName = selectedVoiceName {
            sayArgs.append(contentsOf: ["-v", voiceName])
        }
        // Render with higher sample rate for better quality
        sayArgs.append(contentsOf: ["-r", "180", "-o", tmpFile, text])
        sayProc.arguments = sayArgs

        let errPipe = Pipe()
        sayProc.standardError = errPipe

        do {
            try sayProc.run()
            logEvent("SPEECH_RENDER text=\"\(text)\" voice=\(selectedVoiceName ?? "default") \(audioTag)")
        } catch {
            logEvent("SPEECH_RENDER_FAIL text=\"\(text)\" error=\(error.localizedDescription)")
            return
        }

        // ── Step 5: Play with volume AMPLIFICATION ──
        // afplay -v supports values > 1.0 for amplification
        // We compensate for low system volume: if sysVol=38%, use -v 2.6 so effective ≈ 100%
        let sysVol = max(audio.vol, 60)  // After fix, should be at least 60
        let compensationFactor = min(4.0, max(1.5, 100.0 / Float(sysVol)))
        let afplayVol = speechVolume * compensationFactor

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            sayProc.waitUntilExit()
            let sayStatus = sayProc.terminationStatus

            guard sayStatus == 0 else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    logEvent("SPEECH_RENDER_FAIL text=\"\(text)\" exit=\(sayStatus) err=\"\(errStr)\"")
                }
                return
            }

            // Verify file has real content
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: tmpFile)[.size] as? Int) ?? 0
            guard fileSize > 100 else {
                DispatchQueue.main.async {
                    logEvent("SPEECH_RENDER_FAIL text=\"\(text)\" size=\(fileSize)")
                }
                return
            }

            // Play with amplification
            let playProc = Process()
            playProc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            playProc.arguments = ["-v", String(format: "%.2f", afplayVol), tmpFile]
            let playErr = Pipe()
            playProc.standardError = playErr

            do {
                let playStart = Date()
                try playProc.run()
                DispatchQueue.main.async {
                    self?.sayProcess = playProc
                    logEvent("SPEECH_PLAY text=\"\(text)\" size=\(fileSize)b afplayVol=\(String(format: "%.1f", afplayVol))x comp=\(String(format: "%.1f", compensationFactor))x")
                }
                playProc.waitUntilExit()
                let playDuration = Date().timeIntervalSince(playStart)
                let playStatus = playProc.terminationStatus

                DispatchQueue.main.async {
                    if playStatus == 0 {
                        // Flag suspiciously short playback (< 0.3s for a file that should be ~1s)
                        let warning = playDuration < 0.3 ? " ⚠️SUSPECT_SHORT" : ""
                        logEvent("SPEECH_DONE text=\"\(text)\" dur=\(String(format: "%.1f", playDuration))s\(warning)")
                    } else {
                        let pErr = String(data: playErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        logEvent("SPEECH_PLAY_FAIL text=\"\(text)\" exit=\(playStatus) err=\"\(pErr.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    logEvent("SPEECH_PLAY_FAIL text=\"\(text)\" error=\(error.localizedDescription)")
                }
            }

            try? FileManager.default.removeItem(atPath: tmpFile)
        }
    }

    // AVSpeechSynthesizerDelegate (for fallback only)
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        speechDidStart = true
    }

    // MARK: - Screen Sleep/Wake

    @objc func screenDidSleep() {
        screenAwake = false
        logEvent("SCREEN_SLEEP")
        primaryTimer?.cancel()
        primaryTimer = nil
    }

    @objc func screenDidWake() {
        screenAwake = true
        logEvent("SCREEN_WAKE")
        primaryTimer?.cancel()
        primaryTimer = nil
        scheduleNextAnnouncement()
    }

    // MARK: - Actions

    @objc func toggleEnabled() {
        enabled.toggle()
        if enabled {
            scheduleNextAnnouncement()
            startWatchdog()
            startBackupWatchdog()
        } else {
            primaryTimer?.cancel(); primaryTimer = nil
            watchdogTimer?.invalidate(); watchdogTimer = nil
            backupWatchdog?.cancel(); backupWatchdog = nil
        }
        refreshUI()
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        speechVolume = Float(sender.integerValue) / 100.0
        savePreference("TAVolume", value: sender.integerValue)
        refreshUI()
    }

    @objc func muteAction() {
        let durations = [15, 30, 60, 120]
        let minutes = durations[mutePopup.indexOfSelectedItem]
        isMuted = true
        muteEndDate = Date().addingTimeInterval(Double(minutes * 60))

        muteTimer?.invalidate()
        muteTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: false) { [weak self] _ in
            self?.unmuteAction()
        }
        refreshUI()
    }

    @objc func unmuteAction() {
        isMuted = false
        muteEndDate = nil
        muteTimer?.invalidate()
        muteTimer = nil
        refreshUI()
    }

    @objc func modeSegmentChanged() {
        let mode: DisplayMode = modeSegment.selectedSegment == 0 ? .menuBar : .floatingWindow
        switchDisplayMode(to: mode)
    }

    @objc func intervalChanged() {
        let values = [5, 10, 15, 30]
        announcementInterval = values[intervalPopup.indexOfSelectedItem]
        lastAnnouncedSlot = nil  // Prevent race on interval change
        savePreference("TAIntervalMinutes", value: announcementInterval)
        scheduleNextAnnouncement()
        refreshUI()
    }

    @objc func allDayToggled() {
        allDayEnabled = allDayCheckbox.state == .on
        startHourPopup.isEnabled = !allDayEnabled
        endHourPopup.isEnabled = !allDayEnabled
        savePreference("TAAllDay", value: allDayEnabled)
        refreshUI()
    }

    @objc func activeHoursChanged() {
        activeStartHour = startHourPopup.indexOfSelectedItem
        activeEndHour = endHourPopup.indexOfSelectedItem
        savePreference("TAActiveStartHour", value: activeStartHour)
        savePreference("TAActiveEndHour", value: activeEndHour)
        refreshUI()
    }

    @objc func voiceChanged() {
        if voicePopup.indexOfSelectedItem == 0 {
            selectedVoiceIdentifier = nil
            selectedVoiceName = nil
        } else {
            selectedVoiceIdentifier = voicePopup.selectedItem?.representedObject as? String
            let title = voicePopup.titleOfSelectedItem ?? ""
            selectedVoiceName = title.replacingOccurrences(of: " (Enhanced)", with: "")
        }
        savePreference("TAVoiceIdentifier", value: selectedVoiceIdentifier)
        savePreference("TAVoiceName", value: selectedVoiceName)

        // Preview the selected voice
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        var displayHour = hour % 12
        if displayHour == 0 { displayHour = 12 }
        let text = minute == 0 ? "\(displayHour) o'clock" : "\(displayHour) \(minute)"
        speak(text)
    }

    @objc func hourlyChimeToggled() {
        hourlyChimeEnabled = hourlyChimeCheckbox.state == .on
        savePreference("TAHourlyChime", value: hourlyChimeEnabled)
    }

    @objc func toggleStartAtLogin(_ sender: NSButton) {
        if sender.state == .on {
            writeLaunchAgentPlist()
        } else {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        }
    }

    func writeLaunchAgentPlist() {
        let plist: [String: Any] = [
            "Label": "com.mshrmnsr.timeannouncer",
            "ProgramArguments": ["/usr/bin/open", "-a",
                NSHomeDirectory() + "/claude1/time announcer/TimeAnnouncer.app"],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: URL(fileURLWithPath: launchAgentPath))
        }
    }

    // MARK: - Cleanup

    func applicationWillTerminate(_ notification: Notification) {
        primaryTimer?.cancel()
        watchdogTimer?.invalidate()
        backupWatchdog?.cancel()
        muteTimer?.invalidate()
        uiUpdateTimer?.invalidate()
        logRefreshTimer?.invalidate()
        synthesizer.stopSpeaking(at: .immediate)
        sayProcess?.terminate()
        if notifier != 0 { IOObjectRelease(notifier) }
        if let port = notifyPort { IONotificationPortDestroy(port) }
        if let monitor = globalKeyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
        // Clean up display mode resources
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        floatingPanel?.orderOut(nil)
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Build main menu (needed for Cmd+Q to work)
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "Quit Time Announcer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
