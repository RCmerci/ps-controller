# PSController

Use a PlayStation controller to control macOS cursor actions.

## MVP Features

- Detect PlayStation controller connection/disconnection.
- Menu bar app with:
  - Connection status
  - Pause/Resume control
  - Quit

## Requirements

- macOS 13+
- Swift 5.9+
- USB connection for the controller (Bluetooth is intentionally not supported)
- Accessibility permission (required for event injection)
- Microphone permission (required for voice capture)
- `qwen3-asr-rs` `asr-server` running (required for transcription)

## Build

```bash
swift build
```

## Run

```bash
swift run PSController
```

After first run, macOS will ask for Accessibility permission.
Grant permission for the running binary/terminal in:

`System Settings -> Privacy & Security -> Accessibility`

If `voiceInput.enabled` is on, also grant:

- `System Settings -> Privacy & Security -> Microphone`

Then restart the app.

Voice transcription is processed by a local `qwen3-asr-rs` `asr-server` over its OpenAI-compatible HTTP API.

## Controller connection (USB only)

1. Connect your PlayStation controller to your Mac with a USB cable.
2. Keep the controller connected while using this app.

Bluetooth connection is intentionally not supported in this project because controller microphone behavior is not reliable in that mode.

## Configuration

Config resolution order at runtime:

1. `PS_CONTROLLER_CONFIG_PATH` (if set)
2. Current working directory: `./controller-config.json` (useful for `swift run`)
3. App bundle resource: `Contents/Resources/controller-config.json`

If no file is found in the selected location, the app writes a default config to the current working directory path.

### Button script mapping

Most PlayStation button events are configurable via `buttons`.
Each entry maps to a shell command executed by `/bin/zsh -lc`.

Supported button keys:

- `buttonA`, `buttonB`, `buttonX`, `buttonY`
- `dpadUp`, `dpadDown`, `dpadLeft`, `dpadRight`
- `leftShoulder`, `rightShoulder`
- `leftTrigger`, `rightTrigger`
- `leftThumbstickButton`, `rightThumbstickButton`
- `touchpadButton` (PlayStation touchpad click)
- `buttonMenu`, `buttonOptions`, `buttonHome`

Reserved runtime behaviors (not script-mapped):

- `buttonMenu`: hold to show an on-screen overlay listing all controller buttons and their current runtime function/script name; release to hide.
- `touchpadButton`: always triggers one left click on press.
- `buttonB`: built-in Codex voice input shortcut; press-and-hold sends `Ctrl+Z` key down, release sends `Ctrl+Z` key up.
- When `voiceInput.enabled=true`: `voiceInput.activationButton` is reserved for local voice capture.

### Touchpad pointer behavior

- **Single-finger touch** on the touchpad controls cursor movement.
- **Two-finger touch** on the touchpad switches to scroll mode.
- Cursor movement uses a **deadzone with hysteresis** to reduce drift (`enter` > `exit`).
- Cursor movement also uses a **non-linear sensitivity curve** (instead of raw linear scaling).
- Touch and click are separated: moving a finger on the touchpad does not click; only `touchpadButton` press triggers left click.
- After lift-off, a short **spike suppression window** ignores abrupt values to avoid jumpy cursor behavior.
- You can tune touchpad sensitivity in config:
  - `touchpad.pointerSensitivity` (single-finger cursor movement multiplier)
  - `touchpad.scrollSensitivity` (two-finger scroll multiplier)

Example:

```json
{
  "touchpad": {
    "pointerSensitivity": 2.4,
    "scrollSensitivity": 3.0
  }
}
```

### Voice input (press-and-hold)

You can enable controller-triggered voice transcription with `voiceInput`:

```json
{
  "voiceInput": {
    "enabled": true,
    "activationButton": "rightTrigger",
    "asrServer": {
      "baseURL": "http://127.0.0.1:8765",
      "apiKey": "",
      "model": "Qwen/Qwen3-ASR-1.7B",
      "timeoutSeconds": 30,
      "autoStart": true,
      "launchExecutable": "/Users/rcmerci/qwen3_asr_rs/asr-server",
      "launchArguments": ["--model-dir", "/Users/rcmerci/qwen3_asr_rs/Qwen3-ASR-1.7B"]
    }
  }
}
```

Runtime behavior:

