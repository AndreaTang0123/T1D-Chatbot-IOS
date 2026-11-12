# Implementation status

Implementation began in a standalone repository containing only a README and implementation plan. The original browser repository was not modified, and no private configuration, health CSV files, or credentials were read. The original implementation plan remains unchanged.

| Module | Implemented source functionality |
|---|---|
| Native app | SwiftUI Joe (default chat), Overview, Lifestyle, and Settings tabs; Xcode project and shared scheme; minimum iOS 26 |
| Nightscout | HTTPS GET entries/treatments/profile, token or SHA-1 authentication, initial 48-hour window, six-hour overlap, ID upserts, bounded retries, no redirects; full pages are rejected rather than silently truncated |
| Keychain / SwiftData | URL and credentials in ThisDeviceOnly Keychain; local health records, context, features, profiles, forecasts, and errors; no CloudKit; export and clearing |
| HealthKit | Settings-based explicit read authorization for steps, heart rate, workouts, and sleep; step statistics, merged sleep intervals, observers; unavailable data stays missing |
| Calendar | Settings-based explicit full-access request; current/next event categories plus explicit local day-event title/time lists; requested titles persist in chat/export only; no notes or attendees |
| Location | Coarse location, optional Always Visits/significant changes/geofences, named places, and categorical visit records; no continuous routes |
| Features | UTC five-minute buckets, causal CGM grid, separate missingness flags, and Python/Swift fixtures |
| Forecast | Core ML CPU inference at 30/60 minutes; manifest/input/output validation; stops when model, history, or fresh CGM is unavailable |
| Evaluation | Forecast logs, subsequent ±150-second CGM matching, errors, MAE display, and export |
| Assistant / TTS | Gemma 4 E2B installation and LiteRT-LM availability handling, four read-only tools, Joe persona in session instructions, bounded multi-turn natural conversation, deterministic fallback, text input, English/Mandarin speech voices, and hold-to-talk on-device transcription with editable drafts |
| Training | Coverage report, chronological 70/15/15 split with boundary purging, A–D Ridge experiments, persistence, Random Forest comparison, Core ML export, and numerical fixtures |
| Background | Foreground, manual, BGAppRefresh, and HealthKit observer updates; cold-start initialization; no fixed refresh guarantee |

## Verified

- `swift build` successfully builds JoeCore.
- `python3 scripts/check_core.py`: 20 checks pass, including four Python/Swift numerical fixtures.
- Python 3.11: all six `python -m unittest -v test_pipeline.py` checks pass.
- Training → Core ML conversion → local CPU prediction parity passes using temporary synthetic data. Test models are deleted afterward and are not bundled in the app.
- The app launches in an iOS 27.2 simulator with Joe selected by default; the initial chat, composer, and tab order were visually checked. Voice capture and actual device layout remain pending.
- iOS Swift files pass parser checks. NightscoutClient, KeychainStore, and ForecastService pass independent type checking with the local SDK.
- The project, Info.plist, and entitlements pass `plutil -lint`.

**The full iOS app builds successfully with Xcode 27.2 for generic iOS device and simulator targets with code signing disabled.** This build includes SwiftData macro expansion and LiteRT-LM native linking. The `LocalStore` FileManager argument label was corrected from `atPath:` to `ofItemAtPath:`. Signed installation and device UI validation remain pending.

Initial verification used Command Line Tools without XCTest or the required macro plugins. The earlier core checks compiled the test source directly and were not reported as an XCTest run. With full Xcode available, all 48 XCTest tests now pass.

## Chat and navigation update

Joe is the default tab and displays a session conversation with a bottom text/voice composer. Hold-to-talk transcribes locally to an editable draft; sending remains explicit. HealthKit, calendar, and location setup live in Settings. Lifestyle displays only current data. Overview uses Nightscout trend arrows and selectable 3/6/12/24-hour dot charts; its pump card shows only the latest bolus, excluding basal and future events. New core tests cover trend mappings and bolus selection. Microphone permissions, recording/release, audio interruptions, and real-device layouts require device acceptance testing.

## Icon, local conversation, and audio update

