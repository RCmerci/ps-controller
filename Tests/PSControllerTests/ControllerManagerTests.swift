import XCTest
import OSLog
import Foundation
@testable import PSController

final class ControllerManagerTests: XCTestCase {
    func testConfiguredButtonPressExecutesMappedScript() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let config = ControllerConfiguration(
            buttons: [
                .buttonA: ScriptBinding(name: "script-a", command: "echo a"),
                .buttonB: ScriptBinding(name: "script-b", command: "echo b")
            ],
            leftThumbstickWheel: makeWheelConfig()
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        sut.handlePrimaryButtonPress(isPressed: false)
        sut.handleSecondaryButtonPress(isPressed: false)
        XCTAssertEqual(executor.executions.count, 0)

        sut.handlePrimaryButtonPress(isPressed: true)
        sut.handleSecondaryButtonPress(isPressed: true)

        XCTAssertEqual(executor.executions.count, 2)
        XCTAssertEqual(executor.executions[0].trigger, "button.buttonA")
        XCTAssertEqual(executor.executions[0].binding.name, "script-a")
        XCTAssertEqual(executor.executions[1].trigger, "button.buttonB")
        XCTAssertEqual(executor.executions[1].binding.name, "script-b")
    }

    func testControllerConfigurationDecodesStringKeyedButtonsJSON() throws {
        let json = """
        {
          "buttons": {
            "buttonA": {
              "name": "buttonA",
              "command": "echo 'Configure script for buttonA'"
            }
          },
          "leftThumbstickWheel": {
            "activationThreshold": 0.45,
            "slots": [
              {
                "title": "Emacs",
                "script": {
                  "name": "switch-emacs",
                  "command": "osascript -e 'tell application \\\"Emacs\\\" to activate'"
                }
              },
              { "title": "Slot 2", "script": null },
              { "title": "Slot 3", "script": null },
              { "title": "Slot 4", "script": null },
              { "title": "Slot 5", "script": null },
              { "title": "Cancel", "script": null }
            ]
          }
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ControllerConfiguration.self, from: data)

        XCTAssertEqual(decoded.buttons[.buttonA]?.name, "buttonA")
        XCTAssertEqual(decoded.leftThumbstickWheel.slots.first?.title, "Emacs")
        XCTAssertEqual(decoded.leftThumbstickWheel.slots.first?.script?.name, "switch-emacs")
    }

    func testControllerConfigurationDecodesVoiceInputConfiguration() throws {
        let json = """
        {
          "buttons": {
            "buttonA": {
              "name": "buttonA",
              "command": "echo 'a'"
            }
          },
          "leftThumbstickWheel": {
            "activationThreshold": 0.45,
            "slots": [
              { "title": "Slot 1", "script": null },
              { "title": "Slot 2", "script": null },
              { "title": "Slot 3", "script": null },
              { "title": "Slot 4", "script": null },
              { "title": "Slot 5", "script": null },
              { "title": "Cancel", "script": null }
            ]
          },
          "voiceInput": {
            "enabled": true,
            "activationButton": "buttonOptions"
          }
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ControllerConfiguration.self, from: data)

        XCTAssertEqual(decoded.voiceInput?.enabled, true)
        XCTAssertEqual(decoded.voiceInput?.activationButton, .buttonOptions)
        XCTAssertEqual(decoded.voiceInput?.asrServer, .default)
        XCTAssertEqual(decoded.voiceInput?.asrServer.autoStart, false)
        XCTAssertEqual(decoded.voiceInput?.asrServer.launchExecutable, "mlx-qwen3-asr")
        XCTAssertEqual(decoded.voiceInput?.asrServer.launchArguments, ["serve", "--job-ttl", "120"])
    }

