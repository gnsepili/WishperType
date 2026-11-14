# Feature Scope

WhisperType is a personal macOS 14+ prototype, not a claim of full Wispr Flow parity. "Implemented" below means a source path exists, not that microphone capture, paid APIs, or every target application has passed live end-to-end testing. Automated core tests cannot establish speech accuracy or product superiority.

## Desktop Matrix

| Capability | WhisperType scope | Verification / limitation |
| --- | --- | --- |
| Hold/toggle dictation | Global modifier/keycode shortcuts and microphone capture | Permission, keyboard, and hardware testing required; native integration in `SystemIntegration.swift` and `AudioRecorder.swift` |
| Record then transcribe | REST audio upload, default `gpt-4o-transcribe` | HTTP requests/errors tested with mocks; real account access and quality not verified |
| Live transcription | WebSocket PCM streaming, default `gpt-live-transcribe`; file-based REST fallback at the app layer | Interim text is provisional; live service/fallback behavior needs manual testing |
| Queued processing | Serial asynchronous dictation processing with UI state | Not parallel insertion; check cancellation and focus changes end to end |
| Cross-app insertion | Accessibility snapshot checks, selected-text insertion where supported, guarded paste fallback | Refuses changed focus, secure fields, and unsupported controls; no universal compatibility claim |
| Cleanup, styles, formatting | Light/polished cleanup; natural, casual, professional, concise, email, developer styles | Rewrite prompts and local text handling tested; model behavior is not deterministic |
| Corrections/backtracking | Rewrite instructions preserve intended self-corrections; local replacements avoid deleting ambiguous speech | Not equivalent to a benchmarked semantic correction engine |
| Personal vocabulary | Transcription hints and literal local corrections | Library persistence and text-processing tests |
| Spoken snippets | Whole-phrase expansion, deterministic overlap handling, no recursive expansion | Local text-processing and persistence tests; not cloud-synced |
| App-specific rules | Bundle-ID style and instruction rules | Personal rules, not deep app/IDE semantic integration |
| Language and translation | Auto/explicit input language; optional rewrite translation target | Model/language availability and multilingual accuracy require live checks |
| Selected-text commands | Explicit selection plus spoken instruction or named transform | Selection is deliberately sent even with ambient context off; not general computer control |
| Custom transforms | Polish, concise, professional, bullets, meeting summary, user instructions | Operates on supplied text; no arbitrary scripts, tools, or autonomous actions |
| History | Local entries with status, text, timing, optional audio filename | Atomic storage/retention tested; no cloud history service |
| Scratchpad | Local UTF-8 text persistence and text transformation workflow | No cloud notes database or collaborative editor |
| Microphone selection | Core Audio input device selection; AAC recording and PCM conversion | Device disconnects/sample-rate behavior need hardware testing |
| Silence/duration controls | Configurable silence auto-stop and a default 20-minute duration limit | Not an hours-long meeting capture pipeline; upload cap is 25 MB |
| Login item | `SMAppService.mainApp` registration integration | Must test a stable signed bundle with user approval |
| Privacy controls | Context off by default, audio retention off, local history default 30 days, Keychain API key | Provider-side retention still applies; see `PRIVACY.md` |

Source references: [`Models.swift`](../Sources/WhisperCore/Models.swift), [`TextProcessing.swift`](../Sources/WhisperCore/TextProcessing.swift), [`OpenAIClient.swift`](../Sources/WhisperCore/OpenAIClient.swift), [`RealtimeTranscriber.swift`](../Sources/WhisperCore/RealtimeTranscriber.swift), [`Persistence.swift`](../Sources/WhisperCore/Persistence.swift), [`AudioRecorder.swift`](../Sources/WhisperType/AudioRecorder.swift), [`SystemIntegration.swift`](../Sources/WhisperType/SystemIntegration.swift).

## Deliberate Gaps

