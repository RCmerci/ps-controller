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
- `mlx-qwen3-asr` HTTP server running (required for transcription)

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

Voice transcription is processed by a local `mlx-qwen3-asr` HTTP server (not CLI mode).

## Controller connection (USB only)

1. Connect your PlayStation controller to your Mac with a USB cable.
2. Keep the controller connected while using this app.

Bluetooth connection is intentionally not supported in this project because controller microphone behavior is not reliable in that mode.

## Configuration

Config resolution order at runtime:

1. `PS_CONTROLLER_CONFIG_PATH` (if set)
2. App bundle resource: `Contents/Resources/controller-config.json`
3. Current working directory: `./controller-config.json` (useful for `swift run`)
4. Fallback: `~/Library/Application Support/PSController/controller-config.json`

If no file is found in the selected location, the app writes a default config there.

### Button script mapping

Most PlayStation button events are configurable via `buttons`.
Each entry maps to a shell command executed by `/bin/zsh -lc`.

Supported button keys:

- `buttonA`, `buttonB`, `buttonX`, `buttonY`
- `dpadUp`, `dpadDown`, `dpadLeft`, `dpadRight`
- `leftShoulder`, `rightShoulder`
- `leftTrigger`, `rightTrigger`
- `leftThumbstickButton`, `rightThumbstickButton`
- `buttonMenu`, `buttonOptions`, `buttonHome`

Reserved runtime behaviors (not script-mapped):

- `buttonMenu`: hold to show an on-screen overlay listing all controller buttons and their current runtime function/script name; release to hide.
- `rightThumbstickButton`: always triggers one left click on press.
- When `voiceInput.enabled=true`: `buttonB` is reserved for voice capture.

### Voice input (press-and-hold)

You can enable controller-triggered voice transcription with `voiceInput`:

```json
{
  "voiceInput": {
    "enabled": true,
    "activationButton": "buttonOptions",
    "asrServer": {
      "baseURL": "http://127.0.0.1:8765",
      "apiKey": "ps-controller-mlx-qwen3-asr",
      "model": "Qwen/Qwen3-ASR-0.6B",
      "timeoutSeconds": 30,
      "autoStart": true,
      "launchExecutable": "mlx-qwen3-asr",
      "launchArguments": ["serve"]
    },
    "llmRefiner": {
      "enabled": true,
      "baseURL": "http://127.0.0.1:11434",
      "model": "gemma4:26b",
      "timeoutSeconds": 8
    }
  }
}
```

Runtime behavior:

1. Press and hold `buttonB` to start `zh-CN` voice capture.
2. Release `buttonB` to stop capture.
3. Captured audio is sent to `mlx-qwen3-asr` HTTP server via `POST /v1/audio/transcriptions`.
4. The ASR transcript is refined by local Ollama only when `llmRefiner.enabled` is `true`.
5. Final text is inserted into the currently focused text cursor.
6. Detailed voice/refiner state is emitted into app logs (`voice_input_*` / `voice_refiner_*`).

Notes:

- Voice input uses the **current macOS default input device**. For controller microphone usage, use a USB-connected controller and set it in `System Settings -> Sound -> Input`.
- Bluetooth controller microphone is not supported by this project.
- When `voiceInput.enabled` is `true`, `buttonB` is reserved for voice capture and its script mapping is skipped.
- `voiceInput.activationButton` is kept in config for backward compatibility but is currently ignored at runtime.
- `voiceInput.asrServer.baseURL` should point to your local `mlx-qwen3-asr` server root URL (for example `http://127.0.0.1:8765`).
- `voiceInput.asrServer.apiKey` must match the server Bearer token.
- Set `voiceInput.asrServer.autoStart=true` if you want app-managed server startup.
- When `autoStart=true`, the app uses a fixed API key: `ps-controller-mlx-qwen3-asr` for both server launch and client requests.
- `voiceInput.asrServer.launchExecutable` and `launchArguments` control how the app launches the server process.
- This project intentionally uses the `mlx-qwen3-asr` **HTTP server mode**, not per-request CLI transcription mode, to avoid model reload on every transcription.
- `llmRefiner.baseURL` should point to your local Ollama server root URL (the app calls `POST /api/chat`).
- On refinement failure or timeout, the app falls back to the original transcript automatically.
- Startup dependency issues (missing command/config/service) are shown in the menu bar dropdown under `Dependencies`.

If auto-start fails (missing executable/permission/invalid args), the issue is shown under menu bar `Dependencies` and you can fall back to manual startup.

Prepare local `mlx-qwen3-asr` server:

```bash
pip install "mlx-qwen3-asr[serve]"
mlx-qwen3-asr serve --api-key ps-controller-mlx-qwen3-asr
```

If you also enable `llmRefiner`, prepare local Ollama:

```bash
ollama pull gemma4:26b
ollama serve
```

### Left thumbstick wheel (6 slots)

`leftThumbstickWheel` config controls a GTA-style radial chooser:

- `activationThreshold`: how far the stick must move to open/select.
- `slots`: exactly 6 slots (`title` + optional `script`).
- Default config includes one `Cancel` slot (slot 6, no script).

Runtime behavior:

1. Move **left thumbstick** beyond threshold to show wheel.
2. Stick direction and highlighted slot are angle-aligned (top -> slot 1, then clockwise).
3. Return stick to center to confirm. If the slot has no script (for example `Cancel`), nothing is executed.

Mouse cursor movement is controlled by **right thumbstick**.

## Notes

- Single active controller at a time.
- Script execution logs include trigger, command, exit status, stdout/stderr, and errors.
