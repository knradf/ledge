import AppKit
import Combine
import SwiftUI

/// Owns every data source once, and one bar window per display.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paneru = PaneruStore()
    let battery = BatteryMonitor()
    let audio = AudioMonitor()
    let wifi = WiFiMonitor()
    let network = NetworkSpeedMonitor()
    let wallpaper = WallpaperTone()
    let bluetooth = BluetoothMonitor()
    let input = InputSourceMonitor()
    let audioActivity = AudioActivity()

    private var bars: [CGDirectDisplayID: BarWindow] = [:]
    private let fullscreen = FullscreenWatcher()
    private var hiddenDisplays: Set<CGDirectDisplayID> = []
    private var subscriptions: Set<AnyCancellable> = []
    private let overviewShortcut = OverviewShortcut()
    private let hotCorner = HotCorner()
    private let rules = WorkspaceRulesEngine()
    private let swipes = TrackpadSwipes()

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherCopies()
        paneru.start()
        rules.start(paneru)
        battery.start()
        audio.start()
        wifi.start()
        LedgeSettings.shared.$statusLayout
            .sink { [weak self] layout in self?.network.update(shown: layout.contains(.of(.network))) }
            .store(in: &subscriptions)
        wallpaper.start()
        input.start()
        audioActivity.start()
        NowPlayingStore.shared.start()
        // Bluetooth starts when its item is first shown (avoids a needless permission prompt)

        rebuildBars()
        fullscreen.onChange = { [weak self] covered in
            self?.hiddenDisplays = covered
            self?.applyVisibility()
        }
        fullscreen.start()
        startOverview()
        // light/dark bar per display. @Published fires before the value is
        // stored, so use the values the publisher hands over.
        Publishers.CombineLatest(wallpaper.$light, LedgeSettings.shared.$barAppearance)
            .sink { [weak self] light, mode in
                self?.wallpaper.enabled = mode == .wallpaper
                self?.applyAppearance(light: light, mode: mode)
            }
            .store(in: &subscriptions)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// After a permission change, System Settings offers "Quit & Reopen":
    /// it quits Ledge and macOS opens it again. Started by install.sh's
    /// LaunchAgent, the reopen doesn't happen, so restart through launchd.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard LoginItem.shared.launchAgent,
              let pid = NSAppleEventManager.shared().currentAppleEvent?
                  .attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value,
              let from = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              from.hasPrefix("com.apple.settings")
        else { return .terminateNow }
        Relaunch.now()
        return .terminateCancel
    }

    /// Two Ledges both act on every swipe and click (on 2026-11-17 a copy
    /// opened from Finder outlived every restart and swiped the old way).
    /// The newest one wins: a restart always leaves exactly one.
    private func quitOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where app.processIdentifier != me {
            NSLog("Ledge: quitting another copy of Ledge (pid \(app.processIdentifier))")
            if !app.terminate() { app.forceTerminate() }
        }
    }

    @objc private func screensChanged() {
        rebuildBars()
    }

    private func rebuildBars() {
        bars.values.forEach { $0.close() }
        bars = [:]
        for screen in NSScreen.screens {
            let root = BarView(displayID: screen.displayID)
                .environmentObject(paneru)
                .environmentObject(battery)
                .environmentObject(audio)
                .environmentObject(wifi)
                .environmentObject(network)
                .environmentObject(LedgeSettings.shared)
                .environmentObject(wallpaper)
                .environmentObject(bluetooth)
                .environmentObject(input)
                .environmentObject(audioActivity)
            bars[screen.displayID] = BarWindow(screen: screen, content: AnyView(root))
        }
        applyVisibility()
        applyAppearance(light: wallpaper.light, mode: LedgeSettings.shared.barAppearance)
    }

    /// ⌥O and the hot corner. The shortcut needs Accessibility; until it's
    /// granted, retry whenever you come back from another app (e.g. Settings).
    private func startOverview() {
        OverviewController.shared.watch(paneru)
        WorkspaceSlide.shared.watch(paneru)
        if !paneru.appsOnly,
           PaneruConfig.replaceLuaStub(ledgeSwipesVertically: LedgeSettings.shared.desktopSwipe != .off) {
            NSLog("Ledge: replaced Paneru's empty init.lua with paneru.toml, restarting Paneru")
            PaneruSettings.shared.reload()
            paneru.restartPaneru()
        }
        // keeps Paneru's top padding just below the bar
        // before the bar padding: an install from before the welcome keeps its setting
        Onboarding.shared.showIfNeeded(paneru: paneru)
        PaneruSettings.shared.followBarIfOn()

        hotCorner.position = { LedgeSettings.shared.hotCorner }
        hotCorner.action = { OverviewController.shared.toggle() }
        LedgeSettings.shared.$hotCorner
            .sink { [weak self] corner in self?.hotCorner.update(corner) }
            .store(in: &subscriptions)

        LedgeSettings.shared.$overviewShortcut
            .sink { [weak self] on in self?.overviewShortcut.enabled = on }
            .store(in: &subscriptions)
        overviewShortcut.action = { OverviewController.shared.toggle() }
        overviewShortcut.escapeAction = { [weak self] in
            if OverviewController.shared.model.isOpen {
                OverviewController.shared.escape()
            } else {
                self?.overviewShortcut.escapeArmed = false
            }
        }
        OverviewController.shared.onOpenChanged = { [weak self] open in
            self?.overviewShortcut.escapeArmed = open
        }
        swipes.onSwipe = { [weak self] up in self?.swiped(up: up) }
        let started = overviewShortcut.start()
        // the trackpad is only read while Ledge handles the swipes
        LedgeSettings.shared.$desktopSwipe
            .sink { [weak self] direction in
                if direction == .off {
                    self?.swipes.stop()
                    ThreeFingerScrollGate.shared.stop()
                } else {
                    self?.swipes.start()
                    ThreeFingerScrollGate.shared.start()
                }
            }
            .store(in: &subscriptions)
        // no Accessibility yet: the welcome and Settings ask for it (asking
        // here too would stack macOS's alert on top of the welcome)
        if !started {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, WindowFocus.trusted else { return }
                if !self.overviewShortcut.isRunning { self.overviewShortcut.start() }
            }
        }
    }

    /// Three fingers up/down: one workspace per swipe, when Ledge handles
    /// that instead of Paneru (and not in the overview, where two-finger
    /// scrolling moves around).
    private func swiped(up: Bool) {
        let direction = LedgeSettings.shared.desktopSwipe
        guard direction != .off, !OverviewController.shared.model.isOpen else { return }
        paneru.step(above: up == (direction == .upGoesAbove))
    }

    /// Setting the window's appearance switches the glass/frosted material and
    /// all text and symbols together. nil = follow the system.
    private func applyAppearance(light: [CGDirectDisplayID: Bool], mode: BarAppearance) {
        for (display, bar) in bars {
            let isLight: Bool?
            switch mode {
            case .wallpaper: isLight = light[display]  // unknown: follow the system
            case .system: isLight = nil
            case .light: isLight = true
            case .dark: isLight = false
            }
            if let isLight {
                bar.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
            } else {
                bar.appearance = nil
            }
        }
    }

    /// Hide the bar on displays where an app is covering the whole screen.
    private func applyVisibility() {
        for (display, bar) in bars {
            if hiddenDisplays.contains(display) {
                bar.orderOut(nil)
            } else {
                bar.orderFrontRegardless()
            }
        }
        if !hiddenDisplays.isEmpty { Dropdown.shared.close() }
    }
}