    func testControllerConfigurationDecodesVoiceInputASRServerConfiguration() throws {
        let json = """
        {
          "buttons": {
            "buttonA": {
              "name": "buttonA",
              "command": "echo 'a'"
            }
          },
          "leftThumbstickWheel": {
            "activationThreshold": 0.45,
            "slots": [
              { "title": "Slot 1", "script": null },
              { "title": "Slot 2", "script": null },
              { "title": "Slot 3", "script": null },
              { "title": "Slot 4", "script": null },
              { "title": "Slot 5", "script": null },
              { "title": "Cancel", "script": null }
            ]
          },
          "voiceInput": {
            "enabled": true,
            "activationButton": "buttonOptions",
            "asrServer": {
              "baseURL": "http://127.0.0.1:8765",
              "apiKey": "test-key",
              "model": "Qwen/Qwen3-ASR-1.7B",
              "timeoutSeconds": 45,
              "autoStart": true,
              "launchExecutable": "/opt/homebrew/bin/mlx-qwen3-asr",
              "launchArguments": ["serve", "--workers", "1"]
            }
          }
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ControllerConfiguration.self, from: data)

        XCTAssertEqual(decoded.voiceInput?.asrServer.baseURL, "http://127.0.0.1:8765")
        XCTAssertEqual(decoded.voiceInput?.asrServer.apiKey, "test-key")
        XCTAssertEqual(decoded.voiceInput?.asrServer.model, "Qwen/Qwen3-ASR-1.7B")
        XCTAssertEqual(decoded.voiceInput?.asrServer.timeoutSeconds, 45)
        XCTAssertEqual(decoded.voiceInput?.asrServer.autoStart, true)
        XCTAssertEqual(decoded.voiceInput?.asrServer.launchExecutable, "/opt/homebrew/bin/mlx-qwen3-asr")
        XCTAssertEqual(decoded.voiceInput?.asrServer.launchArguments, ["serve", "--workers", "1"])
    }

    func testControllerConfigurationIgnoresUnknownLegacyVoiceField() throws {
        let json = """
        {
          "buttons": {
            "buttonA": {
              "name": "buttonA",
              "command": "echo 'a'"
            }
          },
          "leftThumbstickWheel": {
            "activationThreshold": 0.45,
            "slots": [
              { "title": "Slot 1", "script": null },
              { "title": "Slot 2", "script": null },
              { "title": "Slot 3", "script": null },
              { "title": "Slot 4", "script": null },
              { "title": "Slot 5", "script": null },
              { "title": "Cancel", "script": null }
            ]
          },
          "voiceInput": {
            "enabled": true,
            "activationButton": "buttonOptions",
            "legacyWordFixer": {
              "enabled": true,
              "mode": "experimental"
            }
          }
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ControllerConfiguration.self, from: data)

        XCTAssertEqual(decoded.voiceInput?.enabled, true)
        XCTAssertEqual(decoded.voiceInput?.activationButton, .buttonOptions)
        XCTAssertEqual(decoded.voiceInput?.asrServer, .default)
    }

    func testControllerManagerPropagatesVoiceInputConfigurationToController() {
        let bridge = MockMouseEventBridge()
        let voiceInput = MockVoiceInputController()
        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(
                enabled: true,
                activationButton: .buttonB,
                asrServer: VoiceInputASRServerConfiguration(
                    baseURL: "http://127.0.0.1:8765",
                    apiKey: "abc",
                    model: "Qwen/Qwen3-ASR-0.6B",
                    timeoutSeconds: 20
                )
            )
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput
        )

        _ = sut
        XCTAssertEqual(voiceInput.updatedConfigurations.count, 1)

        guard let maybeConfig = voiceInput.updatedConfigurations.first,
              let propagatedConfig = maybeConfig else {
            XCTFail("Expected propagated voiceInput configuration")
            return
        }