| Product area | Status |
| --- | --- |
| Automatic learning from edits, dictionary CSV import | Not implemented; add corrections manually or import WhisperType library JSON |
| Mouse/custom arbitrary hotkeys, double-tap hands-free, automatic Enter submission | Not implemented; three hold presets and fixed toggle/command shortcuts |
| Rich-text snippets and website-specific styles | Not implemented; plain-text snippets and native bundle-ID rules |
| Ambient screenshots, automatic music muting, ranked microphone fallback | Not implemented; focused text context and explicit microphone selection only |
| Teams, administration, shared dictionaries, enterprise policy | Not implemented |
| Accounts, hosted sync, cross-device library/history | Not implemented |
| iOS, Android, Windows, Linux | Not implemented; native macOS only |
| Meeting system/loopback audio, multi-speaker diarization, meeting detection, calendar integration | Not implemented |
| Meeting notes hub, meeting search/chat, automated pre-reads | Not implemented |
| IDE workspace indexing, file tagging, variable recognition | Not implemented; developer style is a writing instruction, not project indexing |
| MCP integrations, Slack/Email/Calendar action routing | Not implemented |
| Offline/on-device speech models | Not implemented; the name does not mean local Whisper inference |
| Automatic updates, Developer ID distribution, notarization | Not implemented; local ad-hoc `.app` builds only |
| Universal compatibility and accessibility certification | Not established |

**Meeting summary is a text transform.** Select or paste notes and ask for a summary. This does not record remote participants or desktop playback, identify speakers, join calls, detect meetings, or automatically organize meeting recordings. Recording microphone sound in the room is not a substitute for a consented, tested meeting notetaker.

## Public References

The following are Wispr's public help-center references, checked on September 6, 2026. These references establish the comparison categories, not exact implementation equivalence, availability in every plan/platform, or measured quality. Wispr's docs and product can change; WhisperType is unaffiliated.

| Documented Wispr category | Public help reference | WhisperType interpretation |
| --- | --- | --- |
| Shortcuts and Command Mode | [Command Mode](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode), [supported hotkeys](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts) | A limited set of native shortcuts and explicit selected-text rewriting |
| Dictionary and snippets | [Dictionary](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary), [snippets](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets) | Local vocabulary and literal phrase expansion |
| Style and smart formatting | [Styles](https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles), [Smart Formatting & Backtrack](https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack) | Configurable prompts and conservative local formatting, not the same engine |
| Transforms and auto cleanup | [Transforms](https://docs.wisprflow.ai/articles/8068950331-how-to-use-transforms-beta), [Auto Cleanup](https://docs.wisprflow.ai/articles/4136931124-how-to-use-auto-cleanup-beta) | Explicit rewrite transforms and optional cleanup |
| Scratchpad | [Scratchpad](https://docs.wisprflow.ai/articles/9618237082-using-the-scratchpad-to-save-and-edit-notes) | One locally persisted text scratchpad |
| Languages and device sync | [Languages](https://docs.wisprflow.ai/articles/3191899797-use-flow-with-multiple-languages), [device sync](https://docs.wisprflow.ai/articles/5284722493-sync-flow-across-your-devices) | Configurable cloud language processing, no sync |
| IDE workflows | [IDE support](https://docs.wisprflow.ai/articles/6434410694-use-flow-with-cursor-vs-code-and-other-ides) | Guarded text insertion and developer writing style only |
| Meeting notetaking | [Wispr Notetaker collection](https://docs.wisprflow.ai/collections/8559995472-wispr_notetaker), [recording a meeting](https://docs.wisprflow.ai/articles/9238501024-recording-a-meeting-with-notetaker-beta) | Not implemented; a meeting-summary text prompt is not this feature |

The [Using Wispr Flow collection](https://docs.wisprflow.ai/collections/7303194563-using_wispr_flow) also lists teams, device sync, desktop/mobile navigation, IDE-specific features, and integrations. They are explicitly outside this personal prototype's scope rather than silently counted as complete.

## Acceptance Checks

1. Run `./scripts/test.sh` and `./scripts/build-app.sh`; preserve the command output for the exact source revision being evaluated.
2. With an API key and explicit permissions, test short dictation in a basic macOS text editor, cancellation, focus changes, and a safe paste fallback.
3. Test Live mode with your account, including disconnect/fallback, and check actual usage charges rather than inferring them from UI latency.
4. Check a selected-text command with ambient context disabled; confirm that sharing that selection is intentional.
5. Change retention settings, restart, and inspect local data. Test permission/storage errors without resetting valuable files.
6. Before making any performance claim, use representative audio, languages, target applications, and a disclosed measurement procedure. None has been performed here.
