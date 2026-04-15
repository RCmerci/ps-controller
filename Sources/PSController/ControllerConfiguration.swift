import Foundation

enum ControllerButton: String, CaseIterable, Codable {
    case buttonA
    case buttonB
    case buttonX
    case buttonY

    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight

    case leftShoulder
    case rightShoulder
    case leftTrigger
    case rightTrigger

    case leftThumbstickButton
    case rightThumbstickButton

    case buttonMenu
    case buttonOptions
    case buttonHome
}

struct ScriptBinding: Codable, Equatable {
    let name: String
    let command: String
    let workingDirectory: String?

    init(name: String, command: String, workingDirectory: String? = nil) {
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
    }
}

struct ThumbstickWheelSlot: Codable, Equatable {
    let title: String
    let script: ScriptBinding?

    init(title: String, script: ScriptBinding? = nil) {
        self.title = title
        self.script = script
    }
}

struct LeftThumbstickWheelConfiguration: Codable, Equatable {
    let activationThreshold: Float
    let slots: [ThumbstickWheelSlot]

    init(activationThreshold: Float, slots: [ThumbstickWheelSlot]) {
        self.activationThreshold = activationThreshold
        self.slots = slots
    }
}

struct VoiceInputASRServerConfiguration: Codable, Equatable {
    let baseURL: String
    let apiKey: String
    let model: String
    let timeoutSeconds: TimeInterval
    let autoStart: Bool
    let launchExecutable: String
    let launchArguments: [String]

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case apiKey
        case model
        case timeoutSeconds
        case autoStart
        case launchExecutable
        case launchArguments
    }

    init(
        baseURL: String = "http://127.0.0.1:8765",
        apiKey: String = "ps-controller-mlx-qwen3-asr",
        model: String = "Qwen/Qwen3-ASR-0.6B",
        timeoutSeconds: TimeInterval = 30,
        autoStart: Bool = false,
        launchExecutable: String = "mlx-qwen3-asr",
        launchArguments: [String] = ["serve", "--job-ttl", "120"]
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.autoStart = autoStart
        self.launchExecutable = launchExecutable
        self.launchArguments = launchArguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.default.baseURL
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? Self.default.apiKey
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model
        self.timeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? Self.default.timeoutSeconds
        self.autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? Self.default.autoStart
        self.launchExecutable = try container.decodeIfPresent(String.self, forKey: .launchExecutable) ?? Self.default.launchExecutable
        self.launchArguments = try container.decodeIfPresent([String].self, forKey: .launchArguments) ?? Self.default.launchArguments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(model, forKey: .model)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(autoStart, forKey: .autoStart)
        try container.encode(launchExecutable, forKey: .launchExecutable)
        try container.encode(launchArguments, forKey: .launchArguments)
    }

    static let `default` = VoiceInputASRServerConfiguration()

    func normalizedForRuntime() -> VoiceInputASRServerConfiguration {
        let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExecutable = launchExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLaunchArguments = launchArguments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedTimeout = min(max(timeoutSeconds, 3), 180)

        return VoiceInputASRServerConfiguration(
            baseURL: normalizedBaseURL.isEmpty ? Self.default.baseURL : normalizedBaseURL,
            apiKey: normalizedAPIKey,
            model: normalizedModel.isEmpty ? Self.default.model : normalizedModel,
            timeoutSeconds: normalizedTimeout,
            autoStart: autoStart,
            launchExecutable: normalizedExecutable.isEmpty ? Self.default.launchExecutable : normalizedExecutable,
            launchArguments: normalizedLaunchArguments.isEmpty ? Self.default.launchArguments : normalizedLaunchArguments
        )
    }
}

struct VoiceInputConfiguration: Codable, Equatable {
    let enabled: Bool
    let activationButton: ControllerButton
    let asrServer: VoiceInputASRServerConfiguration

    private enum CodingKeys: String, CodingKey {
        case enabled
        case activationButton
        case asrServer
    }

    init(
        enabled: Bool = false,
        activationButton: ControllerButton = .buttonOptions,
        asrServer: VoiceInputASRServerConfiguration = .default
    ) {
        self.enabled = enabled
        self.activationButton = activationButton
        self.asrServer = asrServer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.activationButton = try container.decode(ControllerButton.self, forKey: .activationButton)
        self.asrServer = try container.decodeIfPresent(VoiceInputASRServerConfiguration.self, forKey: .asrServer) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(activationButton, forKey: .activationButton)
        try container.encode(asrServer, forKey: .asrServer)
    }

    func normalizedForRuntime() -> VoiceInputConfiguration {
        VoiceInputConfiguration(
            enabled: enabled,
            activationButton: activationButton,
            asrServer: asrServer.normalizedForRuntime()
        )
    }
}