        XCTAssertEqual(propagatedConfig.asrServer.apiKey, "abc")
    }

    func testPausedControlBlocksButtonScriptExecution() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        sut.setControlEnabled(false)
        sut.handleButtonInput(.buttonA, isPressed: true)
        sut.handleButtonInput(.buttonX, isPressed: true)

        XCTAssertEqual(executor.executions.count, 0)
    }

    func testButtonBVoiceInputStartsAndStopsWithZhCNLocale() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let config = ControllerConfiguration(
            buttons: [
                .buttonB: ScriptBinding(name: "button-b-script", command: "echo b")
            ],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .buttonB)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput
        )

        sut.handleButtonInput(.buttonB, isPressed: true)
        sut.handleButtonInput(.buttonB, isPressed: false)

        XCTAssertEqual(voiceInput.startTriggers, ["button.buttonB"])
        XCTAssertEqual(voiceInput.startLocaleIdentifiers, ["zh-CN"])
        XCTAssertEqual(voiceInput.stopTriggers, ["button.buttonB"])
        XCTAssertEqual(executor.executions.count, 0)
    }

    func testButtonXExecutesMappedScriptWhenVoiceInputEnabled() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let config = ControllerConfiguration(
            buttons: [
                .buttonX: ScriptBinding(name: "button-x-script", command: "echo x")
            ],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .buttonB)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput
        )

        sut.handleButtonInput(.buttonX, isPressed: true)
        sut.handleButtonInput(.buttonX, isPressed: false)

        XCTAssertEqual(voiceInput.startTriggers, [])
        XCTAssertEqual(voiceInput.stopTriggers, [])
        XCTAssertEqual(executor.executions.count, 1)
        XCTAssertEqual(executor.executions[0].trigger, "button.buttonX")
    }

    func testVoiceInputDisabledFallsBackToButtonScript() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let config = ControllerConfiguration(
            buttons: [
                .buttonB: ScriptBinding(name: "button-b-script", command: "echo b")
            ],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: false, activationButton: .buttonB)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput
        )

        sut.handleButtonInput(.buttonB, isPressed: true)
        sut.handleButtonInput(.buttonB, isPressed: false)

        XCTAssertEqual(voiceInput.startTriggers.count, 0)
        XCTAssertEqual(voiceInput.stopTriggers.count, 0)
        XCTAssertEqual(executor.executions.count, 1)
        XCTAssertEqual(executor.executions[0].trigger, "button.buttonB")
    }

    func testMenuButtonPressShowsActionOverlayAndReleaseHidesIt() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let hintPresenter = MockControllerActionHintPresenter()
        let config = ControllerConfiguration(
            buttons: [
                .buttonA: ScriptBinding(name: "Press Enter", command: "echo enter"),
                .buttonMenu: ScriptBinding(name: "should-not-run", command: "echo menu")
            ],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .buttonB)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            controllerActionHintPresenter: hintPresenter
        )

        sut.handleButtonInput(.buttonMenu, isPressed: true)
        sut.handleButtonInput(.buttonMenu, isPressed: false)

        XCTAssertEqual(hintPresenter.showCallCount, 1)
        XCTAssertEqual(hintPresenter.hideCallCount, 1)
        XCTAssertEqual(executor.executions.count, 0)

        guard let content = hintPresenter.lastContent else {
            XCTFail("Expected overlay content")
            return
        }

        for button in ControllerButton.allCases {
            XCTAssertTrue(content.contains(button.rawValue), "Missing button in overlay: \(button.rawValue)")
        }

        XCTAssertTrue(content.contains("buttonB -> Voice Input (zh-CN)"))
        XCTAssertTrue(content.contains("buttonX -> Default Key"))
        XCTAssertTrue(content.contains("rightThumbstickButton -> Left Click"))
        XCTAssertTrue(content.contains("buttonA -> Press Enter"))
    }

    func testMenuOverlayShowsDefaultKeyForPlaceholderBindings() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let hintPresenter = MockControllerActionHintPresenter()
        let config = ControllerConfiguration(
            buttons: [
                .buttonHome: ScriptBinding(name: "buttonHome", command: "echo 'Configure script for buttonHome'")
            ],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: false, activationButton: .buttonB)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            controllerActionHintPresenter: hintPresenter
        )

        sut.handleButtonInput(.buttonMenu, isPressed: true)

        guard let content = hintPresenter.lastContent else {
            XCTFail("Expected overlay content")
            return
        }

        XCTAssertTrue(content.contains("buttonHome -> Default Key"))
    }

    func testFinalVoiceTranscriptInsertsTextAtCursor() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let textInjector = MockTextInputInjector()
        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .buttonB)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput,
            textInputInjector: textInjector
        )

        _ = sut
        voiceInput.emitTranscript(text: "你好世界", isFinal: true)

        XCTAssertEqual(textInjector.insertedTexts, ["你好世界"])
    }

    func testFinalVoiceTranscriptAppliesDictionaryCorrection() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let textInjector = MockTextInputInjector()
        let corrector = MockVoiceTranscriptCorrector()
        corrector.correctedText = "open Emacs"

        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(
                enabled: true,
                activationButton: .buttonB
            )
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput,
            textInputInjector: textInjector,
            voiceTranscriptCorrector: corrector
        )

        _ = sut
        voiceInput.emitTranscript(text: "open IMAX", isFinal: true)

        XCTAssertEqual(corrector.correctCalls, ["open IMAX"])
        XCTAssertEqual(textInjector.insertedTexts, ["open Emacs"])
    }

    func testFinalVoiceTranscriptKeepsOriginalTextWhenNoDictionaryMatch() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let textInjector = MockTextInputInjector()
        let corrector = MockVoiceTranscriptCorrector()
        corrector.correctedText = nil

        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(
                enabled: true,
                activationButton: .buttonB
            )
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput,
            textInputInjector: textInjector,
            voiceTranscriptCorrector: corrector
        )

        _ = sut
        voiceInput.emitTranscript(text: "你好世界", isFinal: true)

        XCTAssertEqual(corrector.correctCalls, ["你好世界"])
        XCTAssertEqual(textInjector.insertedTexts, ["你好世界"])
    }

    func testPartialVoiceTranscriptDoesNotInsertTextAtCursor() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let textInjector = MockTextInputInjector()
        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .buttonB)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput,
            textInputInjector: textInjector
        )

        _ = sut
        voiceInput.emitTranscript(text: "你好", isFinal: false)

        XCTAssertTrue(textInjector.insertedTexts.isEmpty)
    }

    func testPausedControlBlocksVoiceInputActivation() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let config = ControllerConfiguration(
            buttons: [
                .buttonB: ScriptBinding(name: "button-b-script", command: "echo b")
            ],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .buttonB)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput
        )

        sut.setControlEnabled(false)
        sut.handleButtonInput(.buttonB, isPressed: true)
        sut.handleButtonInput(.buttonB, isPressed: false)

        XCTAssertEqual(voiceInput.startTriggers.count, 0)
        XCTAssertEqual(voiceInput.stopTriggers.count, 1)
        XCTAssertEqual(executor.executions.count, 0)
    }

    func testMissingBindingSkipsExecution() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let config = ControllerConfiguration(
            buttons: [.buttonA: ScriptBinding(name: "script-a", command: "echo a")],
            leftThumbstickWheel: makeWheelConfig()
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        sut.handleButtonInput(.buttonB, isPressed: true)
        XCTAssertEqual(executor.executions.count, 0)
    }

    func testRightThumbstickButtonPressTriggersLeftClickAndSkipsScript() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let config = ControllerConfiguration(
            buttons: [.rightThumbstickButton: ScriptBinding(name: "should-not-run", command: "echo blocked")],
            leftThumbstickWheel: makeWheelConfig()
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        sut.handleButtonInput(.rightThumbstickButton, isPressed: true)
        sut.handleButtonInput(.rightThumbstickButton, isPressed: false)

        XCTAssertEqual(bridge.leftClickCount, 1)
        XCTAssertEqual(executor.executions.count, 0)
    }

    func testRightThumbstickDeadzonePreventsSmallValues() {
        let bridge = MockMouseEventBridge()
        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        sut.processInput(leftX: 0, leftY: 0, rightX: 0.11, rightY: -0.1, leftTrigger: 0, rightTrigger: 0)
        XCTAssertEqual(bridge.moveCount, 0)

        sut.processInput(leftX: 0, leftY: 0, rightX: 0.2, rightY: -0.5, leftTrigger: 0, rightTrigger: 0)

        XCTAssertEqual(bridge.moveCount, 1)
        XCTAssertEqual(bridge.lastMoveX, 0.2, accuracy: 0.001)
        XCTAssertEqual(bridge.lastMoveY, -0.5, accuracy: 0.001)
    }

    func testProcessInputDoesNotApplyHardcodedTriggerScroll() {
        let bridge = MockMouseEventBridge()
        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        sut.processInput(leftX: 0, leftY: 0, leftTrigger: 1.0, rightTrigger: 0.0)
        sut.processInput(leftX: 0, leftY: 0, leftTrigger: 0.0, rightTrigger: 1.0)

        XCTAssertEqual(bridge.scrollCalls.count, 0)
    }

    func testLeftThumbstickWheelShowsThenExecutesSelectedSlotOnRelease() {
        let bridge = MockMouseEventBridge()
        let wheelPresenter = MockLeftThumbstickWheelPresenter()
        let executor = MockScriptExecutor()
        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig()
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: wheelPresenter
        )

        sut.processInput(leftX: 0.0, leftY: 1.0, leftTrigger: 0, rightTrigger: 0)
        XCTAssertEqual(wheelPresenter.showCallCount, 1)
        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 0)
        XCTAssertEqual(executor.executions.count, 0)

        sut.processInput(leftX: 0.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0)
        XCTAssertEqual(wheelPresenter.hideCallCount, 1)
        XCTAssertEqual(executor.executions.count, 1)
        XCTAssertEqual(executor.executions[0].trigger, "leftThumbstick.slot1")
        XCTAssertEqual(executor.executions[0].binding.name, "wheel-slot-1")
    }

    func testLeftThumbstickWheelSelectionChangeUpdatesPresenter() {
        let bridge = MockMouseEventBridge()
        let wheelPresenter = MockLeftThumbstickWheelPresenter()
        let executor = MockScriptExecutor()
        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig()
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: wheelPresenter
        )

        sut.processInput(leftX: 0.0, leftY: 1.0, leftTrigger: 0, rightTrigger: 0)
        sut.processInput(leftX: 1.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0)

        XCTAssertGreaterThanOrEqual(wheelPresenter.updateCallCount, 1)
        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 2)
    }

    func testLeftThumbstickWheelDirectionAlignmentMatchesSlotIndices() {
        let bridge = MockMouseEventBridge()
        let wheelPresenter = MockLeftThumbstickWheelPresenter()
        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: wheelPresenter
        )

        sut.processInput(leftX: 0.0, leftY: 1.0, leftTrigger: 0, rightTrigger: 0)
        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 0)

        sut.processInput(leftX: 1.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0)
        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 2)

        sut.processInput(leftX: 0.0, leftY: -1.0, leftTrigger: 0, rightTrigger: 0)
        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 3)

        sut.processInput(leftX: -1.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0)
        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 5)
    }

    func testLeftThumbstickWheelSlotWithoutScriptDoesNotExecute() {
        let bridge = MockMouseEventBridge()
        let wheelPresenter = MockLeftThumbstickWheelPresenter()
        let executor = MockScriptExecutor()

        var slots = makeWheelSlots()
        slots[0] = ThumbstickWheelSlot(title: "Slot 1", script: nil)
        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: LeftThumbstickWheelConfiguration(activationThreshold: 0.45, slots: slots)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: wheelPresenter
        )

        sut.processInput(leftX: 0.0, leftY: 1.0, leftTrigger: 0, rightTrigger: 0)
        sut.processInput(leftX: 0.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0)

        XCTAssertEqual(executor.executions.count, 0)
        XCTAssertEqual(wheelPresenter.hideCallCount, 1)
    }

    func testDefaultConfigurationHasCancelSlot() {
        let slots = ControllerConfiguration.default.leftThumbstickWheel.slots
        XCTAssertEqual(slots.count, 6)
        XCTAssertEqual(slots[5].title, "Cancel")
        XCTAssertNil(slots[5].script)
    }

    func testDefaultCancelSlotDoesNotExecuteScript() {
        let bridge = MockMouseEventBridge()
        let wheelPresenter = MockLeftThumbstickWheelPresenter()
        let executor = MockScriptExecutor()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: executor,
            wheelPresenter: wheelPresenter
        )

        sut.processInput(leftX: -1.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0)
        sut.processInput(leftX: 0.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0)

        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 5)
        XCTAssertEqual(executor.executions.count, 0)
    }

    private func makeSUT(
        bridge: MockMouseEventBridge,
        configProvider: ControllerConfigurationProviding,
        scriptExecutor: ScriptExecuting,
        wheelPresenter: LeftThumbstickWheelPresenting,
        voiceInputController: VoiceInputControlling = MockVoiceInputController(),
        textInputInjector: TextInputInjecting = MockTextInputInjector(),
        voiceTranscriptCorrector: VoiceTranscriptCorrecting = MockVoiceTranscriptCorrector(),
        controllerActionHintPresenter: ControllerActionHintPresenting = MockControllerActionHintPresenter()
    ) -> ControllerManager {
        ControllerManager(
            mouseBridge: bridge,
            logger: Logger(subsystem: "PSControllerTests", category: "ControllerManagerTests"),
            configurationProvider: configProvider,
            scriptExecutor: scriptExecutor,
            leftThumbstickWheelPresenter: wheelPresenter,
            controllerActionHintPresenter: controllerActionHintPresenter,
            voiceInputController: voiceInputController,
            textInputInjector: textInputInjector,
            voiceTranscriptCorrector: voiceTranscriptCorrector
        )
    }

    private func makeWheelConfig() -> LeftThumbstickWheelConfiguration {
        LeftThumbstickWheelConfiguration(activationThreshold: 0.45, slots: makeWheelSlots())
    }

    private func makeWheelSlots() -> [ThumbstickWheelSlot] {
        (1...6).map { index in
            ThumbstickWheelSlot(
                title: "Slot \(index)",
                script: ScriptBinding(name: "wheel-slot-\(index)", command: "echo slot-\(index)")
            )
        }
    }
}

