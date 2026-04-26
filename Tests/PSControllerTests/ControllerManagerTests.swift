import XCTest
import OSLog
import Foundation
@testable import PSController

final class ControllerManagerTests: XCTestCase {
    func testConfiguredButtonPressExecutesMappedScriptForButtonA() {
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

        XCTAssertEqual(executor.executions.count, 1)
        XCTAssertEqual(executor.executions[0].trigger, "button.buttonA")
        XCTAssertEqual(executor.executions[0].binding.name, "script-a")
    }

    func testTouchpadButtonPressTriggersLeftClickAndSkipsScript() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let config = ControllerConfiguration(
            buttons: [
                .touchpadButton: ScriptBinding(name: "should-not-run", command: "echo blocked")
            ],
            leftThumbstickWheel: makeWheelConfig()
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        sut.handleButtonInput(.touchpadButton, isPressed: true)
        sut.handleButtonInput(.touchpadButton, isPressed: false)

        XCTAssertEqual(bridge.leftClickCount, 1)
        XCTAssertEqual(executor.executions.count, 0)
    }

    func testDefaultConfigurationIncludesTouchpadButtonBinding() {
        XCTAssertEqual(ControllerConfiguration.default.buttons[.touchpadButton]?.name, "touchpadButton")
        XCTAssertEqual(ControllerConfiguration.default.buttons[.touchpadButton]?.command, "echo 'Configure script for touchpadButton'")
    }

    func testDependencyCheckIgnoresQuotedScriptFragments() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let config = ControllerConfiguration(
            buttons: [
                .leftTrigger: ScriptBinding(
                    name: "jxa-scroll",
                    command: "osascript -l JavaScript -e 'ObjC.import(\"ApplicationServices\"); var e = $.CGEventCreateScrollWheelEvent(null, $.kCGScrollEventUnitLine, 1, 3); $.CGEventPost($.kCGHIDEventTap, e);'"
                ),
                .dpadUp: ScriptBinding(
                    name: "front-app-check",
                    command: "__front_app=\"$(osascript -e 'tell application \\\"System Events\\\" to name of first process whose frontmost is true')\"; __run_status=$?; echo \"status=${__run_status}\""
                )
            ],
            leftThumbstickWheel: makeWheelConfig()
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        let done = expectation(description: "dependency_check_finished")

        sut.onDependencyIssuesChanged = { issues in
            let forbiddenIssues = [
                "Missing command in PATH: var",
                "Missing command in PATH: -e",
                "Missing command in PATH: __run_status=$?",
                "Missing command in PATH: $.CGEventPost($.kCGHIDEventTap,"
            ]

            for forbiddenIssue in forbiddenIssues {
                XCTAssertFalse(issues.contains(forbiddenIssue), "Unexpected false positive dependency issue: \(forbiddenIssue)")
            }

            done.fulfill()
        }

        sut.startMonitoring()

        wait(for: [done], timeout: 3.0)
    }

    func testDependencyCheckReportsMissingCommandForRealExecutable() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let missingCommand = "ps_controller_missing_command_9f3d2c"
        let config = ControllerConfiguration(
            buttons: [
                .buttonA: ScriptBinding(name: "missing-cmd", command: "\(missingCommand) --version")
            ],
            leftThumbstickWheel: makeWheelConfig()
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        let done = expectation(description: "dependency_check_reports_missing_command")

        sut.onDependencyIssuesChanged = { issues in
            XCTAssertTrue(
                issues.contains("Missing command in PATH: \(missingCommand)"),
                "Expected missing command issue for \(missingCommand), got: \(issues)"
            )
            done.fulfill()
        }

        sut.startMonitoring()

        wait(for: [done], timeout: 3.0)
    }

