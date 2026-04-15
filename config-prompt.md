## Controller behavior snapshot

Synced from `controller-config.json`.

## Buttons

| Button | Config name | Effective behavior |
| --- | --- | --- |
| `buttonA` | `buttonA` | Press `Enter` in the currently focused app/input. |
| `buttonB` | `Press Right Command Twice` | **Reserved by voice input** (`voiceInput.activationButton = buttonB`). Press-and-hold starts voice capture, release stops capture. The button script is not executed while voice input is enabled. |
| `buttonX` | `buttonX` | Run placeholder script: `echo 'Configure script for buttonX'`. |
| `buttonY` | `buttonY` | Delete all content in the currently focused text input. |
| `dpadUp` | `dpadUp` | Run placeholder script: `echo 'Configure script for dpadUp'`. |
| `dpadDown` | `dpadDown` | Run placeholder script: `echo 'Configure script for dpadDown'`. |
| `dpadLeft` | `dpadLeft` | Run placeholder script: `echo 'Configure script for dpadLeft'`. |
| `dpadRight` | `dpadRight` | Run placeholder script: `echo 'Configure script for dpadRight'`. |
| `leftShoulder` | `leftShoulder` | Run placeholder script: `echo 'Configure script for leftShoulder'`. |
| `rightShoulder` | `rightShoulder` | Press `Ctrl-Enter` in the currently focused app/input. |
| `leftTrigger` | `leftTrigger` | Run placeholder script: `echo 'Configure script for leftTrigger'`. |
| `rightTrigger` | `rightTrigger` | Run placeholder script: `echo 'Configure script for rightTrigger'`. |
| `leftThumbstickButton` | `leftThumbstickButton` | Run placeholder script: `echo 'Configure script for leftThumbstickButton'`. |
| `rightThumbstickButton` | `rightThumbstickButton` | Run placeholder script: `echo 'Configure script for rightThumbstickButton'`. |
| `buttonMenu` | `buttonMenu` | Run placeholder script: `echo 'Configure script for buttonMenu'`. |
| `buttonOptions` | `buttonOptions` | Run placeholder script: `echo 'Configure script for buttonOptions'`. |
| `buttonHome` | `buttonHome` | Run placeholder script: `echo 'Configure script for buttonHome'`. |

## Voice input

- `enabled`: `true`
- `activationButton`: `buttonB`
- Recognition default locale: `zh-Hans`
- Partial transcript (`final=false`): log only, no cursor insertion.
- Final transcript (`final=true`): insert text at current cursor position.
- On manual stop (button release), if no final result is returned by the recognizer, the latest partial transcript is emitted as a final fallback.

## leftThumbstickWheel

- `activationThreshold`: `0.45`
- Total slots: `6`

### Slot 1 — `Emacs eca-chat-mode`

- Activate Emacs.
- Search all buffers for `major-mode` equal to `eca-chat` or `eca-chat-mode`.
- Switch to the first matched buffer.

### Slot 2 — `Chrome test.logseq.com`

- Activate Google Chrome.
- Search existing tabs for URL containing `test.logseq.com`.
- Focus the matched tab and bring its window to front.

### Slot 3 — `Slot 3`

- No script configured.
- Selection confirms but executes nothing.

### Slot 4 — `Slot 4`

- No script configured.
- Selection confirms but executes nothing.

### Slot 5 — `Slot 5`

- No script configured.
- Selection confirms but executes nothing.

### Slot 6 — `Cancel`

- No script configured.
- Cancels wheel action.