private struct MockConfigurationProvider: ControllerConfigurationProviding {
    let configuration: ControllerConfiguration

    func loadConfiguration() -> ControllerConfiguration {
        configuration
    }
}

private final class MockScriptExecutor: ScriptExecuting {
    struct Execution: Equatable {
        let binding: ScriptBinding
        let trigger: String
    }

    private(set) var executions: [Execution] = []

    func execute(binding: ScriptBinding, trigger: String) {
        executions.append(.init(binding: binding, trigger: trigger))
    }
}

private final class MockLeftThumbstickWheelPresenter: LeftThumbstickWheelPresenting {
    private(set) var showCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var hideCallCount = 0
    private(set) var lastSelectedIndex: Int?

    func show(slots: [ThumbstickWheelSlot], selectedIndex: Int) {
        showCallCount += 1
        lastSelectedIndex = selectedIndex
    }

    func updateSelection(selectedIndex: Int, slots: [ThumbstickWheelSlot]) {
        updateCallCount += 1
        lastSelectedIndex = selectedIndex
    }

    func hide() {
        hideCallCount += 1
    }
}

private final class MockVoiceInputController: VoiceInputControlling {
    var onTranscript: ((VoiceTranscriptEvent) -> Void)?

    private(set) var prepareCallCount = 0
    private(set) var startTriggers: [String] = []
    private(set) var startLocaleIdentifiers: [String] = []
    private(set) var stopTriggers: [String] = []
    private(set) var updatedConfigurations: [VoiceInputConfiguration?] = []

