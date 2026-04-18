import Foundation
import GameController
import OSLog

enum ControllerConnectionState {
    case connected(name: String)
    case disconnected
}

private enum TouchpadMode: String {
    case idle
    case move
    case scroll
    case suppressed
}

final class ControllerManager {
    private static let deadzone: Float = 0.12
    private static let touchpadContactThreshold: Float = 0.01
    private static let touchpadMoveEnterDeadzone: Float = 0.01
    private static let touchpadMoveExitDeadzone: Float = 0.005
    private static let touchpadMoveCurveGamma: Float = 0.95
    private static let touchpadScrollDeadzone: Float = 0.01
    private static let touchpadScrollLinesPerTick: Float = 10.0
    private static let touchpadLiftSuppressionSeconds: TimeInterval = 0.06
    private static let defaultKeyActionLabel = "Default Key"
    private static let defaultTriggerRepeatInitialDelay: TimeInterval = 0.25
    private static let defaultTriggerRepeatInterval: TimeInterval = 0.08
    private static let defaultVoiceInputLocaleIdentifier = "zh-CN"
    private static let repeatableButtons: Set<ControllerButton> = [.leftTrigger, .rightTrigger]
    private static let shellBuiltins: Set<String> = [
        "alias", "bg", "bind", "break", "builtin", "cd", "command", "declare", "dirs", "echo", "eval",
        "exec", "exit", "export", "false", "fc", "fg", "getopts", "hash", "history", "jobs", "kill",
        "let", "local", "logout", "popd", "printf", "pushd", "pwd", "read", "readonly", "return",
        "set", "shift", "source", "test", "times", "trap", "true", "type", "typeset", "ulimit",
        "umask", "unalias", "unset", "wait"
    ]

    private let mouseBridge: MouseEventBridging
    private let logger: Logger
    private let configurationProvider: ControllerConfigurationProviding
    private let scriptExecutor: ScriptExecuting
    private let leftThumbstickWheelPresenter: LeftThumbstickWheelPresenting
    private let rightThumbstickWheelPresenter: LeftThumbstickWheelPresenting
    private let controllerActionHintPresenter: ControllerActionHintPresenting
    private let voiceInputController: VoiceInputControlling
    private let textInputInjector: TextInputInjecting
    private let voiceTranscriptCorrector: VoiceTranscriptCorrecting
    private let voiceTextTranslator: VoiceTextTranslating
    private let triggerRepeatInitialDelay: TimeInterval
    private let triggerRepeatInterval: TimeInterval

    private var configuration: ControllerConfiguration = .default

    private var isLeftWheelVisible = false
    private var selectedLeftWheelSlotIndex: Int?
    private var isRightWheelVisible = false
    private var selectedRightWheelSlotIndex: Int?
    private var isControllerActionHintVisible = false
    private var touchpadMoveActive = false
    private var touchpadWasTouching = false
    private var touchpadLiftSuppressionUntil: Date?
    private var touchpadScrollRemainder: Double = 0
    private var touchpadLastPrimaryPosition: (x: Float, y: Float)?
    private var touchpadLastTwoFingerAverageY: Float?
    private var touchpadMode: TouchpadMode = .idle

    var onLog: ((String) -> Void)?

    private(set) var connectionState: ControllerConnectionState = .disconnected {
        didSet {
            onConnectionChanged?(connectionState)
        }
    }

    var onConnectionChanged: ((ControllerConnectionState) -> Void)?
    var onDependencyIssuesChanged: (([String]) -> Void)?

    private var isControlEnabled = true
    private var currentController: GCController?

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    private var inputTimer: DispatchSourceTimer?
    private var repeatingButtonTimers: [ControllerButton: DispatchSourceTimer] = [:]

    private let dependencyCheckQueue = DispatchQueue(label: "PSController.DependencyCheck", qos: .utility)
    private var dependencyCheckToken: UUID?

    private var asrAutoStartedProcess: Process?
    private var asrAutoStartedStdoutPipe: Pipe?
    private var asrAutoStartedStderrPipe: Pipe?

    init(
        mouseBridge: MouseEventBridging = MouseEventBridge(),
        logger: Logger = Logger(subsystem: "PSController", category: "ControllerManager"),
        configurationProvider: ControllerConfigurationProviding = ControllerConfigurationLoader(),
        scriptExecutor: ScriptExecuting = ProcessScriptExecutor(),
        leftThumbstickWheelPresenter: LeftThumbstickWheelPresenting = LeftThumbstickWheelPresenter(),
        rightThumbstickWheelPresenter: LeftThumbstickWheelPresenting = LeftThumbstickWheelPresenter(centerTitle: "Right Stick"),
        controllerActionHintPresenter: ControllerActionHintPresenting = ControllerActionHintPresenter(),
        voiceInputController: VoiceInputControlling = Qwen3ASRVoiceInputController(),
        textInputInjector: TextInputInjecting = CGEventTextInputInjector(),
        voiceTranscriptCorrector: VoiceTranscriptCorrecting = DictionaryVoiceTranscriptCorrector(),
        voiceTextTranslator: VoiceTextTranslating = OllamaVoiceTextTranslator(),
        triggerRepeatInitialDelay: TimeInterval = ControllerManager.defaultTriggerRepeatInitialDelay,
        triggerRepeatInterval: TimeInterval = ControllerManager.defaultTriggerRepeatInterval
    ) {
        self.mouseBridge = mouseBridge
        self.logger = logger
        self.configurationProvider = configurationProvider
        self.scriptExecutor = scriptExecutor
        self.leftThumbstickWheelPresenter = leftThumbstickWheelPresenter
        self.rightThumbstickWheelPresenter = rightThumbstickWheelPresenter
        self.controllerActionHintPresenter = controllerActionHintPresenter
        self.voiceInputController = voiceInputController
        self.textInputInjector = textInputInjector
        self.voiceTranscriptCorrector = voiceTranscriptCorrector
        self.voiceTextTranslator = voiceTextTranslator
        self.triggerRepeatInitialDelay = max(0, triggerRepeatInitialDelay)
        self.triggerRepeatInterval = max(0.01, triggerRepeatInterval)
        self.configuration = applyRuntimeVoiceInputAdjustments(
            configurationProvider.loadConfiguration().normalizedForRuntime()
        )

        self.voiceInputController.updateConfiguration(self.configuration.voiceInput)
        self.voiceInputController.onTranscript = { [weak self] event in
            self?.handleVoiceTranscript(event)
        }

        if let qwenVoiceInputController = self.voiceInputController as? Qwen3ASRVoiceInputController {
            qwenVoiceInputController.onASRServerRecoveryRequested = { [weak self] completion in
                guard let self else {
                    completion(false, "controller_manager_deallocated")
                    return
                }

                self.logInfo("voice_transcription_recovery_restart_begin")
                self.restartASRServerEnsuringHealthy(forceRestartUnmanagedRunningService: true) { success, message in
                    self.logInfo("voice_transcription_recovery_restart_end success=\(success) message=\(message)")
                    completion(success, message)
                }
            }
        }
    }

    func startMonitoring() {
        configuration = applyRuntimeVoiceInputAdjustments(
            configurationProvider.loadConfiguration().normalizedForRuntime()
        )
        voiceInputController.updateConfiguration(configuration.voiceInput)

        if let resolution = configurationProvider.latestResolutionInfo() {
            logInfo("config_resolution source=\(resolution.source) path=\(resolution.url.path) fileExists=\(resolution.fileExists)")
        } else {
            logInfo("config_resolution source=unknown path=unknown fileExists=unknown")
        }

        let voiceInputEnabled = configuration.voiceInput?.enabled == true
        let asrBaseURL = configuration.voiceInput?.asrServer.baseURL ?? "none"
        let asrModel = configuration.voiceInput?.asrServer.model ?? "none"
        let asrAPIKeyConfigured = !(configuration.voiceInput?.asrServer.apiKey.isEmpty ?? true)
        let asrAutoStart = configuration.voiceInput?.asrServer.autoStart ?? false
        let asrLaunchExecutable = configuration.voiceInput?.asrServer.launchExecutable ?? "none"
        logInfo("Loaded configuration. buttonBindings=\(configuration.buttons.count) leftWheelSlots=\(configuration.leftThumbstickWheel.slots.count) rightWheelSlots=\(configuration.rightThumbstickWheel.slots.count) voiceInputEnabled=\(voiceInputEnabled) voiceInputButtons=\(voiceInputButtonLocaleMappingDescription()) asrBaseURL=\(asrBaseURL) asrModel=\(asrModel) asrApiKeyConfigured=\(asrAPIKeyConfigured) asrAutoStart=\(asrAutoStart) asrLaunchExecutable=\(asrLaunchExecutable)")

        prepareVoiceInputIfNeeded()

        logInfo("Start monitoring controller input")

        GCController.shouldMonitorBackgroundEvents = true
        logInfo("Background controller monitoring enabled")

        let accessibilityGranted = mouseBridge.requestAccessibilityIfNeeded(prompt: true)
        logInfo("Accessibility granted: \(accessibilityGranted)")
        if !accessibilityGranted {
            logInfo("Accessibility permission missing. Enable it in System Settings > Privacy & Security > Accessibility")
        }

        setupObservers()
        attachFirstAvailableController()
        startInputLoop()
        runDependencyChecks()
    }