1. Press and hold `rightTrigger` (or your configured `voiceInput.activationButton`) to start `zh-CN` voice capture.
2. Release the configured voice button to stop capture.
3. Captured audio is sent to `qwen3-asr-rs` server via `POST /v1/audio/transcriptions` (OpenAI-compatible API).
4. The ASR transcript is corrected with a local replacement dictionary.
5. Corrected text is translated to English through local Ollama API (`POST /api/generate`, model: `gemma4:e4b`) and then inserted.
6. Detailed voice/dictionary/translation state is emitted into app logs (`voice_input_*` / `voice_dictionary_*` / `voice_translation_*`).

Separately, `buttonB` is always reserved for Codex voice input integration:

1. Press and hold `buttonB` to send `Ctrl+Z` key down.
2. Release `buttonB` to send `Ctrl+Z` key up.
3. PSController does not perform ASR/transcription for `buttonB`; CodexApp handles the voice input session.

### Voice replacement dictionary (`voice-word-replacements.json`)

Dictionary file format is a JSON map:

- key: the **correct** word/phrase
- value: a list of **possible incorrect** words/phrases

Example:

```json
{
  "Emacs": ["IMAX", "E max", "emax"],
  "Clojure": ["Closer", "Cello"],
  "JSON": ["jason", "杰森"],
  "Logseq": ["log seek", "log six", "Log萨克"]
}
```

Runtime dictionary resolution order:

1. `PS_CONTROLLER_WORD_REPLACEMENTS_PATH` (if set)
2. App bundle resource: `Contents/Resources/voice-word-replacements.json`
3. Current working directory: `./voice-word-replacements.json`
4. Built-in fallback dictionary (if no external file is found)

Notes:

- Voice input uses the **current macOS default input device**. For controller microphone usage, use a USB-connected controller and set it in `System Settings -> Sound -> Input`.
- Bluetooth controller microphone is not supported by this project.
- `buttonB` is always reserved for the built-in Codex voice input shortcut (`Ctrl+Z` hold) and its script mapping is skipped.
- When `voiceInput.enabled` is `true`, `voiceInput.activationButton` is reserved for local voice capture and its script mapping is skipped.
- Voice capture locale is currently fixed to `zh-CN`; adjust source code if you need another locale.
- `voiceInput.asrServer.baseURL` should point to your local `qwen3-asr-rs` server root URL (for example `http://127.0.0.1:8765`).
- `voiceInput.asrServer.apiKey` is optional for local `qwen3-asr-rs`; leave empty unless your proxy/service requires Bearer auth.
- Set `voiceInput.asrServer.autoStart=true` if you want app-managed server startup.
- `voiceInput.asrServer.launchExecutable` and `launchArguments` control how the app launches the server process.
- English translation (used for `voiceInput.activationButton` path, e.g. `rightTrigger`) requires local Ollama server at `http://127.0.0.1:11434`, using model `gemma4:e4b`.
- For `qwen3-asr-rs`, `--model-dir` is required in `launchArguments`.
- This project intentionally uses an OpenAI-compatible **HTTP server mode** (`POST /v1/audio/transcriptions`), not per-request CLI transcription mode, to avoid model reload on every transcription.
- Startup dependency issues (missing command/config/service) are shown in the menu bar dropdown under `Dependencies`.

If auto-start fails (missing executable/permission/invalid args), the issue is shown under menu bar `Dependencies` and you can fall back to manual startup.

Prepare local `qwen3-asr-rs` server:

```bash
"/Users/rcmerci/qwen3_asr_rs/asr-server" \
  --model-dir "/Users/rcmerci/qwen3_asr_rs/Qwen3-ASR-1.7B" \
  --host 127.0.0.1 \
  --port 8765
```

### Thumbstick wheels (left/right, 5 slots each)

Both `leftThumbstickWheel` and `rightThumbstickWheel` support a GTA-style radial chooser:

- `activationThreshold`: how far the stick must move to open/select.
- `slots`: exactly 5 slots (`title` + optional `script`).
- Default config includes one `Cancel` slot (slot 5, no script).

Runtime behavior (same for both sticks):

1. Move the thumbstick beyond threshold to show wheel.
2. Stick direction and highlighted slot are angle-aligned (top -> slot 1, then clockwise).
3. Return stick to center to confirm. If the slot has no script (for example `Cancel`), nothing is executed.

Each slot can execute an independent shell script by setting `slots[n].script` in `controller-config.json`.

Mouse cursor movement is controlled by the **touchpad primary finger**.
Two-finger touchpad gesture performs wheel scrolling.
Right thumbstick movement no longer controls the mouse cursor directly; it now controls `rightThumbstickWheel`.

## Notes

- Single active controller at a time.
- Script execution logs include trigger, command, exit status, stdout/stderr, and errors.