- The supplied T1D Ally PNG is resized to an opaque 1024×1024 AppIcon asset; both build configurations select it.
- Gemma 4 E2B replaces Apple Intelligence entirely. LiteRT-LM 0.19.1 is pinned in Xcode; a verified 2.59 GB model is downloaded over Wi-Fi or imported explicitly. Settings provides progress, cancellation, load/unload and removal. Joe persona/safety/explanation remain system instructions. Selected local tool results and bounded memory are user-message data; Swift gating and validation remain in force.
- Cloud settings and the cloud network client were removed following the user's clarification. Only a delete-only Keychain migration remains to remove a previously saved prototype credential.
- Voice input uses stable UIKit touch tracking, token-guarded authorization/callbacks, and a five-second finalization window. Settings provide English/Mandarin selection and automatic reading.
- Read-aloud now writes local synthesized PCM into a temporary audio file, rejects empty/silent synthesis, and plays through `AVAudioPlayer`. Settings expose a tone test, voice test, playback state, output route, and media volume. Temporary speech is removed when stopped or finished.
- Core tests cover persona placement, bounded conversation prompts, and canceled/released input. `scripts/check_speech_renderer.py` checks PCM persistence, silent/empty rejection, and cancellation without playing sound. Natural model responses and audible output still require device acceptance testing.

## Safety/prompt architecture plan

The new [architecture implementation](PROMPT_ARCHITECTURE_IMPLEMENTATION.md) maps the sibling prompt/model plan to code. Safety decisions, deterministic gating, structured tools, actual tool-call evidence, response screening, split/versioned prompts, distinct availability/errors, short session memory/on-demand automatic Gemma loading, persistent versioned dialogue logs, and ten bilingual persona fixtures are implemented. All 74 XCTest checks pass; a ten-case Mac Gemma run produced nine screened replies and one rejection fallback; iPhone generation and manual persona review remain pending. The committed regression report is explicitly a deterministic/fake-provider run.

## Remaining work

1. Complete signed iPhone installation and device testing of system permissions, UI, and background lifecycle behavior.
2. Verify public Nightscout HTTPS and real authentication over cellular with Tailscale and the Mac disabled. No private Nightscout instance has been contacted.
3. Train a personalized model using actual historical data. The repository contains no personalized model, real performance metrics, or ablation conclusions.
4. Verify device numerical parity, latency, thermal behavior, battery use, and 3–7 days of shadow mode.
5. Hypoglycemia probability modeling and calibration are not implemented; `lowRisk` is explicitly nil. The offline endpoint threshold screen is not an hour-long risk probability.
6. IOB/COB and active profile schedules/DIA remain unvalidated. Profiles are fetched and persisted only. Basal-rate features use valid Temp Basal absolute events; IOB/COB remain missing.
7. Clarke/Parkes error grids, event warning lead time, and sleep-stratified evaluation remain pending. Basic errors, endpoint screens, and meal/recent-exercise/UTC-overnight strata are implemented. There are no automatic alerts.
8. Source-time retrospective replay cannot reconstruct all arrival delays and does not establish real-time information availability.

## Architecture

```mermaid
flowchart TD
    NS[Nightscout HTTPS] -->|Read-only URLSession| SYNC[Local sync]
    KC[Keychain] --> SYNC
    HK[HealthKit] --> CTX[Local context]
    EK[EventKit] --> CTX
    CL[Core Location] --> CTX
    SYNC --> DB[SwiftData]
    CTX --> DB
    DB --> FEAT[Five-minute features / Missingness flags]
    FEAT --> ML[Core ML CPU]
    ML --> LOG[Forecasts / Subsequent actual-value matching]
    LOG --> DB
    DB --> TOOLS[Four local read-only tools]
    TOOLS --> FM[Gemma 4 E2B / Joe system instructions]
    FM --> OUT[Natural reply / Labeled local fallback]
    OUT --> UI[SwiftUI / Local TTS]
```

See [README](../README.md), [DEVICE_TESTS](DEVICE_TESTS.md), and [FEATURE_SCHEMA](FEATURE_SCHEMA.md).

## Gemma migration

See [Gemma setup](GEMMA_SETUP.md). The dependency and model revision/hash are pinned; 48 core tests pass including integrity rejection and tool-payload routing. Device and simulator build verification is recorded in the setup document. On-device speed, peak memory, thermal behavior, voice audibility and model persona quality still require iPhone 15 Pro acceptance testing. This change ports prompting and orchestration; it does not fine-tune weights or add LoRA.

## Automatic Gemma lifecycle

Eligible chat requests and synthetic regression wait for installed-file verification and a shared automatic load; launch alone does not initialize weights. Active-use leases protect generation from idle release. Foreground idle is 5 minutes; background idle is 2 minutes, with foreground elapsed-time recheck because iOS may suspend timers. Background entry cancels active generation/initialization but retains an already-ready idle engine for brief switches. Memory warnings release it. The next eligible request reloads automatically; failed loads do not loop. Manual load/unload remain available. Native Mac load/generate/idle-release/reload verification passes; actual iPhone suspension/memory-pressure behavior remains an acceptance check.