    func updateConfiguration(_ configuration: VoiceInputConfiguration?) {
        updatedConfigurations.append(configuration)
    }

    func prepare() {
        prepareCallCount += 1
    }

    func startCapture(trigger: String, localeIdentifier: String?) {
        startTriggers.append(trigger)
        startLocaleIdentifiers.append(localeIdentifier ?? "")
    }

    func stopCapture(trigger: String) {
        stopTriggers.append(trigger)
    }

    func emitTranscript(text: String, isFinal: Bool) {
        onTranscript?(.init(text: text, isFinal: isFinal))
    }
}

private final class MockTextInputInjector: TextInputInjecting {
    private(set) var insertedTexts: [String] = []

    @discardableResult
    func insertAtCursor(text: String) -> Bool {
        insertedTexts.append(text)
        return true
    }
}

private final class MockVoiceTranscriptCorrector: VoiceTranscriptCorrecting {
    var correctedText: String?
    private(set) var correctCalls: [String] = []

    func correct(_ text: String) -> String {
        correctCalls.append(text)
        return correctedText ?? text
    }
}

private final class MockControllerActionHintPresenter: ControllerActionHintPresenting {
    private(set) var showCallCount = 0
    private(set) var hideCallCount = 0
    private(set) var lastContent: String?

    func show(content: String) {
        showCallCount += 1
        lastContent = content
    }

    func hide() {
        hideCallCount += 1
    }
}

private final class MockMouseEventBridge: MouseEventBridging {
    private(set) var leftClickCount = 0
    private(set) var rightClickCount = 0
    private(set) var moveCount = 0
    private(set) var lastMoveX: Double = 0
    private(set) var lastMoveY: Double = 0
    private(set) var scrollCalls: [Int32] = []

    @discardableResult
    func requestAccessibilityIfNeeded(prompt: Bool) -> Bool {
        true
    }

    func moveCursor(normalizedX: Double, normalizedY: Double) {
        moveCount += 1
        lastMoveX = normalizedX
        lastMoveY = normalizedY
    }

    func leftClick() {
        leftClickCount += 1
    }

    func rightClick() {
        rightClickCount += 1
    }

    func scroll(lines: Int32) {
        scrollCalls.append(lines)
    }
}
