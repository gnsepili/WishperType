# Setup and Usage

1. Create an OpenAI API project/key with billing and access to the models you select. A ChatGPT subscription does not include API usage. See [API pricing](https://openai.com/api/pricing/) and set project usage limits appropriate to your account.
2. Enter the key in the app's Settings. The integration stores it in the macOS login Keychain, service `com.whispertype.mac`, account `api-key`, not in settings JSON. Do not put keys in source files or custom instructions.
3. Grant Microphone permission for capture. Grant Accessibility for guarded text insertion and global shortcuts, and Input Monitoring for observing the configured shortcut keycodes. Use the app's permission controls/System Settings; the build and tests do not grant permissions for you.
4. Start with a short, non-sensitive sentence in TextEdit and Accurate mode. Review the returned text before trying important documents. If focus or the field changed during processing, automatic insertion may be refused; use explicit copy/paste instead.
5. Try Live mode only after file transcription works. Realtime model availability, quotas, and protocol support depend on your API account. An unsuccessful live session can fall back to REST transcription of the recorded file, increasing latency and potentially incurring both sessions' usage charges.

Defaults from `AppSettings`:

| Setting | Default |
| --- | --- |
| REST transcription | `gpt-4o-transcribe` |
| Realtime transcription | `gpt-live-transcribe` |
| Text rewrite | `gpt-4.1-mini` |
| Processing | Accurate: record, then process |
| Cleanup/style | Light / natural |
| Surrounding app context sharing | Off |
| Local history | On, 30 days |
| Saved audio | Off |
| Clipboard restoration | On |
| Maximum recording duration | 1,200 seconds (20 minutes) |

REST mode uploads the completed recording; it is not incremental live transcription. Live mode streams microphone PCM and displays interim text when the selected model emits it; `gpt-live-transcribe` supports pre-commit deltas, while older transcription models can wait until Stop. Separately, "While a result is processing" selects "Queue new recordings" or "Wait before recording again." The serial asynchronous job queue allows processing without blocking the UI; waiting is the simpler synchronous user experience, not a synchronous network call on the main thread. Model names are configurable and are not guarantees of account access or output quality.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Hold to dictate | Control + Option by default; Right Option or Fn/Globe presets |
| Toggle dictation | Control + Option + Space |
| Hold spoken command on selected text | Control + Option + Command |
| Transform selected text | Control + Option + P |
| Copy last result | Control + Command + C |
| Paste last result | Control + Command + V |
| Cancel an active operation | Escape |

Modifier-only shortcuts can conflict with macOS, VoiceOver, input methods, and other tools. Fn/Globe behavior depends on keyboard/system settings. Secure fields, some custom controls, remote desktops, and apps with incomplete Accessibility support may refuse insertion. WhisperType does not promise to type into every app.