    func setControlEnabled(_ enabled: Bool) {
        isControlEnabled = enabled
        if !enabled {
            hideWheelsIfVisible(reason: "control_paused")
            hideControllerActionHintIfVisible(reason: "control_paused")
            stopAllRepeatingButtons(reason: "control_paused")
            resetTouchpadState(reason: "control_paused")
            voiceInputController.stopCapture(trigger: "control_paused")
        }
        logInfo("Control enabled set to: \(enabled)")
    }

    func restartASRServerEnsuringHealthy(
        forceRestartUnmanagedRunningService: Bool = false,
        completion: ((Bool, String) -> Void)? = nil
    ) {
        let configSnapshot = configuration

        dependencyCheckQueue.async { [weak self] in
            guard let self else { return }

            let result = self.restartASRServerEnsuringHealthyLocked(
                configuration: configSnapshot,
                forceRestartUnmanagedRunningService: forceRestartUnmanagedRunningService
            )
            self.runDependencyChecks()

            guard let completion else { return }
            DispatchQueue.main.async {
                completion(result.success, result.message)
            }
        }
    }

    deinit {
        stopInputLoop()
        stopAllRepeatingButtons(reason: "controller_manager_deinit")
        stopASRAutoStartedProcessIfNeeded(reason: "controller_manager_deinit")
        hideControllerActionHintIfVisible(reason: "controller_manager_deinit")
        voiceInputController.stopCapture(trigger: "controller_manager_deinit")

        if let connectObserver {
            NotificationCenter.default.removeObserver(connectObserver)
        }

        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
    }

    func handlePrimaryButtonPress(isPressed: Bool) {
        handleButtonInput(.buttonA, isPressed: isPressed)
    }

    func handleSecondaryButtonPress(isPressed: Bool) {
        handleButtonInput(.buttonB, isPressed: isPressed)
    }

    func processInput(
        leftX: Float,
        leftY: Float,
        rightX: Float = 0,
        rightY: Float = 0,
        touchpadX: Float = 0,
        touchpadY: Float = 0,
        leftTrigger: Float,
        rightTrigger: Float,
        rightThumbstickX: Float = 0,
        rightThumbstickY: Float = 0
    ) {
        guard isControlEnabled else { return }

        _ = leftTrigger
        _ = rightTrigger

        handleLeftThumbstickWheel(leftX: leftX, leftY: leftY)
        handleRightThumbstickWheel(rightX: rightThumbstickX, rightY: rightThumbstickY)
        handleTouchpadFrame(
            primaryX: touchpadX,
            primaryY: touchpadY,
            secondaryX: rightX,
            secondaryY: rightY
        )
    }

    func normalizedThumbstickValue(_ raw: Float) -> Float {
        abs(raw) >= Self.deadzone ? raw : 0
    }

    private func handleTouchpadFrame(primaryX: Float, primaryY: Float, secondaryX: Float, secondaryY: Float) {
        let now = Date()
        let hasPrimaryTouch = isTouchpadFingerActive(x: primaryX, y: primaryY)
        let hasSecondaryTouch = isTouchpadFingerActive(x: secondaryX, y: secondaryY)
        let isTouching = hasPrimaryTouch || hasSecondaryTouch

        updateTouchpadLiftSuppression(isTouching: isTouching, now: now)

        if isTouchpadSuppressed(isTouching: isTouching, now: now) {
            setTouchpadMode(.suppressed)
            touchpadLastPrimaryPosition = hasPrimaryTouch ? (primaryX, primaryY) : nil
            touchpadLastTwoFingerAverageY = hasPrimaryTouch && hasSecondaryTouch ? ((primaryY + secondaryY) / 2) : nil
            logDebug("touchpad_lift_suppressed")
            return
        }

        guard isTouching else {
            touchpadMoveActive = false
            touchpadScrollRemainder = 0
            touchpadLastPrimaryPosition = nil
            touchpadLastTwoFingerAverageY = nil
            setTouchpadMode(.idle)
            return
        }

        if hasPrimaryTouch && hasSecondaryTouch {
            touchpadMoveActive = false
            touchpadLastPrimaryPosition = nil
            setTouchpadMode(.scroll)
            applyTouchpadTwoFingerScroll(primaryY: primaryY, secondaryY: secondaryY)
            return
        }

        guard hasPrimaryTouch else {
            touchpadLastPrimaryPosition = nil
            touchpadLastTwoFingerAverageY = nil
            setTouchpadMode(.idle)
            return
        }

        touchpadScrollRemainder = 0
        touchpadLastTwoFingerAverageY = nil
        setTouchpadMode(.move)
        applyTouchpadMove(currentX: primaryX, currentY: primaryY)
    }

    private func applyTouchpadMove(currentX: Float, currentY: Float) {
        guard let previous = touchpadLastPrimaryPosition else {
            touchpadLastPrimaryPosition = (currentX, currentY)
            return
        }

        touchpadLastPrimaryPosition = (currentX, currentY)

        let deltaX = currentX - previous.x
        let deltaY = currentY - previous.y

        guard let filtered = filteredTouchpadMove(rawX: deltaX, rawY: deltaY) else {
            return
        }

        let pointerSensitivity = configuration.touchpad.pointerSensitivity
        mouseBridge.moveCursor(
            normalizedX: Double(filtered.x * pointerSensitivity),
            normalizedY: Double(filtered.y * pointerSensitivity)
        )
    }

    private func filteredTouchpadMove(rawX: Float, rawY: Float) -> (x: Float, y: Float)? {
        let magnitude = sqrt((rawX * rawX) + (rawY * rawY))
        guard magnitude > 0 else {
            touchpadMoveActive = false
            return nil
        }

        let deadzone: Float
        if touchpadMoveActive {
            deadzone = Self.touchpadMoveExitDeadzone
            guard magnitude >= deadzone else {
                touchpadMoveActive = false
                return nil
            }
        } else {
            deadzone = Self.touchpadMoveEnterDeadzone
            guard magnitude >= deadzone else {
                return nil
            }
            touchpadMoveActive = true
        }

        let normalizedMagnitude = normalizeTouchpadMagnitude(magnitude, deadzone: deadzone)
        let curvedMagnitude = pow(normalizedMagnitude, Self.touchpadMoveCurveGamma)
        let scale = curvedMagnitude / magnitude

        return (x: rawX * scale, y: rawY * scale)
    }

    private func applyTouchpadTwoFingerScroll(primaryY: Float, secondaryY: Float) {
        let averagedY = (primaryY + secondaryY) / 2

        guard let previousAveragedY = touchpadLastTwoFingerAverageY else {
            touchpadLastTwoFingerAverageY = averagedY
            return
        }

        touchpadLastTwoFingerAverageY = averagedY

        let deltaY = averagedY - previousAveragedY
        let magnitude = abs(deltaY)
        guard magnitude >= Self.touchpadScrollDeadzone else {
            return
        }

        let normalized = normalizeTouchpadMagnitude(magnitude, deadzone: Self.touchpadScrollDeadzone)
        let signedNormalized = deltaY < 0 ? -normalized : normalized
        let scrollSensitivity = configuration.touchpad.scrollSensitivity
        let deltaLines = Double(signedNormalized * Self.touchpadScrollLinesPerTick * scrollSensitivity)

        touchpadScrollRemainder += deltaLines
        let wholeLines = Int32(touchpadScrollRemainder.rounded(.towardZero))
        guard wholeLines != 0 else {
            return
        }

        touchpadScrollRemainder -= Double(wholeLines)
        mouseBridge.scroll(lines: wholeLines)
    }