    func testTriggerHoldRepeatsScriptAndStopsAfterRelease() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let config = ControllerConfiguration(
            buttons: [
                .leftTrigger: ScriptBinding(name: "scroll-up", command: "echo up")
            ],
            leftThumbstickWheel: makeWheelConfig()
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            triggerRepeatInitialDelay: 0.02,
            triggerRepeatInterval: 0.02
        )

        let done = expectation(description: "repeat_stops_after_release")

        sut.handleButtonInput(.leftTrigger, isPressed: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            let countAtRelease = executor.executions.count
            sut.handleButtonInput(.leftTrigger, isPressed: false)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                XCTAssertGreaterThanOrEqual(countAtRelease, 2)
                XCTAssertEqual(executor.executions.count, countAtRelease)
                XCTAssertTrue(executor.executions.allSatisfy { $0.trigger == "button.leftTrigger" })
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 1.0)
    }

    func testNonTriggerButtonDoesNotAutoRepeatWhileHeld() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let config = ControllerConfiguration(
            buttons: [
                .buttonA: ScriptBinding(name: "script-a", command: "echo a")
            ],
            leftThumbstickWheel: makeWheelConfig()
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            triggerRepeatInitialDelay: 0.02,
            triggerRepeatInterval: 0.02
        )

        let done = expectation(description: "button_a_no_repeat")

        sut.handleButtonInput(.buttonA, isPressed: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            XCTAssertEqual(executor.executions.count, 1)
            XCTAssertEqual(executor.executions.first?.trigger, "button.buttonA")
            done.fulfill()
        }

        wait(for: [done], timeout: 1.0)
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
        XCTAssertEqual(decoded.rightThumbstickWheel.slots.count, 5)
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
        XCTAssertEqual(decoded.voiceInput?.asrServer.launchExecutable, "/Users/rcmerci/qwen3_asr_rs/asr-server")
        XCTAssertEqual(decoded.voiceInput?.asrServer.launchArguments, ["--model-dir", "/Users/rcmerci/qwen3_asr_rs/Qwen3-ASR-1.7B"])
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
              "launchExecutable": "/Users/rcmerci/qwen3_asr_rs/asr-server",
              "launchArguments": ["--model-dir", "/tmp/Qwen3-ASR-1.7B"]
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
        XCTAssertEqual(decoded.voiceInput?.asrServer.launchExecutable, "/Users/rcmerci/qwen3_asr_rs/asr-server")
        XCTAssertEqual(decoded.voiceInput?.asrServer.launchArguments, ["--model-dir", "/tmp/Qwen3-ASR-1.7B"])
    }

    func testControllerConfigurationDecodesTouchpadSensitivity() throws {
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
              { "title": "Cancel", "script": null }
            ]
          },
          "touchpad": {
            "pointerSensitivity": 2.4,
            "scrollSensitivity": 3.1
          }
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ControllerConfiguration.self, from: data)

        XCTAssertEqual(decoded.touchpad.pointerSensitivity, 2.4, accuracy: 0.001)
        XCTAssertEqual(decoded.touchpad.scrollSensitivity, 3.1, accuracy: 0.001)
    }

    func testTouchpadSensitivityNormalizationKeepsHighConfiguredValues() {
        let config = ControllerConfiguration(
            buttons: ControllerConfiguration.default.buttons,
            leftThumbstickWheel: ControllerConfiguration.default.leftThumbstickWheel,
            voiceInput: ControllerConfiguration.default.voiceInput,
            touchpad: TouchpadConfiguration(pointerSensitivity: 24, scrollSensitivity: 18)
        ).normalizedForRuntime()

        XCTAssertEqual(config.touchpad.pointerSensitivity, 24, accuracy: 0.001)
        XCTAssertEqual(config.touchpad.scrollSensitivity, 18, accuracy: 0.001)
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
                    model: "Qwen/Qwen3-ASR-1.7B",
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

    func testRightTriggerVoiceInputStartsAndStopsWithZhCNLocale() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let config = ControllerConfiguration(
            buttons: [
                .rightTrigger: ScriptBinding(name: "right-trigger-script", command: "echo r2")
            ],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .rightTrigger)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput
        )

        sut.handleButtonInput(.rightTrigger, isPressed: true)
        sut.handleButtonInput(.rightTrigger, isPressed: false)

        XCTAssertEqual(voiceInput.startTriggers, ["button.rightTrigger"])
        XCTAssertEqual(voiceInput.startLocaleIdentifiers, ["zh-CN"])
        XCTAssertEqual(voiceInput.stopTriggers, ["button.rightTrigger"])
        XCTAssertEqual(executor.executions.count, 0)
    }

    func testButtonBStillUsesCodexShortcutWhenActivationButtonIsButtonB() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let keyboard = MockKeyboardShortcutInjector()
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
            voiceInputController: voiceInput,
            keyboardShortcutInjector: keyboard
        )

        sut.handleButtonInput(.buttonB, isPressed: true)
        sut.handleButtonInput(.buttonB, isPressed: false)

        XCTAssertEqual(voiceInput.startTriggers, [])
        XCTAssertEqual(voiceInput.stopTriggers, [])
        XCTAssertEqual(
            keyboard.events,
            [
                .init(key: 59, modifiers: [], isKeyDown: true),
                .init(key: 6, modifiers: [.maskControl], isKeyDown: true),
                .init(key: 6, modifiers: [.maskControl], isKeyDown: false),
                .init(key: 59, modifiers: [], isKeyDown: false)
            ]
        )
        XCTAssertEqual(executor.executions.count, 0)
    }

    func testButtonBUsesCodexVoiceShortcutInsteadOfLocalVoiceInput() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let keyboard = MockKeyboardShortcutInjector()
        let config = ControllerConfiguration(
            buttons: [
                .buttonB: ScriptBinding(name: "button-b-script", command: "echo b")
            ],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .rightTrigger)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput,
            keyboardShortcutInjector: keyboard
        )

        sut.handleButtonInput(.buttonB, isPressed: true)
        sut.handleButtonInput(.buttonB, isPressed: false)

        XCTAssertEqual(voiceInput.startTriggers, [])
        XCTAssertEqual(voiceInput.startLocaleIdentifiers, [])
        XCTAssertEqual(voiceInput.stopTriggers, [])
        XCTAssertEqual(executor.executions.count, 0)
    }

    func testButtonBPressAndReleaseTriggerCtrlZShortcutDownAndUp() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let keyboard = MockKeyboardShortcutInjector()
        let config = ControllerConfiguration(
            buttons: [
                .buttonB: ScriptBinding(name: "button-b-script", command: "echo b")
            ],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .rightTrigger)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput,
            keyboardShortcutInjector: keyboard
        )

        sut.handleButtonInput(.buttonB, isPressed: true)
        sut.handleButtonInput(.buttonB, isPressed: false)

        XCTAssertEqual(
            keyboard.events,
            [
                .init(key: 59, modifiers: [], isKeyDown: true),
                .init(key: 6, modifiers: [.maskControl], isKeyDown: true),
                .init(key: 6, modifiers: [.maskControl], isKeyDown: false),
                .init(key: 59, modifiers: [], isKeyDown: false)
            ]
        )
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
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .rightTrigger)
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

    func testButtonBUsesCodexShortcutEvenWhenVoiceInputDisabled() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let keyboard = MockKeyboardShortcutInjector()
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
            voiceInputController: voiceInput,
            keyboardShortcutInjector: keyboard
        )

        sut.handleButtonInput(.buttonB, isPressed: true)
        sut.handleButtonInput(.buttonB, isPressed: false)

        XCTAssertEqual(voiceInput.startTriggers.count, 0)
        XCTAssertEqual(voiceInput.stopTriggers.count, 0)
        XCTAssertEqual(executor.executions.count, 0)
        XCTAssertEqual(
            keyboard.events,
            [
                .init(key: 59, modifiers: [], isKeyDown: true),
                .init(key: 6, modifiers: [.maskControl], isKeyDown: true),
                .init(key: 6, modifiers: [.maskControl], isKeyDown: false),
                .init(key: 59, modifiers: [], isKeyDown: false)
            ]
        )
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
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .rightTrigger)
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

        XCTAssertTrue(content.contains("rightTrigger -> Voice Input (zh-CN)"))
        XCTAssertTrue(content.contains("buttonB -> Codex Voice Input (Ctrl+Z hold)"))
        XCTAssertTrue(content.contains("buttonX -> Default Key"))
        XCTAssertTrue(content.contains("touchpadButton -> Left Click"))
        XCTAssertTrue(content.contains("rightThumbstickButton -> Default Key"))
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

    func testFinalVoiceTranscriptTranslatesToEnglishBeforeInsertion() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let textInjector = MockTextInputInjector()
        let translator = MockVoiceTextTranslator()
        translator.translatedText = "Hello world"

        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .rightTrigger)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput,
            textInputInjector: textInjector,
            voiceTextTranslator: translator
        )

        _ = sut
        voiceInput.emitTranscript(text: "你好世界", isFinal: true, trigger: "button.rightTrigger")

        XCTAssertEqual(translator.inputs, ["你好世界"])
        XCTAssertEqual(textInjector.insertedTexts, ["Hello world"])
    }

    func testButtonBTriggeredTranscriptStillTranslatesToEnglish() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let textInjector = MockTextInputInjector()
        let translator = MockVoiceTextTranslator()
        translator.translatedText = "Hello world"

        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .rightTrigger)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput,
            textInputInjector: textInjector,
            voiceTextTranslator: translator
        )

        _ = sut
        voiceInput.emitTranscript(text: "你好世界", isFinal: true, trigger: "button.buttonB")

        XCTAssertEqual(translator.inputs, ["你好世界"])
        XCTAssertEqual(textInjector.insertedTexts, ["Hello world"])
    }

    func testVoiceTranslationFailureFallsBackToCorrectedTranscriptInsertion() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let textInjector = MockTextInputInjector()
        let translator = MockVoiceTextTranslator()
        translator.translationError = NSError(domain: "test", code: -1)
        let corrector = MockVoiceTranscriptCorrector()
        corrector.correctedText = "open Emacs"

        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig(),
            voiceInput: VoiceInputConfiguration(enabled: true, activationButton: .rightTrigger)
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: MockLeftThumbstickWheelPresenter(),
            voiceInputController: voiceInput,
            textInputInjector: textInjector,
            voiceTranscriptCorrector: corrector,
            voiceTextTranslator: translator
        )

        _ = sut
        voiceInput.emitTranscript(text: "open IMAX", isFinal: true, trigger: "button.rightTrigger")

        XCTAssertEqual(corrector.correctCalls, ["open IMAX"])
        XCTAssertEqual(translator.inputs, ["open Emacs"])
        XCTAssertEqual(textInjector.insertedTexts, ["open Emacs"])
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

    func testPausedControlBlocksButtonBCodexVoiceShortcut() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let voiceInput = MockVoiceInputController()
        let keyboard = MockKeyboardShortcutInjector()
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
            voiceInputController: voiceInput,
            keyboardShortcutInjector: keyboard
        )

        sut.setControlEnabled(false)
        sut.handleButtonInput(.buttonB, isPressed: true)
        sut.handleButtonInput(.buttonB, isPressed: false)

        XCTAssertEqual(voiceInput.startTriggers.count, 0)
        XCTAssertEqual(voiceInput.stopTriggers, ["control_paused"])
        XCTAssertEqual(executor.executions.count, 0)
        XCTAssertEqual(keyboard.events, [])
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

    func testRightThumbstickButtonPressExecutesMappedScript() {
        let bridge = MockMouseEventBridge()
        let executor = MockScriptExecutor()
        let config = ControllerConfiguration(
            buttons: [.rightThumbstickButton: ScriptBinding(name: "right-stick-script", command: "echo run")],
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

        XCTAssertEqual(bridge.leftClickCount, 0)
        XCTAssertEqual(executor.executions.count, 1)
        XCTAssertEqual(executor.executions[0].trigger, "button.rightThumbstickButton")
        XCTAssertEqual(executor.executions[0].binding.name, "right-stick-script")
    }

    func testTouchpadDeadzonePreventsSmallValuesAndAppliesSensitivityCurve() {
        let bridge = MockMouseEventBridge()
        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        sut.processInput(
            leftX: 0,
            leftY: 0,
            touchpadX: 0.11,
            touchpadY: -0.1,
            leftTrigger: 0,
            rightTrigger: 0
        )
        XCTAssertEqual(bridge.moveCount, 0)

        sut.processInput(
            leftX: 0,
            leftY: 0,
            touchpadX: 0.2,
            touchpadY: -0.5,
            leftTrigger: 0,
            rightTrigger: 0
        )

        XCTAssertEqual(bridge.moveCount, 1)
        XCTAssertLessThan(abs(bridge.lastMoveX), 0.2)
        XCTAssertLessThan(abs(bridge.lastMoveY), 0.5)
        XCTAssertGreaterThan(abs(bridge.lastMoveY), 0.01)
    }

    func testHigherTouchpadPointerSensitivityProducesLargerCursorDelta() {
        let defaultBridge = MockMouseEventBridge()
        let highBridge = MockMouseEventBridge()

        let defaultSUT = makeSUT(
            bridge: defaultBridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        let highSensitivityConfig = ControllerConfiguration(
            buttons: ControllerConfiguration.default.buttons,
            leftThumbstickWheel: ControllerConfiguration.default.leftThumbstickWheel,
            voiceInput: ControllerConfiguration.default.voiceInput,
            touchpad: TouchpadConfiguration(pointerSensitivity: 2.6, scrollSensitivity: 1.0)
        ).normalizedForRuntime()

        let highSensitivitySUT = makeSUT(
            bridge: highBridge,
            configProvider: MockConfigurationProvider(configuration: highSensitivityConfig),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        defaultSUT.processInput(leftX: 0, leftY: 0, touchpadX: 0.1, touchpadY: 0.1, leftTrigger: 0, rightTrigger: 0)
        defaultSUT.processInput(leftX: 0, leftY: 0, touchpadX: 0.4, touchpadY: 0.1, leftTrigger: 0, rightTrigger: 0)

        highSensitivitySUT.processInput(leftX: 0, leftY: 0, touchpadX: 0.1, touchpadY: 0.1, leftTrigger: 0, rightTrigger: 0)
        highSensitivitySUT.processInput(leftX: 0, leftY: 0, touchpadX: 0.4, touchpadY: 0.1, leftTrigger: 0, rightTrigger: 0)

        XCTAssertEqual(defaultBridge.moveCount, 1)
        XCTAssertEqual(highBridge.moveCount, 1)
        XCTAssertGreaterThan(abs(highBridge.lastMoveX), abs(defaultBridge.lastMoveX))
    }

    func testTouchpadInitialContactUsesTouchPointAsCenterForMovement() {
        let bridge = MockMouseEventBridge()
        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        sut.processInput(
            leftX: 0,
            leftY: 0,
            touchpadX: 0.0,
            touchpadY: 0.8,
            leftTrigger: 0,
            rightTrigger: 0
        )

        XCTAssertEqual(bridge.moveCount, 0)

        sut.processInput(
            leftX: 0,
            leftY: 0,
            touchpadX: 0.0,
            touchpadY: 0.5,
            leftTrigger: 0,
            rightTrigger: 0
        )

        XCTAssertEqual(bridge.moveCount, 1)
        XCTAssertLessThan(bridge.lastMoveY, 0)
    }

    func testRightThumbstickDoesNotMoveCursorAnymore() {
        let bridge = MockMouseEventBridge()
        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        sut.processInput(
            leftX: 0,
            leftY: 0,
            leftTrigger: 0,
            rightTrigger: 0,
            rightThumbstickX: 0.6,
            rightThumbstickY: -0.6
        )

        XCTAssertEqual(bridge.moveCount, 0)
    }

    func testTwoFingerTouchpadScrollsOnlyWhenFingersMove() {
        let bridge = MockMouseEventBridge()
        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        // First contact only establishes anchor.
        sut.processInput(
            leftX: 0,
            leftY: 0,
            rightX: 0.4,
            rightY: 0.8,
            touchpadX: 0.3,
            touchpadY: 0.5,
            leftTrigger: 0,
            rightTrigger: 0
        )

        XCTAssertEqual(bridge.moveCount, 0)
        XCTAssertTrue(bridge.scrollCalls.isEmpty)

        // Fingers move, so scrolling should happen.
        sut.processInput(
            leftX: 0,
            leftY: 0,
            rightX: 0.4,
            rightY: -0.8,
            touchpadX: 0.3,
            touchpadY: -0.8,
            leftTrigger: 0,
            rightTrigger: 0
        )

        XCTAssertEqual(bridge.moveCount, 0)
        XCTAssertFalse(bridge.scrollCalls.isEmpty)
        let scrollCountAfterMove = bridge.scrollCalls.count

        // Fingers stop, scrolling should stop.
        sut.processInput(
            leftX: 0,
            leftY: 0,
            rightX: 0.4,
            rightY: -0.8,
            touchpadX: 0.3,
            touchpadY: -0.8,
            leftTrigger: 0,
            rightTrigger: 0
        )

        XCTAssertEqual(bridge.scrollCalls.count, scrollCountAfterMove)
    }

    func testTouchpadLiftSuppressesImmediateSpikeValues() {
        let bridge = MockMouseEventBridge()
        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: .default),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: MockLeftThumbstickWheelPresenter()
        )

        // First contact only establishes anchor.
        sut.processInput(
            leftX: 0,
            leftY: 0,
            touchpadX: 0.5,
            touchpadY: 0.0,
            leftTrigger: 0,
            rightTrigger: 0
        )

        // Movement frame produces cursor move.
        sut.processInput(
            leftX: 0,
            leftY: 0,
            touchpadX: 0.8,
            touchpadY: 0.0,
            leftTrigger: 0,
            rightTrigger: 0
        )
        XCTAssertEqual(bridge.moveCount, 1)

        sut.processInput(
            leftX: 0,
            leftY: 0,
            touchpadX: 0.0,
            touchpadY: 0.0,
            leftTrigger: 0,
            rightTrigger: 0
        )

        sut.processInput(
            leftX: 0,
            leftY: 0,
            touchpadX: 0.98,
            touchpadY: 0.0,
            leftTrigger: 0,
            rightTrigger: 0
        )

        XCTAssertEqual(bridge.moveCount, 1)
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
        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 1)
    }

    func testRightThumbstickWheelShowsThenExecutesSelectedSlotOnRelease() {
        let bridge = MockMouseEventBridge()
        let leftWheelPresenter = MockLeftThumbstickWheelPresenter()
        let rightWheelPresenter = MockLeftThumbstickWheelPresenter()
        let executor = MockScriptExecutor()

        let rightWheelConfig = RightThumbstickWheelConfiguration(activationThreshold: 0.45, slots: makeWheelSlots())
        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig(),
            rightThumbstickWheel: rightWheelConfig
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: executor,
            wheelPresenter: leftWheelPresenter,
            rightWheelPresenter: rightWheelPresenter
        )

        sut.processInput(
            leftX: 0.0,
            leftY: 0.0,
            leftTrigger: 0,
            rightTrigger: 0,
            rightThumbstickX: 0.0,
            rightThumbstickY: 1.0
        )

        XCTAssertEqual(rightWheelPresenter.showCallCount, 1)
        XCTAssertEqual(rightWheelPresenter.lastSelectedIndex, 0)
        XCTAssertEqual(executor.executions.count, 0)

        sut.processInput(
            leftX: 0.0,
            leftY: 0.0,
            leftTrigger: 0,
            rightTrigger: 0,
            rightThumbstickX: 0.0,
            rightThumbstickY: 0.0
        )

        XCTAssertEqual(rightWheelPresenter.hideCallCount, 1)
        XCTAssertEqual(executor.executions.count, 1)
        XCTAssertEqual(executor.executions[0].trigger, "rightThumbstick.slot1")
        XCTAssertEqual(executor.executions[0].binding.name, "wheel-slot-1")
        XCTAssertEqual(leftWheelPresenter.showCallCount, 0)
    }

    func testRightThumbstickWheelDirectionAlignmentMatchesSlotIndices() {
        let bridge = MockMouseEventBridge()
        let leftWheelPresenter = MockLeftThumbstickWheelPresenter()
        let rightWheelPresenter = MockLeftThumbstickWheelPresenter()

        let rightWheelConfig = RightThumbstickWheelConfiguration(activationThreshold: 0.45, slots: makeWheelSlots())
        let config = ControllerConfiguration(
            buttons: [:],
            leftThumbstickWheel: makeWheelConfig(),
            rightThumbstickWheel: rightWheelConfig
        ).normalizedForRuntime()

        let sut = makeSUT(
            bridge: bridge,
            configProvider: MockConfigurationProvider(configuration: config),
            scriptExecutor: MockScriptExecutor(),
            wheelPresenter: leftWheelPresenter,
            rightWheelPresenter: rightWheelPresenter
        )

        sut.processInput(leftX: 0.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0, rightThumbstickX: 0.0, rightThumbstickY: 1.0)
        XCTAssertEqual(rightWheelPresenter.lastSelectedIndex, 0)

        sut.processInput(leftX: 0.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0, rightThumbstickX: 1.0, rightThumbstickY: 0.0)
        XCTAssertEqual(rightWheelPresenter.lastSelectedIndex, 1)

        sut.processInput(leftX: 0.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0, rightThumbstickX: 0.0, rightThumbstickY: -1.0)
        XCTAssertEqual(rightWheelPresenter.lastSelectedIndex, 3)

        sut.processInput(leftX: 0.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0, rightThumbstickX: -1.0, rightThumbstickY: 0.0)
        XCTAssertEqual(rightWheelPresenter.lastSelectedIndex, 4)
        XCTAssertEqual(leftWheelPresenter.showCallCount, 0)
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
        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 1)

        sut.processInput(leftX: 0.0, leftY: -1.0, leftTrigger: 0, rightTrigger: 0)
        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 3)

        sut.processInput(leftX: -1.0, leftY: 0.0, leftTrigger: 0, rightTrigger: 0)
        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 4)
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
        let leftSlots = ControllerConfiguration.default.leftThumbstickWheel.slots
        XCTAssertEqual(leftSlots.count, 5)
        XCTAssertEqual(leftSlots[4].title, "Cancel")
        XCTAssertNil(leftSlots[4].script)

        let rightSlots = ControllerConfiguration.default.rightThumbstickWheel.slots
        XCTAssertEqual(rightSlots.count, 5)
        XCTAssertEqual(rightSlots[4].title, "Cancel")
        XCTAssertNil(rightSlots[4].script)
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

        XCTAssertEqual(wheelPresenter.lastSelectedIndex, 4)
        XCTAssertEqual(executor.executions.count, 0)
    }

    private func makeSUT(
        bridge: MockMouseEventBridge,
        configProvider: ControllerConfigurationProviding,
        scriptExecutor: ScriptExecuting,
        wheelPresenter: LeftThumbstickWheelPresenting,
        rightWheelPresenter: LeftThumbstickWheelPresenting? = nil,
        voiceInputController: VoiceInputControlling = MockVoiceInputController(),
        textInputInjector: TextInputInjecting = MockTextInputInjector(),
        keyboardShortcutInjector: KeyboardShortcutInjecting = MockKeyboardShortcutInjector(),
        voiceTranscriptCorrector: VoiceTranscriptCorrecting = MockVoiceTranscriptCorrector(),
        voiceTextTranslator: VoiceTextTranslating = MockVoiceTextTranslator(),
        controllerActionHintPresenter: ControllerActionHintPresenting = MockControllerActionHintPresenter(),
        triggerRepeatInitialDelay: TimeInterval = 0.25,
        triggerRepeatInterval: TimeInterval = 0.08
    ) -> ControllerManager {
        ControllerManager(
            mouseBridge: bridge,
            logger: Logger(subsystem: "PSControllerTests", category: "ControllerManagerTests"),
            configurationProvider: configProvider,
            scriptExecutor: scriptExecutor,
            leftThumbstickWheelPresenter: wheelPresenter,
            rightThumbstickWheelPresenter: rightWheelPresenter ?? MockLeftThumbstickWheelPresenter(),
            controllerActionHintPresenter: controllerActionHintPresenter,
            voiceInputController: voiceInputController,
            textInputInjector: textInputInjector,
            keyboardShortcutInjector: keyboardShortcutInjector,
            voiceTranscriptCorrector: voiceTranscriptCorrector,
            voiceTextTranslator: voiceTextTranslator,
            triggerRepeatInitialDelay: triggerRepeatInitialDelay,
            triggerRepeatInterval: triggerRepeatInterval
        )
    }

    private func makeWheelConfig() -> LeftThumbstickWheelConfiguration {
        LeftThumbstickWheelConfiguration(activationThreshold: 0.45, slots: makeWheelSlots())
    }

    private func makeWheelSlots() -> [ThumbstickWheelSlot] {
        [
            ThumbstickWheelSlot(
                title: "Slot 1",
                script: ScriptBinding(name: "wheel-slot-1", command: "echo slot-1")
            ),
            ThumbstickWheelSlot(
                title: "Slot 2",
                script: ScriptBinding(name: "wheel-slot-2", command: "echo slot-2")
            ),
            ThumbstickWheelSlot(
                title: "Slot 3",
                script: ScriptBinding(name: "wheel-slot-3", command: "echo slot-3")
            ),
            ThumbstickWheelSlot(
                title: "Slot 4",
                script: ScriptBinding(name: "wheel-slot-4", command: "echo slot-4")
            ),
            ThumbstickWheelSlot(title: "Cancel", script: nil)
        ]
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

    func emitTranscript(text: String, isFinal: Bool, trigger: String? = nil) {
        onTranscript?(.init(text: text, isFinal: isFinal, trigger: trigger))
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

private final class MockKeyboardShortcutInjector: KeyboardShortcutInjecting {
    struct Event: Equatable {
        let key: CGKeyCode
        let modifiers: CGEventFlags
        let isKeyDown: Bool
    }

    private(set) var events: [Event] = []

    @discardableResult
    func postKeyEvent(keyCode: CGKeyCode, modifiers: CGEventFlags, isKeyDown: Bool) -> Bool {
        events.append(.init(key: keyCode, modifiers: modifiers, isKeyDown: isKeyDown))
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

private final class MockVoiceTextTranslator: VoiceTextTranslating {
    var translatedText: String?
    var translationError: Error?
    private(set) var inputs: [String] = []

    func translateToEnglish(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        inputs.append(text)

        if let translationError {
            completion(.failure(translationError))
            return
        }

        completion(.success(translatedText ?? text))
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
