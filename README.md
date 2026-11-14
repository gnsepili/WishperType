<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo-horizontal-dark.svg">
  <img src="assets/logo-horizontal-light.svg" alt="WhisperType" height="72">
</picture>

<br><br>

**Hold a key, speak, and clean text appears in whatever app you're using.**

A native, open source dictation app for macOS. Built with SwiftUI and AppKit, no third-party dependencies, bring your own OpenAI API key.

<br>

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![Status: early prototype](https://img.shields.io/badge/status-early%20prototype-orange)

[Features](#features) · [Install](#install) · [Shortcuts](#shortcuts) · [Privacy](#privacy) · [Docs](#documentation) · [Contributing](#contributing)

</div>

<br>

> [!NOTE]
> WhisperType is an early prototype. It is not notarized, and it has not been benchmarked against any other dictation product. Microphone capture, API access and text insertion across apps all need a manual check on your own Mac. [What is and isn't implemented](docs/FEATURES.md).

## Features

- **Dictate anywhere.** Hold a shortcut, talk, release. The result is inserted into the focused text field, with a guarded paste fallback.
- **Two modes.** *Accurate* records, then transcribes. *Live* streams audio and shows interim text as you speak.
- **Cleanup and styles.** Remove filler words and keep self-corrections, then write it as natural, casual, professional, concise, email or developer text.
- **Spoken commands.** Select text, hold the command shortcut and say "make this shorter", or run a named transform such as polish, bullets or summary.
- **Personal vocabulary and snippets.** Teach it names and jargon, and expand spoken phrases into saved text.
- **Per-app rules.** Give different apps their own style and instructions.
- **History and scratchpad.** Local history with optional audio, kept for 30 days by default.
- **Menu-bar app.** Lives in the menu bar, optional launch at login, pick your microphone.

## Install

You need macOS 14 or newer and an [OpenAI API key](https://platform.openai.com/api-keys) with billing enabled. A ChatGPT subscription does not include API usage.

**Build from source** (Swift 6 toolchain or Xcode Command Line Tools, no full Xcode needed):

```bash
git clone <this-repo-url>
cd whisper-type
./scripts/build-app.sh
open dist/WhisperType.app
```

**Or package a DMG** for Apple Silicon:

```bash
./scripts/build-dmg.sh
```

The app is ad-hoc signed and not notarized, so macOS may ask you to approve it in **System Settings > Privacy & Security**. Details are in [Development](docs/DEVELOPMENT.md).

### First run

1. Open **Settings** and paste your API key. It is stored in the macOS Keychain, never in a file.
2. Grant **Microphone** access. Grant **Accessibility** and **Input Monitoring** for text insertion and global shortcuts.
3. Try a short, non-sensitive sentence in TextEdit before using it on anything important.

The full walkthrough and default settings are in [Setup and Usage](docs/USAGE.md).

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Hold to dictate | `Control` + `Option` (Right Option or Fn/Globe available as presets) |
| Toggle dictation | `Control` + `Option` + `Space` |
| Spoken command on selected text | Hold `Control` + `Option` + `Command` |
| Transform selected text | `Control` + `Option` + `P` |
| Copy / paste last result | `Control` + `Command` + `C` / `V` |
| Cancel | `Escape` |

## Privacy

There is no WhisperType server, account or analytics. Audio and text go straight from your Mac to the OpenAI API using your key. Local history is on by default for 30 days, saved audio is off, and sharing of surrounding app text is off. Read [Privacy](docs/PRIVACY.md) before dictating anything sensitive.

> [!IMPORTANT]
> Despite the name, WhisperType does not run Whisper locally. Transcription needs an internet connection and an OpenAI API account.

## Documentation

| Doc | What's in it |
| --- | --- |
| [Setup and Usage](docs/USAGE.md) | API key, permissions, default settings, shortcuts |
| [Features](docs/FEATURES.md) | What is implemented and what is deliberately not |
| [Privacy](docs/PRIVACY.md) | What leaves your Mac and what stays on it |
| [Development](docs/DEVELOPMENT.md) | Building, testing, DMG packaging, validation notes |
| [Storage](docs/STORAGE.md) | On-disk layout and the persistence contract |
| [Design](docs/DESIGN.md) | Visual direction and tokens |

## Project layout

```text
Sources/WhisperCore/   Models, OpenAI client, realtime transcriber, text processing, persistence
Sources/WhisperType/   SwiftUI app, audio capture, overlay, system integration
Tests/                 Swift Testing suites (mocked HTTP, no API key or microphone needed)
scripts/               test.sh, build-app.sh, build-dmg.sh
```

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, run `./scripts/test.sh` before opening a pull request, and follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE). WhisperType is an independent project and is not affiliated with or endorsed by OpenAI or Wispr.