    private func normalizeTouchpadMagnitude(_ magnitude: Float, deadzone: Float) -> Float {
        let clampedDeadzone = min(max(deadzone, 0), 0.95)
        guard magnitude > clampedDeadzone else {
            return 0
        }

        let normalized = (magnitude - clampedDeadzone) / (1 - clampedDeadzone)
        return min(max(normalized, 0), 1)
    }

    private func isTouchpadFingerActive(x: Float, y: Float) -> Bool {
        let magnitude = sqrt((x * x) + (y * y))
        return magnitude >= Self.touchpadContactThreshold
    }

    private func updateTouchpadLiftSuppression(isTouching: Bool, now: Date) {
        if !isTouching && touchpadWasTouching {
            touchpadLiftSuppressionUntil = now.addingTimeInterval(Self.touchpadLiftSuppressionSeconds)
            touchpadMoveActive = false
            touchpadScrollRemainder = 0
            touchpadLastPrimaryPosition = nil
            touchpadLastTwoFingerAverageY = nil
            logInfo("touchpad_lift_detected suppression_ms=\(Int(Self.touchpadLiftSuppressionSeconds * 1000))")
        }

        touchpadWasTouching = isTouching
    }

    private func isTouchpadSuppressed(isTouching: Bool, now: Date) -> Bool {
        guard let suppressionUntil = touchpadLiftSuppressionUntil else {
            return false
        }

        if now < suppressionUntil {
            return isTouching
        }

        touchpadLiftSuppressionUntil = nil
        return false
    }

    private func resetTouchpadState(reason: String) {
        touchpadMoveActive = false
        touchpadWasTouching = false
        touchpadLiftSuppressionUntil = nil
        touchpadScrollRemainder = 0
        touchpadLastPrimaryPosition = nil
        touchpadLastTwoFingerAverageY = nil
        setTouchpadMode(.idle)
        logInfo("touchpad_state_reset reason=\(reason)")
    }

    private func setTouchpadMode(_ mode: TouchpadMode) {
        guard touchpadMode != mode else { return }

        let involvesScroll = touchpadMode == .scroll || mode == .scroll
        if !involvesScroll {
            logInfo("touchpad_mode_change from=\(touchpadMode.rawValue) to=\(mode.rawValue)")
        }

        touchpadMode = mode
    }