struct ControllerConfiguration: Codable, Equatable {
    let buttons: [ControllerButton: ScriptBinding]
    let leftThumbstickWheel: LeftThumbstickWheelConfiguration
    let voiceInput: VoiceInputConfiguration?

    private enum CodingKeys: String, CodingKey {
        case buttons
        case leftThumbstickWheel
        case voiceInput
    }

    init(
        buttons: [ControllerButton: ScriptBinding],
        leftThumbstickWheel: LeftThumbstickWheelConfiguration,
        voiceInput: VoiceInputConfiguration? = nil
    ) {
        self.buttons = buttons
        self.leftThumbstickWheel = leftThumbstickWheel
        self.voiceInput = voiceInput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let stringKeyedButtons = try? container.decode([String: ScriptBinding].self, forKey: .buttons) {
            var mappedButtons: [ControllerButton: ScriptBinding] = [:]

            for (key, binding) in stringKeyedButtons {
                guard let button = ControllerButton(rawValue: key) else { continue }
                mappedButtons[button] = binding
            }

            self.buttons = mappedButtons
        } else {
            // Backward compatibility with legacy encoded format.
            self.buttons = try container.decode([ControllerButton: ScriptBinding].self, forKey: .buttons)
        }

        self.leftThumbstickWheel = try container.decode(LeftThumbstickWheelConfiguration.self, forKey: .leftThumbstickWheel)
        self.voiceInput = try container.decodeIfPresent(VoiceInputConfiguration.self, forKey: .voiceInput)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        let stringKeyedButtons = Dictionary(uniqueKeysWithValues: buttons.map { ($0.key.rawValue, $0.value) })
        try container.encode(stringKeyedButtons, forKey: .buttons)
        try container.encode(leftThumbstickWheel, forKey: .leftThumbstickWheel)
        try container.encodeIfPresent(voiceInput, forKey: .voiceInput)
    }

    static let `default` = ControllerConfiguration(
        buttons: defaultButtonBindings(),
        leftThumbstickWheel: LeftThumbstickWheelConfiguration(
            activationThreshold: 0.45,
            slots: [
                ThumbstickWheelSlot(title: "Slot 1", script: ScriptBinding(name: "slot-1", command: "echo 'slot-1'")),
                ThumbstickWheelSlot(title: "Slot 2", script: ScriptBinding(name: "slot-2", command: "echo 'slot-2'")),
                ThumbstickWheelSlot(title: "Slot 3", script: ScriptBinding(name: "slot-3", command: "echo 'slot-3'")),
                ThumbstickWheelSlot(title: "Slot 4", script: ScriptBinding(name: "slot-4", command: "echo 'slot-4'")),
                ThumbstickWheelSlot(title: "Slot 5", script: ScriptBinding(name: "slot-5", command: "echo 'slot-5'")),
                ThumbstickWheelSlot(title: "Cancel", script: nil)
            ]
        ),
        voiceInput: VoiceInputConfiguration(enabled: false, activationButton: .buttonOptions)
    )

    func normalizedForRuntime() -> ControllerConfiguration {
        let slots = normalizedWheelSlots(leftThumbstickWheel.slots)
        let threshold = min(max(leftThumbstickWheel.activationThreshold, 0.1), 0.95)

        return ControllerConfiguration(
            buttons: buttons,
            leftThumbstickWheel: LeftThumbstickWheelConfiguration(
                activationThreshold: threshold,
                slots: slots
            ),
            voiceInput: voiceInput?.normalizedForRuntime()
        )
    }

    private static func defaultButtonBindings() -> [ControllerButton: ScriptBinding] {
        var result: [ControllerButton: ScriptBinding] = [:]

        for button in ControllerButton.allCases {
            result[button] = ScriptBinding(
                name: button.rawValue,
                command: "echo 'Configure script for \(button.rawValue)'"
            )
        }

        return result
    }

    private func normalizedWheelSlots(_ currentSlots: [ThumbstickWheelSlot]) -> [ThumbstickWheelSlot] {
        if currentSlots.count == 6 {
            return currentSlots
        }

        if currentSlots.count > 6 {
            return Array(currentSlots.prefix(6))
        }

        var slots = currentSlots
        while slots.count < 6 {
            let index = slots.count + 1

            if index == 6 {
                slots.append(ThumbstickWheelSlot(title: "Cancel", script: nil))
            } else {
                slots.append(
                    ThumbstickWheelSlot(
                        title: "Slot \(index)",
                        script: ScriptBinding(name: "slot-\(index)", command: "echo 'slot-\(index)'")
                    )
                )
            }
        }

        return slots
    }
}
