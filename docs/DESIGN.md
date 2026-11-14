# Native Design Direction

WhisperType should feel like a quiet macOS writing utility, not a browser dashboard inside a window. The goal is a clear distinction between recording, processing, a result ready to use, and a recoverable problem. Product polish is not evidence of live transcription accuracy or successful cross-app insertion.

## Provenance

The design source is OpenDesign's `modern-minimal` and `human-approachable` direction, explored using the `od` 0.19.2 workflow. The attempted generation failed at Claude authentication. **No successful generated OpenDesign artifact, render, or visual validation is claimed.** This native adaptation uses the source direction and the palette below rather than presenting a failed run as completed design work.

The installed OpenDesign shim is `/Users/ganeshepili/.opendesign/bin/od`. A bare `od` on macOS resolves to the unrelated system octal-dump utility. Future generation should use the OpenDesign brief/confirmation workflow, resolve the engine's authentication, and record a successful artifact before claiming generated provenance. The app itself does not depend on OpenDesign or its runtime.

## Visual Tokens

| Token | Value | Intended role |
| --- | --- | --- |
| Ink | `#172523` | Primary text and high-contrast controls |
| Warm background | `#F7F7F2` | Quiet main surfaces |
| Mint | `#A9E4CA` | Soft selection and supportive accents |
| Teal | `#176B58` | Primary actions and focused/active emphasis |

Use native system typography for legibility and familiar macOS metrics. SF Symbols provide lightweight runtime iconography without a downloaded icon set. There is no bundled custom app icon in the build script. Prefer restrained borders, comfortable spacing, and readable text over stacked promotional cards, oversized gradients, or decorative charts.

These hex values describe the light visual direction, not a complete accessible light/dark design system. Check actual text contrast, disabled states, increased contrast, and system appearance behavior before claiming accessibility or dark-mode completion. Do not rely on mint/teal alone to communicate state.

## Interaction Principles

- Keep the menu bar available; opening settings should not be necessary to begin an ordinary recording.
- Show whether audio is being recorded, whether a job is queued/processing, and whether the result was inserted or merely saved. A transcript appearing is not proof that insertion succeeded.
- Keep interim Live text visually distinct from final text. REST record-then-process mode must not pretend to be live streaming.
- Use a serial queue for final dictation work, with explicit cancellation. Starting another recording must not allow housekeeping to delete its audio.
- Do not steal focus to paste. A changed target should leave a recoverable result with deliberate copy/paste actions rather than write into the wrong document.
- Use native controls for preferences, microphone selection, permission status, lists, and text editing. Preserve keyboard operation, focus indication, and system text selection.
- Explain privacy boundaries at the action: ambient context is off by default, but a selected-text command sends that selected text intentionally.
- Surface storage/API/permission problems in plain language with a next action. Never silently turn a failed load into an empty library or overwrite a valuable history file.
- Keep transforms honest: "Meeting summary" transforms supplied notes. Do not use visual language implying automatic meeting capture or a notetaker service.

## Information Structure

The primary workflow is recording and a recoverable result. Supporting areas are local history, a scratchpad, vocabulary/snippets, app rules/transforms, and settings. Permissions and API configuration belong near onboarding and settings, not in an unexplained status badge.

History should make failed/cancelled/completed status understandable without exposing secrets. Optional audio is associated with the relevant entry, not a promise that every recording can be replayed. Retention settings must explain that scratchpad/library data are separate from history and that deletion failures may require attention.

Settings should separate model/processing choices from privacy and retention. Accurate mode is completed-file transcription; Live mode is a network stream that can fall back to the file. Advanced configuration should not obscure that API usage costs money or that changes in provider model availability can cause errors.

## Validation Boundary

No interactive visual acceptance, microphone permission flow, target-app insertion matrix, or VoiceOver audit is claimed by this document. The deliverable is a native prototype with an explicit direction and implementation constraints, not a verified design artifact. Check the actual bundle on desktop at several window sizes, text/contrast settings, keyboard-only navigation, and both success/error states before describing the UI as finished. There is no mobile UI in this project.