    private func setupObservers() {
        guard connectObserver == nil, disconnectObserver == nil else { return }

        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let controller = notification.object as? GCController else { return }
            self.attachControllerIfNeeded(controller)
        }

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let controller = notification.object as? GCController else { return }
            self.handleControllerDisconnect(controller)
        }
    }

    private func attachFirstAvailableController() {
        guard let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }) else {
            if case .connected = connectionState {
                connectionState = .disconnected
            }
            logDebug("No compatible USB controller connected")
            return
        }

        attachControllerIfNeeded(controller)
    }

    private func attachControllerIfNeeded(_ controller: GCController) {
        guard controller.extendedGamepad != nil else { return }
        guard currentController !== controller else { return }

        currentController = controller
        configureButtonHandlers(controller)

        let controllerName = controller.vendorName ?? "PlayStation Controller"
        connectionState = .connected(name: controllerName)
        logInfo("Controller connected: \(controllerName)")
    }

    private func handleControllerDisconnect(_ controller: GCController) {
        guard currentController === controller else { return }

        let disconnectedName = controller.vendorName ?? "PlayStation Controller"
        logInfo("Controller disconnected: \(disconnectedName)")

        currentController = nil
        connectionState = .disconnected
        hideWheelsIfVisible(reason: "controller_disconnected")
        hideControllerActionHintIfVisible(reason: "controller_disconnected")
        stopAllRepeatingButtons(reason: "controller_disconnected")
        resetTouchpadState(reason: "controller_disconnected")

        // Try switching to another connected controller immediately.
        attachFirstAvailableController()
    }

    private func configureButtonHandlers(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }

        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.buttonA, isPressed: pressed)
        }

        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.buttonB, isPressed: pressed)
        }

        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.buttonX, isPressed: pressed)
        }

        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.buttonY, isPressed: pressed)
        }

        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.leftShoulder, isPressed: pressed)
        }

        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.rightShoulder, isPressed: pressed)
        }

        gamepad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.leftTrigger, isPressed: pressed)
        }

        gamepad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.rightTrigger, isPressed: pressed)
        }

        gamepad.leftThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.leftThumbstickButton, isPressed: pressed)
        }

        gamepad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.rightThumbstickButton, isPressed: pressed)
        }

        gamepad.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.dpadUp, isPressed: pressed)
        }

        gamepad.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.dpadDown, isPressed: pressed)
        }

        gamepad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.dpadLeft, isPressed: pressed)
        }

        gamepad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.dpadRight, isPressed: pressed)
        }

        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.buttonMenu, isPressed: pressed)
        }

        gamepad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButtonInput(.buttonOptions, isPressed: pressed)
        }

        if #available(macOS 11.3, *) {
            gamepad.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.handleButtonInput(.buttonHome, isPressed: pressed)
            }
        }

        configureTouchpadButtonHandler(for: controller)
    }

    private func configureTouchpadButtonHandler(for controller: GCController) {
        if let dualSense = controller.physicalInputProfile as? GCDualSenseGamepad {
            dualSense.touchpadButton.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.handleButtonInput(.touchpadButton, isPressed: pressed)
            }
            logInfo("touchpad_button_handler_configured profile=dualSense")
            return
        }

        if let dualShock = controller.physicalInputProfile as? GCDualShockGamepad {
            dualShock.touchpadButton.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.handleButtonInput(.touchpadButton, isPressed: pressed)
            }
            logInfo("touchpad_button_handler_configured profile=dualShock")
            return
        }

        logDebug("touchpad_button_handler_unavailable")
    }

    func handleButtonInput(_ button: ControllerButton, isPressed: Bool) {
        guard isControlEnabled else {
            logDebug("Ignored button input while paused. button=\(button.rawValue) isPressed=\(isPressed)")
            return
        }

        if handleControllerActionHintButton(button, isPressed: isPressed) {
            return
        }

        if handleVoiceInputButton(button, isPressed: isPressed) {
            return
        }

        if handleFixedClickButton(button, isPressed: isPressed) {
            return
        }

        if handleRepeatableButton(button, isPressed: isPressed) {
            return
        }

        guard isPressed else { return }

        guard let binding = configuration.buttons[button] else {
            logDebug("No configured script for button=\(button.rawValue)")
            return
        }

        executeButtonScript(button, binding: binding, event: "button_pressed")
    }

    private func handleRepeatableButton(_ button: ControllerButton, isPressed: Bool) -> Bool {
        guard Self.repeatableButtons.contains(button) else {
            return false
        }

        if !isPressed {
            stopRepeatingButton(button, reason: "released")
            return true
        }

        if repeatingButtonTimers[button] != nil {
            return true
        }

        guard let binding = configuration.buttons[button] else {
            logDebug("No configured script for repeatable button=\(button.rawValue)")
            return true
        }

        executeButtonScript(button, binding: binding, event: "button_pressed")
        startRepeatingButton(button)
        return true
    }

    private func executeButtonScript(_ button: ControllerButton, binding: ScriptBinding, event: String) {
        logInfo("\(event) button=\(button.rawValue) script=\(binding.name) command=\(binding.command)")
        scriptExecutor.execute(binding: binding, trigger: "button.\(button.rawValue)")
    }

    private func startRepeatingButton(_ button: ControllerButton) {
        guard repeatingButtonTimers[button] == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + triggerRepeatInitialDelay,
            repeating: triggerRepeatInterval
        )

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            guard self.isControlEnabled else {
                self.stopRepeatingButton(button, reason: "control_disabled")
                return
            }

            guard let binding = self.configuration.buttons[button] else {
                self.logDebug("repeat_button_binding_missing button=\(button.rawValue)")
                self.stopRepeatingButton(button, reason: "binding_missing")
                return
            }

            self.scriptExecutor.execute(binding: binding, trigger: "button.\(button.rawValue)")
        }

        repeatingButtonTimers[button] = timer
        timer.resume()
        logInfo("button_repeat_start button=\(button.rawValue) initialDelay=\(triggerRepeatInitialDelay) interval=\(triggerRepeatInterval)")
    }

    private func stopRepeatingButton(_ button: ControllerButton, reason: String) {
        guard let timer = repeatingButtonTimers.removeValue(forKey: button) else {
            return
        }

        timer.cancel()
        logInfo("button_repeat_stop button=\(button.rawValue) reason=\(reason)")
    }

    private func stopAllRepeatingButtons(reason: String) {
        let buttons = Array(repeatingButtonTimers.keys)
        guard !buttons.isEmpty else { return }

        for button in buttons {
            stopRepeatingButton(button, reason: reason)
        }
    }

    private func handleControllerActionHintButton(_ button: ControllerButton, isPressed: Bool) -> Bool {
        guard button == .buttonMenu else {
            return false
        }

        if isPressed {
            let content = buildControllerActionHintContent()
            controllerActionHintPresenter.show(content: content)
            isControllerActionHintVisible = true
            logInfo("controller_action_hint_show")
        } else {
            hideControllerActionHintIfVisible(reason: "menu_released")
        }

        return true
    }

    private func hideControllerActionHintIfVisible(reason: String) {
        guard isControllerActionHintVisible else { return }

        isControllerActionHintVisible = false
        controllerActionHintPresenter.hide()
        logInfo("controller_action_hint_hide reason=\(reason)")
    }

    private func buildControllerActionHintContent() -> String {
        var lines: [String] = []
        lines.append("Controller Button Mappings")
        lines.append("==========================")
        lines.append("")

        for button in ControllerButton.allCases {
            let description = actionDescription(for: button)
            lines.append("\(button.rawValue) -> \(description)")
        }

        return lines.joined(separator: "\n")
    }

    private func actionDescription(for button: ControllerButton) -> String {
        if button == .buttonMenu {
            return "Hold to show this overlay"
        }

        if button == .touchpadButton {
            return "Left Click"
        }

        if configuration.voiceInput?.enabled == true, let locale = voiceInputLocaleIdentifier(for: button) {
            return "Voice Input (\(locale))"
        }

        guard let binding = configuration.buttons[button] else {
            return Self.defaultKeyActionLabel
        }

        if isPlaceholderDefaultBinding(binding, for: button) {
            return Self.defaultKeyActionLabel
        }

        let normalizedName = binding.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName.isEmpty ? Self.defaultKeyActionLabel : normalizedName
    }

    private func isPlaceholderDefaultBinding(_ binding: ScriptBinding, for button: ControllerButton) -> Bool {
        let normalizedName = binding.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommand = binding.command.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedCommand.isEmpty {
            return true
        }

        let expectedDefaultCommand = "echo 'Configure script for \(button.rawValue)'"
        if normalizedCommand == expectedDefaultCommand {
            return true
        }

        if normalizedCommand.contains("Configure script for \(button.rawValue)") {
            return true
        }

        return normalizedName == button.rawValue && normalizedCommand.contains("Configure script for")
    }

    private func handleVoiceTranscript(_ event: VoiceTranscriptEvent) {
        logInfo("voice_input_transcript final=\(event.isFinal) trigger=\(event.trigger ?? "unknown") text=\(event.text)")

        guard event.isFinal else {
            logDebug("voice_input_partial_skip_insertion")
            return
        }

        let normalized = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            logDebug("voice_input_final_skip_empty")
            return
        }

        let corrected = voiceTranscriptCorrector.correct(normalized)
        let source = corrected == normalized ? "raw" : "dictionary_corrected"

        guard shouldTranslateVoiceTranscript(trigger: event.trigger) else {
            logInfo("voice_input_translation_skipped reason=button_b_legacy trigger=\(event.trigger ?? "unknown") source=\(source)")
            insertVoiceTranscriptAtCursor(corrected, source: "\(source)_no_translation")
            return
        }

        translateVoiceTranscriptToEnglishAndInsert(corrected, source: source)
    }

    private func translateVoiceTranscriptToEnglishAndInsert(_ text: String, source: String) {
        logInfo("voice_input_translation_start source=\(source) inputChars=\(text.count)")

        voiceTextTranslator.translateToEnglish(text: text) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let translated):
                let normalizedTranslated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedTranslated.isEmpty else {
                    self.logError("voice_input_translation_failed reason=empty_translation source=\(source)")
                    self.insertVoiceTranscriptAtCursor(text, source: "\(source)_translation_fallback")
                    return
                }

                self.logInfo("voice_input_translation_success source=\(source) outputChars=\(normalizedTranslated.count)")
                self.insertVoiceTranscriptAtCursor(normalizedTranslated, source: "\(source)_translated_en")

            case .failure(let error):
                self.logError("voice_input_translation_failed reason=ollama_error source=\(source) message=\(error.localizedDescription)")
                self.insertVoiceTranscriptAtCursor(text, source: "\(source)_translation_fallback")
            }
        }
    }

    private func shouldTranslateVoiceTranscript(trigger: String?) -> Bool {
        guard let voiceInput = configuration.voiceInput,
              voiceInput.enabled else {
            return true
        }

        guard let trigger else {
            return true
        }

        let legacyButtonBTrigger = "button.\(ControllerButton.buttonB.rawValue)"
        let activationButtonTrigger = "button.\(voiceInput.activationButton.rawValue)"

        if trigger == legacyButtonBTrigger && trigger != activationButtonTrigger {
            return false
        }

        return true
    }

    private func insertVoiceTranscriptAtCursor(_ text: String, source: String) {
        let inserted = textInputInjector.insertAtCursor(text: text)
        logInfo("voice_input_insert_cursor success=\(inserted) chars=\(text.count) source=\(source)")
    }

    private func prepareVoiceInputIfNeeded() {
        guard let voiceInput = configuration.voiceInput else {
            logDebug("voice_input_config_missing")
            return
        }

        guard voiceInput.enabled else {
            logInfo("voice_input_disabled")
            return
        }

        logInfo("voice_input_prepare buttons=\(voiceInputButtonLocaleMappingDescription()) asrBaseURL=\(voiceInput.asrServer.baseURL) asrModel=\(voiceInput.asrServer.model) asrApiKeyConfigured=\(!voiceInput.asrServer.apiKey.isEmpty) asrAutoStart=\(voiceInput.asrServer.autoStart) asrLaunchExecutable=\(voiceInput.asrServer.launchExecutable)")
        voiceInputController.prepare()
    }

    private func handleVoiceInputButton(_ button: ControllerButton, isPressed: Bool) -> Bool {
        guard let voiceInput = configuration.voiceInput,
              voiceInput.enabled,
              let localeIdentifier = voiceInputLocaleIdentifier(for: button) else {
            return false
        }

        let trigger = "button.\(button.rawValue)"
        if isPressed {
            logInfo("voice_input_start trigger=\(trigger) locale=\(localeIdentifier)")
            voiceInputController.startCapture(trigger: trigger, localeIdentifier: localeIdentifier)
        } else {
            logInfo("voice_input_stop trigger=\(trigger) locale=\(localeIdentifier)")
            voiceInputController.stopCapture(trigger: trigger)
        }

        return true
    }

    private func voiceInputLocaleIdentifier(for button: ControllerButton) -> String? {
        guard let voiceInput = configuration.voiceInput,
              voiceInput.enabled else {
            return nil
        }

        let voiceButtons = voiceInputButtons(activationButton: voiceInput.activationButton)
        guard voiceButtons.contains(button) else {
            return nil
        }

        return Self.defaultVoiceInputLocaleIdentifier
    }

    private func voiceInputButtonLocaleMappingDescription() -> String {
        guard let voiceInput = configuration.voiceInput,
              voiceInput.enabled else {
            return "none"
        }

        return voiceInputButtons(activationButton: voiceInput.activationButton)
            .map { "\($0.rawValue):\(Self.defaultVoiceInputLocaleIdentifier)" }
            .joined(separator: ",")
    }

    private func voiceInputButtons(activationButton: ControllerButton) -> [ControllerButton] {
        var buttons: [ControllerButton] = [activationButton]

        if activationButton != .buttonB {
            buttons.append(.buttonB)
        }

        return buttons
    }

    private func handleFixedClickButton(_ button: ControllerButton, isPressed: Bool) -> Bool {
        guard button == .touchpadButton else {
            return false
        }

        guard isPressed else {
            return true
        }

        mouseBridge.leftClick()
        logInfo("touchpad_button_left_click")
        return true
    }

    private func handleLeftThumbstickWheel(leftX: Float, leftY: Float) {
        let magnitude = sqrt((leftX * leftX) + (leftY * leftY))
        let threshold = configuration.leftThumbstickWheel.activationThreshold
        let slots = configuration.leftThumbstickWheel.slots

        guard slots.count >= 2 else {
            logDebug("left_thumbstick_wheel_invalid_slot_count count=\(slots.count)")
            return
        }

        if magnitude >= threshold {
            let index = wheelSlotIndex(x: leftX, y: leftY, slotCount: slots.count)

            if !isLeftWheelVisible {
                isLeftWheelVisible = true
                selectedLeftWheelSlotIndex = index
                leftThumbstickWheelPresenter.show(slots: slots, selectedIndex: index)
                logInfo("left_thumbstick_wheel_show slot=\(index + 1) title=\(slots[index].title)")
                return
            }

            if selectedLeftWheelSlotIndex != index {
                selectedLeftWheelSlotIndex = index
                leftThumbstickWheelPresenter.updateSelection(selectedIndex: index, slots: slots)
                logInfo("left_thumbstick_wheel_select slot=\(index + 1) title=\(slots[index].title)")
            }

            return
        }

        guard isLeftWheelVisible else { return }

        leftThumbstickWheelPresenter.hide()
        isLeftWheelVisible = false

        guard let selectedLeftWheelSlotIndex else {
            logDebug("left_thumbstick_wheel_hide without selection")
            return
        }

        self.selectedLeftWheelSlotIndex = nil

        let slot = slots[selectedLeftWheelSlotIndex]
        logInfo("left_thumbstick_wheel_confirm slot=\(selectedLeftWheelSlotIndex + 1) title=\(slot.title)")

        guard let binding = slot.script else {
            if slot.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cancel" {
                logInfo("left_thumbstick_wheel_cancelled slot=\(selectedLeftWheelSlotIndex + 1)")
            } else {
                logDebug("left_thumbstick_wheel_no_script slot=\(selectedLeftWheelSlotIndex + 1) title=\(slot.title)")
            }
            return
        }

        scriptExecutor.execute(binding: binding, trigger: "leftThumbstick.slot\(selectedLeftWheelSlotIndex + 1)")
    }

    private func handleRightThumbstickWheel(rightX: Float, rightY: Float) {
        let magnitude = sqrt((rightX * rightX) + (rightY * rightY))
        let threshold = configuration.rightThumbstickWheel.activationThreshold
        let slots = configuration.rightThumbstickWheel.slots

        guard slots.count >= 2 else {
            logDebug("right_thumbstick_wheel_invalid_slot_count count=\(slots.count)")
            return
        }

        if magnitude >= threshold {
            let index = wheelSlotIndex(x: rightX, y: rightY, slotCount: slots.count)

            if !isRightWheelVisible {
                isRightWheelVisible = true
                selectedRightWheelSlotIndex = index
                rightThumbstickWheelPresenter.show(slots: slots, selectedIndex: index)
                logInfo("right_thumbstick_wheel_show slot=\(index + 1) title=\(slots[index].title)")
                return
            }

            if selectedRightWheelSlotIndex != index {
                selectedRightWheelSlotIndex = index
                rightThumbstickWheelPresenter.updateSelection(selectedIndex: index, slots: slots)
                logInfo("right_thumbstick_wheel_select slot=\(index + 1) title=\(slots[index].title)")
            }

            return
        }

        guard isRightWheelVisible else { return }

        rightThumbstickWheelPresenter.hide()
        isRightWheelVisible = false

        guard let selectedRightWheelSlotIndex else {
            logDebug("right_thumbstick_wheel_hide without selection")
            return
        }

        self.selectedRightWheelSlotIndex = nil

        let slot = slots[selectedRightWheelSlotIndex]
        logInfo("right_thumbstick_wheel_confirm slot=\(selectedRightWheelSlotIndex + 1) title=\(slot.title)")

        guard let binding = slot.script else {
            if slot.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cancel" {
                logInfo("right_thumbstick_wheel_cancelled slot=\(selectedRightWheelSlotIndex + 1)")
            } else {
                logDebug("right_thumbstick_wheel_no_script slot=\(selectedRightWheelSlotIndex + 1) title=\(slot.title)")
            }
            return
        }

        scriptExecutor.execute(binding: binding, trigger: "rightThumbstick.slot\(selectedRightWheelSlotIndex + 1)")
    }

    private func wheelSlotIndex(x: Float, y: Float, slotCount: Int) -> Int {
        let angleFromXAxis = atan2(Double(y), Double(x)) * 180 / Double.pi
        let clockwiseFromUp = fmod((90.0 - angleFromXAxis + 360.0), 360.0)
        let segmentSize = 360.0 / Double(slotCount)
        let shifted = fmod(clockwiseFromUp + (segmentSize / 2), 360.0)
        return Int(shifted / segmentSize)
    }

    private func hideWheelsIfVisible(reason: String) {
        hideLeftWheelIfVisible(reason: reason)
        hideRightWheelIfVisible(reason: reason)
    }

    private func hideLeftWheelIfVisible(reason: String) {
        guard isLeftWheelVisible else { return }
        isLeftWheelVisible = false
        selectedLeftWheelSlotIndex = nil
        leftThumbstickWheelPresenter.hide()
        logInfo("left_thumbstick_wheel_hide reason=\(reason)")
    }

    private func hideRightWheelIfVisible(reason: String) {
        guard isRightWheelVisible else { return }
        isRightWheelVisible = false
        selectedRightWheelSlotIndex = nil
        rightThumbstickWheelPresenter.hide()
        logInfo("right_thumbstick_wheel_hide reason=\(reason)")
    }

    private func startInputLoop() {
        guard inputTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))

        timer.setEventHandler { [weak self] in
            self?.processContinuousInput()
        }

        inputTimer = timer
        timer.resume()
    }

    private func stopInputLoop() {
        inputTimer?.cancel()
        inputTimer = nil
    }

    private func processContinuousInput() {
        guard let gamepad = currentController?.extendedGamepad else { return }

        let touchpadInput = resolveTouchpadInput(from: currentController)

        processInput(
            leftX: gamepad.leftThumbstick.xAxis.value,
            leftY: gamepad.leftThumbstick.yAxis.value,
            rightX: touchpadInput.secondaryX,
            rightY: touchpadInput.secondaryY,
            touchpadX: touchpadInput.primaryX,
            touchpadY: touchpadInput.primaryY,
            leftTrigger: gamepad.leftTrigger.value,
            rightTrigger: gamepad.rightTrigger.value,
            rightThumbstickX: gamepad.rightThumbstick.xAxis.value,
            rightThumbstickY: gamepad.rightThumbstick.yAxis.value
        )
    }

    private func resolveTouchpadInput(from controller: GCController?) -> (primaryX: Float, primaryY: Float, secondaryX: Float, secondaryY: Float) {
        guard let controller else {
            return (0, 0, 0, 0)
        }

        if let dualSense = controller.physicalInputProfile as? GCDualSenseGamepad {
            return (
                dualSense.touchpadPrimary.xAxis.value,
                dualSense.touchpadPrimary.yAxis.value,
                dualSense.touchpadSecondary.xAxis.value,
                dualSense.touchpadSecondary.yAxis.value
            )
        }

        if let dualShock = controller.physicalInputProfile as? GCDualShockGamepad {
            return (
                dualShock.touchpadPrimary.xAxis.value,
                dualShock.touchpadPrimary.yAxis.value,
                dualShock.touchpadSecondary.xAxis.value,
                dualShock.touchpadSecondary.yAxis.value
            )
        }

        return (0, 0, 0, 0)
    }

    private enum ASRAutoStartStatus {
        case skipped
        case started
        case alreadyRunning
        case failed(String)
    }

    private func applyRuntimeVoiceInputAdjustments(_ configuration: ControllerConfiguration) -> ControllerConfiguration {
        configuration
    }

    private func runDependencyChecks() {
        let checkToken = UUID()
        dependencyCheckToken = checkToken

        let configSnapshot = configuration
        let configResolution = configurationProvider.latestResolutionInfo()

        dependencyCheckQueue.async { [weak self] in
            guard let self else { return }

            var issues: [String] = []

            if let configResolution {
                issues.append(contentsOf: self.configurationResolutionIssues(configResolution))
            }

            issues.append(contentsOf: self.scriptCommandDependencyIssues(configuration: configSnapshot))
            issues.append(contentsOf: self.voiceDependencyIssues(configuration: configSnapshot))

            let uniqueSortedIssues = Array(Set(issues)).sorted()
            self.publishDependencyIssues(uniqueSortedIssues, checkToken: checkToken)
        }
    }

    private func publishDependencyIssues(_ issues: [String], checkToken: UUID) {
        guard dependencyCheckToken == checkToken else {
            return
        }

        if issues.isEmpty {
            logInfo("runtime_dependency_check_ok")
        } else {
            logError("runtime_dependency_check_failed count=\(issues.count) issues=\(issues.joined(separator: " | "))")
        }

        onDependencyIssuesChanged?(issues)
    }

    private func configurationResolutionIssues(_ resolution: ControllerConfigurationResolutionInfo) -> [String] {
        var issues: [String] = []

        if resolution.source == "env" && !resolution.fileExists {
            issues.append("Missing config file at PS_CONTROLLER_CONFIG_PATH: \(resolution.url.path)")
        }

        if resolution.source == "cwd" && !resolution.fileExists {
            issues.append("Config file missing; default config was generated at: \(resolution.url.path)")
        }

        return issues
    }

    private func scriptCommandDependencyIssues(configuration: ControllerConfiguration) -> [String] {
        var commandNames: Set<String> = []
        var absoluteExecutablePaths: Set<String> = []

        let allCommands = configuration.buttons.values.map(\.command)
            + configuration.leftThumbstickWheel.slots.compactMap { $0.script?.command }
            + configuration.rightThumbstickWheel.slots.compactMap { $0.script?.command }

        for rawCommand in allCommands {
            for segment in commandSegments(rawCommand) {
                guard let executable = executableCandidate(from: segment) else {
                    continue
                }

                if executable.hasPrefix("/") {
                    absoluteExecutablePaths.insert(executable)
                } else {
                    commandNames.insert(executable)
                }
            }
        }

        var issues: [String] = []

        for path in absoluteExecutablePaths.sorted() {
            if !isExecutableFile(atAbsolutePath: path) {
                issues.append("Missing executable file: \(path)")
            }
        }

        for command in commandNames.sorted() {
            if !isShellCommandAvailable(command) {
                issues.append("Missing command in PATH: \(command)")
            }
        }

        return issues
    }

    private func voiceDependencyIssues(configuration: ControllerConfiguration) -> [String] {
        guard let voiceInput = configuration.voiceInput, voiceInput.enabled else {
            stopASRAutoStartedProcessIfNeeded(reason: "voice_input_disabled")
            return []
        }

        var issues: [String] = []

        let asrServer = voiceInput.asrServer
        if !asrServer.autoStart {
            stopASRAutoStartedProcessIfNeeded(reason: "asr_auto_start_disabled")
        }

        guard let asrBaseURL = URL(string: asrServer.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            issues.append("Invalid ASR baseURL: \(asrServer.baseURL)")
            return issues
        }

        guard let asrHealthURL = makeASRHealthURL(fromBaseURL: asrBaseURL) else {
            issues.append("Unable to build ASR health URL from: \(asrServer.baseURL)")
            return issues
        }

        var asrReachable = isHTTPServiceReachable(url: asrHealthURL, timeout: min(asrServer.timeoutSeconds, 5))

        if !asrReachable && asrServer.autoStart {
            switch ensureASRServerRunning(asrServer: asrServer) {
            case .skipped:
                break
            case .started:
                logInfo("asr_server_auto_start_started endpoint=\(asrHealthURL.absoluteString)")
            case .alreadyRunning:
                logInfo("asr_server_auto_start_already_running")
            case .failed(let reason):
                issues.append("ASR auto-start failed: \(reason)")
            }

            asrReachable = waitForHTTPServiceReachable(
                url: asrHealthURL,
                timeout: min(asrServer.timeoutSeconds, 5),
                maxWaitSeconds: 8
            )
        }

        if !asrReachable {
            issues.append("ASR server unavailable at: \(asrHealthURL.absoluteString)")
        }

        return issues
    }

    private func restartASRServerEnsuringHealthyLocked(
        configuration: ControllerConfiguration,
        forceRestartUnmanagedRunningService: Bool
    ) -> (success: Bool, message: String) {
        guard let voiceInput = configuration.voiceInput, voiceInput.enabled else {
            let message = "ASR restart skipped: voice input is disabled in configuration"
            logError("asr_server_manual_restart_failed reason=voice_input_disabled")
            return (false, message)
        }

        let asrServer = voiceInput.asrServer

        guard let asrBaseURL = URL(string: asrServer.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            let message = "ASR restart failed: invalid baseURL \(asrServer.baseURL)"
            logError("asr_server_manual_restart_failed reason=invalid_base_url baseURL=\(asrServer.baseURL)")
            return (false, message)
        }

        guard let asrHealthURL = makeASRHealthURL(fromBaseURL: asrBaseURL) else {
            let message = "ASR restart failed: unable to build health URL from \(asrServer.baseURL)"
            logError("asr_server_manual_restart_failed reason=invalid_health_url baseURL=\(asrServer.baseURL)")
            return (false, message)
        }

        let timeout = min(asrServer.timeoutSeconds, 5)
        let wasManagedProcessRunning = asrAutoStartedProcess?.isRunning == true

        logInfo("asr_server_manual_restart_requested endpoint=\(asrHealthURL.absoluteString) managedRunning=\(wasManagedProcessRunning) forceRestartUnmanaged=\(forceRestartUnmanagedRunningService)")

        if wasManagedProcessRunning {
            stopASRAutoStartedProcessIfNeeded(reason: "manual_restart")
            Thread.sleep(forTimeInterval: 0.3)
        }

        let wasReachableBeforeStart = isHTTPServiceReachable(url: asrHealthURL, timeout: timeout)
        var forcedUnmanagedRestart = false

        if !wasManagedProcessRunning && wasReachableBeforeStart {
            if !forceRestartUnmanagedRunningService {
                let message = "ASR server already running and healthy at: \(asrHealthURL.absoluteString)"
                logInfo("asr_server_manual_restart_skipped reason=unmanaged_running_service endpoint=\(asrHealthURL.absoluteString)")
                return (true, message)
            }

            guard let hostPort = asrHostPort(fromBaseURLText: asrServer.baseURL) else {
                let message = "ASR restart failed: unable to parse host/port from \(asrServer.baseURL)"
                logError("asr_server_manual_restart_failed reason=force_restart_parse_host_port_failed baseURL=\(asrServer.baseURL)")
                return (false, message)
            }

            guard isLocalHost(hostPort.host) else {
                let message = "ASR restart failed: force restart supports only local host, got \(hostPort.host)"
                logError("asr_server_manual_restart_failed reason=force_restart_non_local_host host=\(hostPort.host) port=\(hostPort.port)")
                return (false, message)
            }

            let forceRestartResult = stopUnmanagedASRServiceListeningOnPort(
                port: hostPort.port,
                reason: "forced_restart_after_transcription_failure"
            )
            guard forceRestartResult.success else {
                let message = "ASR restart failed: \(forceRestartResult.message)"
                logError("asr_server_manual_restart_failed reason=force_restart_stop_unmanaged_failed detail=\(forceRestartResult.message)")
                return (false, message)
            }

            forcedUnmanagedRestart = true
            Thread.sleep(forTimeInterval: 0.3)
        }

        switch ensureASRServerRunning(asrServer: asrServer, allowManualStartWhenAutoStartDisabled: true) {
        case .skipped:
            let message = "ASR restart failed: start was skipped"
            logError("asr_server_manual_restart_failed reason=start_skipped")
            return (false, message)
        case .failed(let reason):
            let message = "ASR restart failed: \(reason)"
            logError("asr_server_manual_restart_failed reason=start_error detail=\(reason)")
            return (false, message)
        case .started:
            logInfo("asr_server_manual_restart_started endpoint=\(asrHealthURL.absoluteString)")
        case .alreadyRunning:
            logInfo("asr_server_manual_restart_already_running endpoint=\(asrHealthURL.absoluteString)")
        }

        let isHealthy = waitForHTTPServiceReachable(
            url: asrHealthURL,
            timeout: timeout,
            maxWaitSeconds: max(8, min(asrServer.timeoutSeconds, 20))
        )

        guard isHealthy else {
            let message = "ASR server failed health check at: \(asrHealthURL.absoluteString)"
            logError("asr_server_manual_restart_failed reason=health_check_timeout endpoint=\(asrHealthURL.absoluteString)")
            return (false, message)
        }

        let action = (wasManagedProcessRunning || forcedUnmanagedRestart) ? "restarted" : "started"
        let message = "ASR server \(action) and healthy at: \(asrHealthURL.absoluteString)"
        logInfo("asr_server_manual_restart_success action=\(action) endpoint=\(asrHealthURL.absoluteString)")
        return (true, message)
    }

    private func ensureASRServerRunning(
        asrServer: VoiceInputASRServerConfiguration,
        allowManualStartWhenAutoStartDisabled: Bool = false
    ) -> ASRAutoStartStatus {
        guard asrServer.autoStart || allowManualStartWhenAutoStartDisabled else {
            return .skipped
        }

        if let asrAutoStartedProcess, asrAutoStartedProcess.isRunning {
            return .alreadyRunning
        }

        guard let executablePath = resolveExecutablePath(asrServer.launchExecutable) else {
            return .failed("Cannot find launch executable: \(asrServer.launchExecutable)")
        }

        var arguments = normalizedASRAutoStartArguments(asrServer)

        guard containsCLIOption(arguments, "--model-dir") else {
            return .failed("Missing required --model-dir in voiceInput.asrServer.launchArguments")
        }

        if let hostPort = asrHostPort(fromBaseURLText: asrServer.baseURL) {
            if !containsCLIOption(arguments, "--host") {
                arguments.append(contentsOf: ["--host", hostPort.host])
            }

            if !containsCLIOption(arguments, "--port") {
                arguments.append(contentsOf: ["--port", String(hostPort.port)])
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = currentPath.isEmpty ? fallbackPath : "\(currentPath):\(fallbackPath)"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        bindASRServerPipe(stdoutPipe, stream: "stdout")
        bindASRServerPipe(stderrPipe, stream: "stderr")

        process.terminationHandler = { [weak self] process in
            self?.dependencyCheckQueue.async {
                guard let self else { return }

                let reason = process.terminationReason == .exit ? "exit" : "signal"
                self.logError("asr_server_process_terminated status=\(process.terminationStatus) reason=\(reason)")

                self.asrAutoStartedStdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.asrAutoStartedStderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.asrAutoStartedStdoutPipe = nil
                self.asrAutoStartedStderrPipe = nil
                self.asrAutoStartedProcess = nil
            }
        }

        do {
            try process.run()
            asrAutoStartedProcess = process
            asrAutoStartedStdoutPipe = stdoutPipe
            asrAutoStartedStderrPipe = stderrPipe

            let visibleArguments = redactSecretArguments(arguments)
            logInfo("asr_server_process_started executable=\(executablePath) arguments=\(visibleArguments.joined(separator: " ")) pid=\(process.processIdentifier)")
            return .started
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failed(error.localizedDescription)
        }
    }

    private func stopASRAutoStartedProcessIfNeeded(reason: String) {
        guard let process = asrAutoStartedProcess else { return }

        if process.isRunning {
            logInfo("asr_server_process_stopping reason=\(reason) pid=\(process.processIdentifier)")
            process.terminate()
        }

        asrAutoStartedStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        asrAutoStartedStderrPipe?.fileHandleForReading.readabilityHandler = nil
        asrAutoStartedStdoutPipe = nil
        asrAutoStartedStderrPipe = nil
        asrAutoStartedProcess = nil
    }

    private func stopUnmanagedASRServiceListeningOnPort(port: Int, reason: String) -> (success: Bool, message: String) {
        let currentPID = ProcessInfo.processInfo.processIdentifier

        let initialLookup = listeningProcessIDs(onTCPPort: port)
        if let lookupError = initialLookup.error {
            return (false, "failed to discover listening PID: \(lookupError)")
        }

        let targetPIDs = Set(initialLookup.pids.filter { $0 != currentPID }).sorted()
        guard !targetPIDs.isEmpty else {
            logInfo("asr_server_unmanaged_stop_skipped reason=no_listener_on_port port=\(port)")
            return (true, "no listener on port \(port)")
        }

        logInfo("asr_server_unmanaged_stop_begin reason=\(reason) port=\(port) pids=\(targetPIDs.map(String.init).joined(separator: ","))")

        var termFailedPIDs: [Int32] = []
        for pid in targetPIDs {
            let termSucceeded = sendSignalToProcess(pid: pid, signal: "-TERM")
            if !termSucceeded {
                termFailedPIDs.append(pid)
            }
        }

        if !termFailedPIDs.isEmpty {
            logError("asr_server_unmanaged_stop_term_failed port=\(port) pids=\(termFailedPIDs.map(String.init).joined(separator: ","))")
        }

        if waitForNoListenerOnTCPPort(port: port, maxWaitSeconds: 1.5) {
            logInfo("asr_server_unmanaged_stop_done method=term port=\(port)")
            return (true, "terminated unmanaged ASR listener on port \(port)")
        }

        let postTermLookup = listeningProcessIDs(onTCPPort: port)
        if let lookupError = postTermLookup.error {
            return (false, "failed to verify listener after TERM: \(lookupError)")
        }

        let remainingPIDs = Set(postTermLookup.pids.filter { $0 != currentPID }).sorted()
        if remainingPIDs.isEmpty {
            logInfo("asr_server_unmanaged_stop_done method=term_verify port=\(port)")
            return (true, "terminated unmanaged ASR listener on port \(port)")
        }

        logInfo("asr_server_unmanaged_stop_escalate signal=KILL port=\(port) pids=\(remainingPIDs.map(String.init).joined(separator: ","))")

        var killFailedPIDs: [Int32] = []
        for pid in remainingPIDs {
            let killSucceeded = sendSignalToProcess(pid: pid, signal: "-KILL")
            if !killSucceeded {
                killFailedPIDs.append(pid)
            }
        }

        if !killFailedPIDs.isEmpty {
            logError("asr_server_unmanaged_stop_kill_failed port=\(port) pids=\(killFailedPIDs.map(String.init).joined(separator: ","))")
        }

        if waitForNoListenerOnTCPPort(port: port, maxWaitSeconds: 1.5) {
            logInfo("asr_server_unmanaged_stop_done method=kill port=\(port)")
            return (true, "killed unmanaged ASR listener on port \(port)")
        }

        let finalLookup = listeningProcessIDs(onTCPPort: port)
        if let lookupError = finalLookup.error {
            return (false, "failed to verify listener after KILL: \(lookupError)")
        }

        let finalPIDs = Set(finalLookup.pids.filter { $0 != currentPID }).sorted()
        if finalPIDs.isEmpty {
            logInfo("asr_server_unmanaged_stop_done method=kill_verify port=\(port)")
            return (true, "killed unmanaged ASR listener on port \(port)")
        }

        return (false, "listener still active on port \(port), pids=\(finalPIDs.map(String.init).joined(separator: ","))")
    }

    private func listeningProcessIDs(onTCPPort port: Int) -> (pids: [Int32], error: String?) {
        guard let lsofPath = resolveExecutablePath("lsof") else {
            return ([], "lsof_not_found")
        }

        guard let commandResult = runLocalProcess(executablePath: lsofPath, arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]) else {
            return ([], "lsof_run_failed")
        }

        if commandResult.status != 0 {
            let stderr = commandResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if commandResult.status == 1 && stderr.isEmpty {
                return ([], nil)
            }

            let detail = stderr.isEmpty ? "exit_status_\(commandResult.status)" : stderr
            return ([], detail)
        }

        let pids = commandResult.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(Int32.init)

        return (pids, nil)
    }

    private func sendSignalToProcess(pid: Int32, signal: String) -> Bool {
        guard let killPath = resolveExecutablePath("kill") else {
            logError("asr_server_unmanaged_stop_signal_failed reason=kill_not_found pid=\(pid) signal=\(signal)")
            return false
        }

        guard let result = runLocalProcess(executablePath: killPath, arguments: [signal, String(pid)]) else {
            logError("asr_server_unmanaged_stop_signal_failed reason=kill_run_failed pid=\(pid) signal=\(signal)")
            return false
        }

        if result.status != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "exit_status_\(result.status)" : stderr
            logError("asr_server_unmanaged_stop_signal_failed reason=kill_non_zero pid=\(pid) signal=\(signal) detail=\(detail)")
            return false
        }

        return true
    }

    private func waitForNoListenerOnTCPPort(port: Int, maxWaitSeconds: TimeInterval) -> Bool {
        let attempts = max(1, Int(ceil(maxWaitSeconds / 0.2)))
        let currentPID = ProcessInfo.processInfo.processIdentifier

        for attempt in 0..<attempts {
            let lookup = listeningProcessIDs(onTCPPort: port)
            guard lookup.error == nil else {
                return false
            }

            let remainingPIDs = lookup.pids.filter { $0 != currentPID }
            if remainingPIDs.isEmpty {
                return true
            }

            if attempt < attempts - 1 {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        return false
    }

    private func runLocalProcess(
        executablePath: String,
        arguments: [String]
    ) -> (status: Int32, stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            logError("asr_server_local_process_run_failed executable=\(executablePath) arguments=\(arguments.joined(separator: " ")) message=\(error.localizedDescription)")
            return nil
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    private func bindASRServerPipe(_ pipe: Pipe, stream: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            guard let text = String(data: data, encoding: .utf8) else {
                return
            }

            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for line in lines {
                self?.logInfo("asr_server_\(stream) \(line)")
            }
        }
    }

    private func normalizedASRAutoStartArguments(_ asrServer: VoiceInputASRServerConfiguration) -> [String] {
        asrServer.launchArguments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func containsCLIOption(_ arguments: [String], _ option: String) -> Bool {
        arguments.contains(option) || arguments.contains(where: { $0.hasPrefix("\(option)=") })
    }

    private func redactSecretArguments(_ arguments: [String]) -> [String] {
        var redacted = arguments

        for index in redacted.indices {
            if redacted[index] == "--api-key", index + 1 < redacted.endIndex {
                redacted[index + 1] = "***"
            } else if redacted[index].hasPrefix("--api-key=") {
                redacted[index] = "--api-key=***"
            }
        }

        return redacted
    }

    private func resolveExecutablePath(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("/") {
            return isExecutableFile(atAbsolutePath: trimmed) ? trimmed : nil
        }

        return resolveShellCommandPath(trimmed)
    }

    private func resolveShellCommandPath(_ command: String) -> String? {
        for directory in shellSearchPaths() {
            let executablePath = URL(fileURLWithPath: directory).appendingPathComponent(command, isDirectory: false).path
            if FileManager.default.isExecutableFile(atPath: executablePath) {
                return executablePath
            }
        }

        return nil
    }

    private func shellSearchPaths() -> [String] {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let mergedPath = envPath.isEmpty ? fallback : "\(envPath):\(fallback)"

        return mergedPath
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func asrHostPort(fromBaseURLText baseURLText: String) -> (host: String, port: Int)? {
        let normalized = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: normalized) else {
            return nil
        }

        let host = components.host ?? "127.0.0.1"
        let port = components.port ?? 8765
        return (host, port)
    }

    private func isLocalHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }

    private func waitForHTTPServiceReachable(url: URL, timeout: TimeInterval, maxWaitSeconds: TimeInterval) -> Bool {
        let attempts = max(1, Int(ceil(maxWaitSeconds / 0.5)))

        for attempt in 0..<attempts {
            if isHTTPServiceReachable(url: url, timeout: timeout) {
                return true
            }

            if attempt < attempts - 1 {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        return false
    }

    private func commandSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var isSingleQuoted = false
        var isDoubleQuoted = false
        var isEscaped = false
        var commandSubstitutionDepth = 0

        let characters = Array(command)
        var index = 0

        func flushSegment() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(trimmed)
            }
            current.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            let character = characters[index]

            if isEscaped {
                current.append(character)
                isEscaped = false
                index += 1
                continue
            }

            if character == "\\" && !isSingleQuoted {
                current.append(character)
                isEscaped = true
                index += 1
                continue
            }

            if character == "'" && !isDoubleQuoted && commandSubstitutionDepth == 0 {
                isSingleQuoted.toggle()
                current.append(character)
                index += 1
                continue
            }

            if character == "\"" && !isSingleQuoted && commandSubstitutionDepth == 0 {
                isDoubleQuoted.toggle()
                current.append(character)
                index += 1
                continue
            }

            if !isSingleQuoted {
                if character == "(" && index > 0 && characters[index - 1] == "$" {
                    commandSubstitutionDepth += 1
                } else if character == ")" && commandSubstitutionDepth > 0 {
                    commandSubstitutionDepth -= 1
                }
            }

            let isTopLevel = !isSingleQuoted && !isDoubleQuoted && commandSubstitutionDepth == 0
            if isTopLevel {
                if character == ";" || character == "\n" {
                    flushSegment()
                    index += 1
                    continue
                }

                if character == "&", index + 1 < characters.count, characters[index + 1] == "&" {
                    flushSegment()
                    index += 2
                    continue
                }

                if character == "|", index + 1 < characters.count, characters[index + 1] == "|" {
                    flushSegment()
                    index += 2
                    continue
                }

                if character == "|" {
                    flushSegment()
                    index += 1
                    continue
                }
            }

            current.append(character)
            index += 1
        }

        flushSegment()
        return segments
    }

    private func executableCandidate(from commandSegment: String) -> String? {
        var remainder = commandSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return nil
        }

        while let firstWord = firstShellWord(from: remainder) {
            remainder = firstWord.remainder

            if isShellAssignmentWord(firstWord.word) {
                continue
            }

            let cleaned = firstWord.word.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard !cleaned.isEmpty else {
                return nil
            }

            // Skip shell grouping / test operator tokens like "([" that are not executables.
            if cleaned.range(of: "[A-Za-z0-9/_\\.~-]", options: .regularExpression) == nil {
                continue
            }

            if cleaned.hasPrefix("$(") || cleaned.hasPrefix("${") || cleaned.hasPrefix("$.") || cleaned.hasPrefix("-") {
                return nil
            }

            if Self.shellBuiltins.contains(cleaned) {
                return nil
            }

            return cleaned
        }

        return nil
    }

    private func firstShellWord(from text: String) -> (word: String, remainder: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        var word = ""
        var isSingleQuoted = false
        var isDoubleQuoted = false
        var isEscaped = false
        var commandSubstitutionDepth = 0

        let characters = Array(trimmed)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if isEscaped {
                word.append(character)
                isEscaped = false
                index += 1
                continue
            }

            if character == "\\" && !isSingleQuoted {
                word.append(character)
                isEscaped = true
                index += 1
                continue
            }

            if character == "'" && !isDoubleQuoted && commandSubstitutionDepth == 0 {
                isSingleQuoted.toggle()
                word.append(character)
                index += 1
                continue
            }

            if character == "\"" && !isSingleQuoted && commandSubstitutionDepth == 0 {
                isDoubleQuoted.toggle()
                word.append(character)
                index += 1
                continue
            }

            if !isSingleQuoted {
                if character == "(" && index > 0 && characters[index - 1] == "$" {
                    commandSubstitutionDepth += 1
                } else if character == ")" && commandSubstitutionDepth > 0 {
                    commandSubstitutionDepth -= 1
                }
            }

            let isTopLevel = !isSingleQuoted && !isDoubleQuoted && commandSubstitutionDepth == 0
            if isTopLevel && character.isWhitespace {
                break
            }

            word.append(character)
            index += 1
        }

        let remainder = index < characters.count
            ? String(characters[(index + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        return (word: word, remainder: remainder)
    }

    private func isShellAssignmentWord(_ token: String) -> Bool {
        guard let equalIndex = token.firstIndex(of: "=") else {
            return false
        }

        let name = token[..<equalIndex]
        guard !name.isEmpty else {
            return false
        }

        guard let firstCharacter = name.first,
              firstCharacter == "_" || firstCharacter.isLetter else {
            return false
        }

        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private func isExecutableFile(atAbsolutePath path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return FileManager.default.isExecutableFile(atPath: standardized)
    }

    private func isShellCommandAvailable(_ command: String) -> Bool {
        guard !command.isEmpty else {
            return false
        }

        return resolveShellCommandPath(command) != nil
    }

    private func makeASRHealthURL(fromBaseURL baseURL: URL) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""

        if path.hasSuffix("/v1") {
            path.removeLast(3)
        }

        if path.isEmpty {
            path = "/health"
        } else if path.hasSuffix("/") {
            path += "health"
        } else {
            path += "/health"
        }

        components?.path = path
        return components?.url
    }

    private func isHTTPServiceReachable(url: URL, timeout: TimeInterval) -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(1, timeout)

        let semaphore = DispatchSemaphore(value: 0)
        var isReachable = false

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }

            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return
            }

            isReachable = true
        }

        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + max(2, timeout + 1))
        if waitResult == .timedOut {
            task.cancel()
            return false
        }

        return isReachable
    }

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
        AppFileLogger.shared.info(category: "ControllerManager", message)
        onLog?(message)
        print("[ControllerManager] \(message)")
    }

    private func logDebug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        AppFileLogger.shared.debug(category: "ControllerManager", message)
        onLog?(message)
        print("[ControllerManager] \(message)")
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        AppFileLogger.shared.error(category: "ControllerManager", message)
        onLog?(message)
        print("[ControllerManager] \(message)")
    }
}
