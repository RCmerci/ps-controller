import Foundation
import GameController
import OSLog

enum ControllerConnectionState {
    case connected(name: String)
    case disconnected
}

final class ControllerManager {
    private static let deadzone: Float = 0.12
    private static let fixedASRAutoStartAPIKey = "ps-controller-mlx-qwen3-asr"
    private static let defaultKeyActionLabel = "Default Key"
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
    private let controllerActionHintPresenter: ControllerActionHintPresenting
    private let voiceInputController: VoiceInputControlling
    private let textInputInjector: TextInputInjecting
    private let voiceTranscriptRefiner: VoiceTranscriptRefining

    private var configuration: ControllerConfiguration = .default

    private var isWheelVisible = false
    private var selectedWheelSlotIndex: Int?
    private var pendingVoiceRefinementID: UUID?
    private var isControllerActionHintVisible = false

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
        controllerActionHintPresenter: ControllerActionHintPresenting = ControllerActionHintPresenter(),
        voiceInputController: VoiceInputControlling = Qwen3ASRVoiceInputController(),
        textInputInjector: TextInputInjecting = CGEventTextInputInjector(),
        voiceTranscriptRefiner: VoiceTranscriptRefining = OllamaVoiceTranscriptRefiner()
    ) {
        self.mouseBridge = mouseBridge
        self.logger = logger
        self.configurationProvider = configurationProvider
        self.scriptExecutor = scriptExecutor
        self.leftThumbstickWheelPresenter = leftThumbstickWheelPresenter
        self.controllerActionHintPresenter = controllerActionHintPresenter
        self.voiceInputController = voiceInputController
        self.textInputInjector = textInputInjector
        self.voiceTranscriptRefiner = voiceTranscriptRefiner
        self.configuration = applyRuntimeVoiceInputAdjustments(
            configurationProvider.loadConfiguration().normalizedForRuntime()
        )

        self.voiceInputController.updateConfiguration(self.configuration.voiceInput)
        self.voiceInputController.onTranscript = { [weak self] event in
            self?.handleVoiceTranscript(event)
        }
    }

    func startMonitoring() {
        configuration = applyRuntimeVoiceInputAdjustments(
            configurationProvider.loadConfiguration().normalizedForRuntime()
        )
        voiceInputController.updateConfiguration(configuration.voiceInput)

        let voiceInputEnabled = configuration.voiceInput?.enabled == true
        let asrBaseURL = configuration.voiceInput?.asrServer.baseURL ?? "none"
        let asrModel = configuration.voiceInput?.asrServer.model ?? "none"
        let asrAPIKeyConfigured = !(configuration.voiceInput?.asrServer.apiKey.isEmpty ?? true)
        let asrAutoStart = configuration.voiceInput?.asrServer.autoStart ?? false
        let asrLaunchExecutable = configuration.voiceInput?.asrServer.launchExecutable ?? "none"
        let llmRefinerEnabled = configuration.voiceInput?.llmRefiner.enabled == true
        let llmRefinerModel = configuration.voiceInput?.llmRefiner.model ?? "none"
        logInfo("Loaded configuration. buttonBindings=\(configuration.buttons.count) wheelSlots=\(configuration.leftThumbstickWheel.slots.count) voiceInputEnabled=\(voiceInputEnabled) voiceInputButtons=buttonB:zh-CN asrBaseURL=\(asrBaseURL) asrModel=\(asrModel) asrApiKeyConfigured=\(asrAPIKeyConfigured) asrAutoStart=\(asrAutoStart) asrLaunchExecutable=\(asrLaunchExecutable) llmRefinerEnabled=\(llmRefinerEnabled) llmRefinerModel=\(llmRefinerModel)")

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
            hideWheelIfVisible(reason: "control_paused")
            hideControllerActionHintIfVisible(reason: "control_paused")
            voiceInputController.stopCapture(trigger: "control_paused")
            cancelPendingVoiceRefinement(reason: "control_paused")
        }
        logInfo("Control enabled set to: \(enabled)")
    }

    deinit {
        stopInputLoop()
        stopASRAutoStartedProcessIfNeeded(reason: "controller_manager_deinit")
        hideControllerActionHintIfVisible(reason: "controller_manager_deinit")
        voiceInputController.stopCapture(trigger: "controller_manager_deinit")
        cancelPendingVoiceRefinement(reason: "controller_manager_deinit")

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
        leftTrigger: Float,
        rightTrigger: Float
    ) {
        guard isControlEnabled else { return }

        _ = leftTrigger
        _ = rightTrigger

        handleLeftThumbstickWheel(leftX: leftX, leftY: leftY)

        let filteredRightX = normalizedThumbstickValue(rightX)
        let filteredRightY = normalizedThumbstickValue(rightY)

        if filteredRightX != 0 || filteredRightY != 0 {
            mouseBridge.moveCursor(
                normalizedX: Double(filteredRightX),
                normalizedY: Double(filteredRightY)
            )
        }

    }

    func normalizedThumbstickValue(_ raw: Float) -> Float {
        abs(raw) >= Self.deadzone ? raw : 0
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
        hideWheelIfVisible(reason: "controller_disconnected")
        hideControllerActionHintIfVisible(reason: "controller_disconnected")

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

        guard isPressed else { return }

        guard let binding = configuration.buttons[button] else {
            logDebug("No configured script for button=\(button.rawValue)")
            return
        }

        logInfo("button_pressed button=\(button.rawValue) script=\(binding.name) command=\(binding.command)")
        scriptExecutor.execute(binding: binding, trigger: "button.\(button.rawValue)")
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

        if button == .rightThumbstickButton {
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
        logInfo("voice_input_transcript final=\(event.isFinal) text=\(event.text)")

        guard event.isFinal else {
            logDebug("voice_input_partial_skip_insertion")
            return
        }

        let normalized = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            logDebug("voice_input_final_skip_empty")
            return
        }

        guard let llmConfig = configuration.voiceInput?.llmRefiner, llmConfig.enabled else {
            insertVoiceTranscriptAtCursor(normalized, source: "raw")
            return
        }

        let refinementID = UUID()
        pendingVoiceRefinementID = refinementID
        logInfo("voice_input_refine_start id=\(refinementID.uuidString) model=\(llmConfig.model) baseURL=\(llmConfig.baseURL)")

        voiceTranscriptRefiner.refine(text: normalized, configuration: llmConfig) { [weak self] result in
            guard let self else { return }

            guard self.pendingVoiceRefinementID == refinementID else {
                self.logDebug("voice_input_refine_stale_response id=\(refinementID.uuidString)")
                return
            }

            self.pendingVoiceRefinementID = nil

            switch result {
            case .success(let refinedText):
                let cleaned = refinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalText = cleaned.isEmpty ? normalized : cleaned
                self.logInfo("voice_input_refine_success id=\(refinementID.uuidString) changed=\(finalText != normalized)")
                self.insertVoiceTranscriptAtCursor(finalText, source: "refined")
            case .failure(let error):
                self.logError("voice_input_refine_failed id=\(refinementID.uuidString) message=\(error.localizedDescription)")
                self.insertVoiceTranscriptAtCursor(normalized, source: "refine_fallback")
            }
        }
    }

    private func insertVoiceTranscriptAtCursor(_ text: String, source: String) {
        let inserted = textInputInjector.insertAtCursor(text: text)
        logInfo("voice_input_insert_cursor success=\(inserted) chars=\(text.count) source=\(source)")
    }

    private func cancelPendingVoiceRefinement(reason: String) {
        pendingVoiceRefinementID = nil
        voiceTranscriptRefiner.cancelCurrentRefinement(reason: reason)
        logDebug("voice_input_refine_cancel reason=\(reason)")
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

        logInfo("voice_input_prepare buttons=buttonB:zh-CN asrBaseURL=\(voiceInput.asrServer.baseURL) asrModel=\(voiceInput.asrServer.model) asrApiKeyConfigured=\(!voiceInput.asrServer.apiKey.isEmpty) asrAutoStart=\(voiceInput.asrServer.autoStart) asrLaunchExecutable=\(voiceInput.asrServer.launchExecutable) llmRefinerEnabled=\(voiceInput.llmRefiner.enabled) llmModel=\(voiceInput.llmRefiner.model)")
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
            cancelPendingVoiceRefinement(reason: "new_capture_start")
            logInfo("voice_input_start trigger=\(trigger) locale=\(localeIdentifier)")
            voiceInputController.startCapture(trigger: trigger, localeIdentifier: localeIdentifier)
        } else {
            logInfo("voice_input_stop trigger=\(trigger) locale=\(localeIdentifier)")
            voiceInputController.stopCapture(trigger: trigger)
        }

        return true
    }

    private func voiceInputLocaleIdentifier(for button: ControllerButton) -> String? {
        switch button {
        case .buttonB:
            return "zh-CN"
        default:
            return nil
        }
    }

    private func handleFixedClickButton(_ button: ControllerButton, isPressed: Bool) -> Bool {
        guard button == .rightThumbstickButton else {
            return false
        }

        guard isPressed else {
            return true
        }

        mouseBridge.leftClick()
        logInfo("right_thumbstick_button_left_click")
        return true
    }

    private func handleLeftThumbstickWheel(leftX: Float, leftY: Float) {
        let magnitude = sqrt((leftX * leftX) + (leftY * leftY))
        let threshold = configuration.leftThumbstickWheel.activationThreshold
        let slots = configuration.leftThumbstickWheel.slots

        guard slots.count == 6 else {
            logDebug("Wheel config invalid slot count: \(slots.count)")
            return
        }

        if magnitude >= threshold {
            let index = wheelSlotIndex(leftX: leftX, leftY: leftY)

            if !isWheelVisible {
                isWheelVisible = true
                selectedWheelSlotIndex = index
                leftThumbstickWheelPresenter.show(slots: slots, selectedIndex: index)
                logInfo("left_thumbstick_wheel_show slot=\(index + 1) title=\(slots[index].title)")
                return
            }

            if selectedWheelSlotIndex != index {
                selectedWheelSlotIndex = index
                leftThumbstickWheelPresenter.updateSelection(selectedIndex: index, slots: slots)
                logInfo("left_thumbstick_wheel_select slot=\(index + 1) title=\(slots[index].title)")
            }

            return
        }

        guard isWheelVisible else { return }

        leftThumbstickWheelPresenter.hide()
        isWheelVisible = false

        guard let selectedWheelSlotIndex else {
            logDebug("left_thumbstick_wheel_hide without selection")
            return
        }

        self.selectedWheelSlotIndex = nil

        let slot = slots[selectedWheelSlotIndex]
        logInfo("left_thumbstick_wheel_confirm slot=\(selectedWheelSlotIndex + 1) title=\(slot.title)")

        guard let binding = slot.script else {
            if slot.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cancel" {
                logInfo("left_thumbstick_wheel_cancelled slot=\(selectedWheelSlotIndex + 1)")
            } else {
                logDebug("left_thumbstick_wheel_no_script slot=\(selectedWheelSlotIndex + 1) title=\(slot.title)")
            }
            return
        }

        scriptExecutor.execute(binding: binding, trigger: "leftThumbstick.slot\(selectedWheelSlotIndex + 1)")
    }

    private func wheelSlotIndex(leftX: Float, leftY: Float) -> Int {
        let angleFromXAxis = atan2(Double(leftY), Double(leftX)) * 180 / Double.pi
        let clockwiseFromUp = fmod((90.0 - angleFromXAxis + 360.0), 360.0)
        let shifted = fmod(clockwiseFromUp + 30.0, 360.0)
        return Int(shifted / 60.0)
    }

    private func hideWheelIfVisible(reason: String) {
        guard isWheelVisible else { return }
        isWheelVisible = false
        selectedWheelSlotIndex = nil
        leftThumbstickWheelPresenter.hide()
        logInfo("left_thumbstick_wheel_hide reason=\(reason)")
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

        processInput(
            leftX: gamepad.leftThumbstick.xAxis.value,
            leftY: gamepad.leftThumbstick.yAxis.value,
            rightX: gamepad.rightThumbstick.xAxis.value,
            rightY: gamepad.rightThumbstick.yAxis.value,
            leftTrigger: gamepad.leftTrigger.value,
            rightTrigger: gamepad.rightTrigger.value
        )
    }

    private enum ASRAutoStartStatus {
        case skipped
        case started
        case alreadyRunning
        case failed(String)
    }

    private func applyRuntimeVoiceInputAdjustments(_ configuration: ControllerConfiguration) -> ControllerConfiguration {
        guard let voiceInput = configuration.voiceInput else {
            return configuration
        }

        let asrServer = voiceInput.asrServer
        guard voiceInput.enabled,
              asrServer.autoStart else {
            return configuration
        }

        if asrServer.apiKey == Self.fixedASRAutoStartAPIKey {
            return configuration
        }

        let updatedASRServer = VoiceInputASRServerConfiguration(
            baseURL: asrServer.baseURL,
            apiKey: Self.fixedASRAutoStartAPIKey,
            model: asrServer.model,
            timeoutSeconds: asrServer.timeoutSeconds,
            autoStart: asrServer.autoStart,
            launchExecutable: asrServer.launchExecutable,
            launchArguments: asrServer.launchArguments
        )

        let updatedVoiceInput = VoiceInputConfiguration(
            enabled: voiceInput.enabled,
            activationButton: voiceInput.activationButton,
            asrServer: updatedASRServer,
            llmRefiner: voiceInput.llmRefiner
        )

        if asrServer.apiKey.isEmpty {
            logInfo("asr_auto_start_apply_fixed_api_key value=\(Self.fixedASRAutoStartAPIKey)")
        } else {
            logInfo("asr_auto_start_override_api_key with fixed value=\(Self.fixedASRAutoStartAPIKey)")
        }

        return ControllerConfiguration(
            buttons: configuration.buttons,
            leftThumbstickWheel: configuration.leftThumbstickWheel,
            voiceInput: updatedVoiceInput
        )
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

        if resolution.source == "app_support" && !resolution.fileExists {
            issues.append("Config file missing; default config was generated at: \(resolution.url.path)")
        }

        return issues
    }

    private func scriptCommandDependencyIssues(configuration: ControllerConfiguration) -> [String] {
        var commandNames: Set<String> = []
        var absoluteExecutablePaths: Set<String> = []

        let allCommands = configuration.buttons.values.map(\.command)
            + configuration.leftThumbstickWheel.slots.compactMap { $0.script?.command }

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

        if asrServer.apiKey.isEmpty, !asrServer.autoStart {
            issues.append("voiceInput.asrServer.apiKey is empty")
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

        if voiceInput.llmRefiner.enabled {
            let llmBaseURLText = voiceInput.llmRefiner.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let llmBaseURL = URL(string: llmBaseURLText) else {
                issues.append("Invalid llmRefiner.baseURL: \(voiceInput.llmRefiner.baseURL)")
                return issues
            }

            let tagsURL = llmBaseURL.appendingPathComponent("api/tags", isDirectory: false)
            if !isHTTPServiceReachable(url: tagsURL, timeout: min(voiceInput.llmRefiner.timeoutSeconds, 5)) {
                issues.append("Ollama unavailable at: \(tagsURL.absoluteString)")
            }
        }

        return issues
    }

    private func ensureASRServerRunning(asrServer: VoiceInputASRServerConfiguration) -> ASRAutoStartStatus {
        guard asrServer.autoStart else {
            return .skipped
        }

        if let asrAutoStartedProcess, asrAutoStartedProcess.isRunning {
            return .alreadyRunning
        }

        guard !asrServer.apiKey.isEmpty else {
            return .failed("voiceInput.asrServer.apiKey is empty")
        }

        guard let executablePath = resolveExecutablePath(asrServer.launchExecutable) else {
            return .failed("Cannot find launch executable: \(asrServer.launchExecutable)")
        }

        var arguments = normalizedASRAutoStartArguments(asrServer)

        if !containsCLIOption(arguments, "--api-key") {
            arguments.append(contentsOf: ["--api-key", asrServer.apiKey])
        }

        if !containsCLIOption(arguments, "--model") {
            arguments.append(contentsOf: ["--model", asrServer.model])
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
        let normalized = asrServer.launchArguments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return normalized.isEmpty ? ["serve"] : normalized
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
        command
            .split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func executableCandidate(from commandSegment: String) -> String? {
        let trimmed = commandSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        var segment = trimmed

        while let spaceIndex = segment.firstIndex(of: " ") {
            let token = String(segment[..<spaceIndex])
            if token.contains("=") && !token.hasPrefix("/") {
                segment = String(segment[segment.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            break
        }

        if segment.hasPrefix("\"") {
            let remainder = segment.dropFirst()
            guard let endQuote = remainder.firstIndex(of: "\"") else {
                return nil
            }
            let value = String(remainder[..<endQuote])
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let token = segment.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("$(") {
            return nil
        }

        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !cleaned.isEmpty else {
            return nil
        }

        if Self.shellBuiltins.contains(cleaned) {
            return nil
        }

        return cleaned
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
