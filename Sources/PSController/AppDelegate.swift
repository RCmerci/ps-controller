import AppKit
import GameController

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controllerManager = ControllerManager()

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var connectionItem: NSMenuItem?
    private var batteryItem: NSMenuItem?
    private var dependencyStatusItem: NSMenuItem?
    private var dependencyDetailItems: [NSMenuItem] = []
    private var toggleControlItem: NSMenuItem?
    private var restartASRServerItem: NSMenuItem?

    private var isRestartingASRServer = false {
        didSet {
            guard let restartASRServerItem else { return }
            restartASRServerItem.isEnabled = !isRestartingASRServer
            restartASRServerItem.title = isRestartingASRServer ? "Restarting ASR Server..." : "Restart ASR Server"
        }
    }

    private var batteryPollingTimer: DispatchSourceTimer?
    private var latestConnectionState: ControllerConnectionState = .disconnected
    private var latestBatteryPercent: Int?

    private var isControlEnabled = true {
        didSet {
            toggleControlItem?.title = isControlEnabled ? "Pause Control" : "Resume Control"
            controllerManager.setControlEnabled(isControlEnabled)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        controllerManager.onConnectionChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleConnectionStateChanged(state)
            }
        }

        controllerManager.onDependencyIssuesChanged = { [weak self] issues in
            DispatchQueue.main.async {
                self?.updateDependencyMenu(issues)
            }
        }

        updateDependencyMenu(["Checking runtime dependencies..."])

        controllerManager.startMonitoring()
        handleConnectionStateChanged(controllerManager.connectionState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopBatteryPolling()
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "PS"

        let menu = NSMenu()

        let connection = NSMenuItem(title: "Controller: Disconnected", action: nil, keyEquivalent: "")
        connection.isEnabled = false
        menu.addItem(connection)
        self.connectionItem = connection

        let battery = NSMenuItem(title: "Battery: --", action: nil, keyEquivalent: "")
        battery.isEnabled = false
        menu.addItem(battery)
        self.batteryItem = battery

        menu.addItem(.separator())

        let dependencyStatus = NSMenuItem(title: "Dependencies: Checking...", action: nil, keyEquivalent: "")
        dependencyStatus.isEnabled = false
        menu.addItem(dependencyStatus)
        self.dependencyStatusItem = dependencyStatus

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Pause Control", action: #selector(toggleControl), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)
        self.toggleControlItem = toggle

        let restartASRServerMenuItem = NSMenuItem(title: "Restart ASR Server", action: #selector(restartASRServer), keyEquivalent: "r")
        restartASRServerMenuItem.target = self
        menu.addItem(restartASRServerMenuItem)
        self.restartASRServerItem = restartASRServerMenuItem

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        self.statusMenu = menu
        self.statusItem = item
    }

    private func handleConnectionStateChanged(_ state: ControllerConnectionState) {
        latestConnectionState = state
        updateConnectionLabel(state)

        switch state {
        case .connected:
            startBatteryPolling()
            refreshBatteryDisplay()
        case .disconnected:
            stopBatteryPolling()
            updateBatteryDisplay(nil)
        }
    }

    private func updateConnectionLabel(_ state: ControllerConnectionState) {
        switch state {
        case .connected(let name):
            connectionItem?.title = "Controller: Connected (\(name))"
        case .disconnected:
            connectionItem?.title = "Controller: Disconnected"
        }
    }

    private func startBatteryPolling() {
        guard batteryPollingTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.refreshBatteryDisplay()
        }

        batteryPollingTimer = timer
        timer.resume()
    }

    private func stopBatteryPolling() {
        batteryPollingTimer?.cancel()
        batteryPollingTimer = nil
    }

    private func refreshBatteryDisplay() {
        guard case .connected = latestConnectionState else {
            updateBatteryDisplay(nil)
            return
        }

        guard let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }),
              let battery = controller.battery else {
            updateBatteryDisplay(nil)
            return
        }

        let level = battery.batteryLevel
        guard level >= 0 else {
            updateBatteryDisplay(nil)
            return
        }

        let percent = max(0, min(100, Int(round(level * 100))))
        updateBatteryDisplay(percent)
    }

    private func updateBatteryDisplay(_ percent: Int?) {
        latestBatteryPercent = percent

        if let percent {
            batteryItem?.title = "Battery: \(percent)%"
        } else {
            batteryItem?.title = "Battery: --"
        }

        updateStatusTitle()
    }

    private func updateStatusTitle() {
        switch latestConnectionState {
        case .connected:
            if let latestBatteryPercent {
                statusItem?.button?.title = "PS \(latestBatteryPercent)%"
            } else {
                statusItem?.button?.title = "PS --"
            }
        case .disconnected:
            statusItem?.button?.title = "PS"
        }
    }

    private func updateDependencyMenu(_ issues: [String]) {
        guard let statusMenu else { return }

        for item in dependencyDetailItems {
            statusMenu.removeItem(item)
        }
        dependencyDetailItems.removeAll()

        let normalizedIssues = issues
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedIssues.isEmpty else {
            dependencyStatusItem?.title = "Dependencies: OK"
            return
        }

        let isChecking = normalizedIssues.count == 1 && normalizedIssues[0] == "Checking runtime dependencies..."
        dependencyStatusItem?.title = isChecking ? "Dependencies: Checking..." : "Dependencies: \(normalizedIssues.count) issue(s)"

        guard !isChecking else { return }

        guard let dependencyStatusItem else {
            return
        }

        let dependencyStatusIndex = statusMenu.index(of: dependencyStatusItem)
        guard dependencyStatusIndex >= 0 else {
            return
        }

        var insertionIndex = dependencyStatusIndex + 1
        for issue in normalizedIssues {
            let item = NSMenuItem(title: "⚠️ \(issue)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            statusMenu.insertItem(item, at: insertionIndex)
            dependencyDetailItems.append(item)
            insertionIndex += 1
        }
    }

    @objc
    private func toggleControl() {
        isControlEnabled.toggle()
    }

    @objc
    private func restartASRServer() {
        guard !isRestartingASRServer else { return }

        isRestartingASRServer = true
        updateDependencyMenu(["Checking runtime dependencies..."])

        AppFileLogger.shared.info(category: "AppDelegate", "menu_restart_asr_requested")
        print("[AppDelegate] menu_restart_asr_requested")

        controllerManager.restartASRServerEnsuringHealthy { [weak self] success, message in
            guard let self else { return }

            self.isRestartingASRServer = false

            if success {
                AppFileLogger.shared.info(category: "AppDelegate", "menu_restart_asr_succeeded message=\(message)")
                print("[AppDelegate] menu_restart_asr_succeeded message=\(message)")
            } else {
                AppFileLogger.shared.error(category: "AppDelegate", "menu_restart_asr_failed message=\(message)")
                print("[AppDelegate] menu_restart_asr_failed message=\(message)")
                self.updateDependencyMenu([message])
            }
        }
    }

    @objc
    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
