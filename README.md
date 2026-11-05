# Joe — Standalone iOS Research App

A native SwiftUI iPhone app with a direct **iPhone → Nightscout HTTPS** connection. Context collection, storage, Core ML inference, Apple Foundation Models, speech recognition, and speech synthesis run on the phone. Natural conversation uses Apple's on-device Foundation Model with Joe's browser-inspired companion persona in `LanguageModelSession` instructions. No cloud model, API key, Mac mini, Tailscale, original Python server, or Gemini TTS is required.

**Current status: source code and a testable research pipeline are implemented, and a full unsigned iOS build passes with Xcode 27.2. Signed iPhone installation and acceptance testing remain pending. No personalized model is bundled, and forecasts are never fabricated.** See the [implementation plan](IOS_STANDALONE_IMPLEMENTATION_PLAN.md) for requirements and [implementation status](docs/IMPLEMENTATION_STATUS.md) for delivered functionality and remaining work.

## Open and install

1. Install the full **Xcode 26 or later** and update the iPhone 15 Pro to **iOS 26 or later**. This project targets iOS 26 to use Foundation Models. If the model is disabled or not downloaded, the app uses deterministic templates. See [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels).
2. Open `ios/JoeMobile.xcodeproj` and select the `JoeMobile` scheme.
3. Under Signing & Capabilities, choose your Apple Developer Team and change the bundle ID if necessary. Signing and provisioning must support HealthKit; entitlements are included. Do not commit personal signing settings.
4. Connect the iPhone, enable Developer Mode, select the phone, and run the app. A Mac is needed for development installation, but not for normal use afterward. Development signing expires; long-term installation requires an appropriate developer distribution method.
5. In **Settings**, enter the **public HTTPS Nightscout base URL** and a read-only access token, or the API secret's 40-character SHA-1 hash. The URL and credentials are stored only in the device's Keychain. Do not include the token in the base URL.
6. In **Settings**, enable HealthKit, calendar, and location access separately. Background Visits and geofences require the user to grant Always location access separately.

**First device acceptance test:** disable Tailscale and Wi-Fi, then open Nightscout's `/api/v1/entries.json?count=1` in Safari over cellular, authenticating if required. Refresh the app afterward. If Nightscout is reachable only through Tailscale, first provide a public, authenticated HTTPS service.

Without a Core ML model, you can still sync real CGM and pump data, collect context, view charts, and use local explanations. The forecast panel explicitly displays “No trained Core ML model is installed.”

## App navigation and input

The tab order is **Joe → Overview → Lifestyle → Settings**, with Joe selected on launch.

- **Joe:** message bubbles retain both sides of the current session, with a bottom composer, quick questions, and per-message read-aloud controls. Type a message or hold the microphone, release to finish transcription, review the text, and tap Send. Final conversations and versioned safety logs are saved locally, a short recent conversation restores on launch, and clearing local data removes them.
- **Voice input:** microphone and speech permissions are requested on first use. Recognition requires on-device support for the selected English or Mandarin language; audio is not uploaded and there is no cloud fallback. If permissions are granted after you release the button, hold again to begin. Recording stops on interruption, leaving the page, app inactivity, or the 55-second limit. Voice accuracy and audio routes still need device testing. See [Apple's on-device recognition requirements](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition).
- **Overview:** a large measured glucose value and trend arrow, a 3/6/12/24-hour dot chart, experimental forecasts, the latest positive recorded bolus, and research metrics. Basal events are excluded from the bolus card. Unknown trends remain unavailable, and stale readings stay explicitly labeled.
- **Lifestyle:** read-only current activity, sleep, calendar category, and place data, with update time and unavailable states. Display snapshots are separate from the historical context used for causal forecast features.
- **Settings:** Nightscout connection, HealthKit/calendar/location access, optional background visits, named places, freshness settings, export, and clearing.

## Joe conversation model and voice

The app icon uses the supplied T1D Ally artwork. Joe runs on **Apple's on-device Foundation Model**. The browser app's supportive persona is adapted into `JoeConversation.persona` and passed to `LanguageModelSession(instructions:)`; the model generates natural replies rather than merely selecting a template category.

Static instructions are split into versioned persona, safety, and explanation sections. Each turn first passes through a Swift safety coordinator; a permitted local session registers only relevant structured tools and uses a bounded replay of recent messages. Current readings are never embedded in instructions. This avoids accumulating obsolete snapshots and limits the context budget. No conversation or health context is sent to a cloud model. Versioned per-turn records and optional synthetic persona regressions are included in user-initiated research exports. Current low/high, missing data, stale current-glucose questions, dose requests, unavailable models, tool failures and rejected model responses use a labeled deterministic fallback. Responses are screened for tool-supported facts, language, prediction/measurement distinctions and unsafe advice. See [architecture implementation](docs/PROMPT_ARCHITECTURE_IMPLEMENTATION.md) for safeguards and limits. The browser Python server's web-search, weather, and decision/interpretation pipeline have not been ported, and those tools are not claimed.

In **Settings → Joe conversation model**, check model availability. Enable Apple Intelligence in iPhone Settings and let its required model assets finish downloading. No API key is needed. Unused credentials from the superseded cloud prototype are removed locally during app initialization without being read or sent anywhere.

In **Settings → Voice**, select English or Mandarin. Hold the microphone to record, release to finish, review the transcription, and send. Recognition requires local support for the selected language. Automatic reply reading defaults to enabled for new settings and can be disabled.

Read-aloud synthesizes speech locally to PCM, validates that audio was produced, then plays the temporary audio through `AVAudioPlayer` with a playback audio session. The temporary file is deleted when stopped or finished. Two diagnostics distinguish the stages:

- **Test sound:** plays a locally generated tone through the same player and output route, without invoking speech synthesis.
- **Test voice:** generates and plays a short local spoken message. Status, media volume, and the output device are shown. Silent/empty synthesis, timeout, and playback errors produce visible messages.

If the tone is audible but the voice is not, check downloaded system voices in iPhone Accessibility settings. If neither is audible, raise media volume while playing the test and check the displayed Bluetooth/output route. Code and PCM-file checks cannot confirm audible output on a physical iPhone; device verification remains required.

## Repository structure

```text
Sources/JoeCore/             Pure Swift types, Nightscout decoding, feature and forecast validation
Tests/JoeCoreTests/          Core tests and Python/Swift feature parity fixtures
ios/JoeMobile.xcodeproj/     Xcode project and shared scheme
ios/JoeMobile/              SwiftUI, SwiftData, system services, Core ML, and Foundation Models
analysis/forecast/          Dataset construction, A–D experiments, training, evaluation, and export
scripts/                    Project generation, cross-language fixtures, checks without XCTest
docs/                       Feature definitions, device tests, and implementation status
```

The project uses the local Swift package at the repository root and requires no CocoaPods, XcodeGen, or third-party runtime services. After adding Swift files or model resources, run:

```sh
python3 scripts/generate_project.py
```

The generator rebuilds `project.pbxproj`. Select your personal signing Team again in Xcode if needed.

## Tests

On a Mac with only Command Line Tools:

```sh
swift build
python3 scripts/check_core.py
python3 scripts/check_speech_renderer.py
```

With full Xcode, you can also run `swift test`. The CLI checks execute the same test source; they are not reported as successful XCTest runs when XCTest is unavailable.

Use Python 3.11 for training and export. A native macOS Core ML wheel must be available:

```sh
python3.11 -m venv .venv311
.venv311/bin/pip install -r analysis/forecast/requirements.txt
cd analysis/forecast
../../.venv311/bin/python -m unittest -v test_pipeline.py
```

These tests use temporary synthetic data to verify the implementation. They do not establish real glucose forecasting performance.

## Train and add a personalized model

1. Save local data through **Settings → Prepare research JSON export → Share export**. Collect several weeks of data if possible. Historical context from before collection was enabled must not be invented.
2. Run locally:

```sh
cd analysis/forecast
../../.venv311/bin/python build_dataset.py /absolute/path/Joe-research-export.json
../../.venv311/bin/python train.py data/dataset.json
../../.venv311/bin/python export_coreml.py
cd ../..
python3 scripts/generate_project.py
```

3. Review `analysis/forecast/artifacts/report.json` for data coverage, A–D experiments, and chronological test metrics. The exporter checks Python/Core ML numerical parity before writing resources. Reinstall the app afterward.
4. Follow the [device test checklist](docs/DEVICE_TESTS.md) for on-device parity and end-to-end acceptance, and collect 3–7 days of shadow-mode results.

Training compares persistence, Ridge, and Random Forest using a chronological 70/15/15 split, with future labels crossing split boundaries purged. Ridge feature groups and alpha are selected using validation data; Random Forest is currently an offline comparator. The Core ML model is a linear network with standardization folded into its coefficients and runs on the CPU. The app requires 38 ordered inputs and a matching manifest. Model files and research data are excluded from Git by default.

Hypoglycemia probability modeling, IOB/COB, and clinical error grids remain incomplete; uncalibrated values are not substituted. Validation P90 absolute error is a research error summary, not a confidence interval with guaranteed coverage.

## Privacy and runtime limitations

- Conversation logs and regression records stay in the local SwiftData store until cleared or explicitly exported.
- The app uses URLSession only to read Nightscout entries, treatments, and profiles. It does not write to Nightscout or include a pump-control path.
- SwiftData does not enable CloudKit. Keychain credentials use ThisDeviceOnly protection. Tokens and authentication URLs are not logged. System backup behavior depends on device settings; exported files are managed by the destination you choose.
- Calendar titles are used only for transient local classification. Titles, notes, and attendees are not stored. HealthKit requests only the required read permissions. Empty results mean data is unavailable, not necessarily that permission was denied. See [HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data).
- Location records normally contain categories and visit times. Coordinates are stored only for places you explicitly name; continuous routes are not stored.
- Apple's local model receives Joe's persona in instructions, recent messages, and four read-only tools. It must distinguish measurements from experimental forecasts and acknowledge missing or stale data. Unavailability or refusal triggers a labeled local fallback.
- Background refresh, HealthKit observers, Visits, and geofences are opportunistic and cannot guarantee five-minute execution. Do not depend on this app for emergency alerts.
- Invalid, future, or unsupported CGM readings outside 40–400 mg/dL are excluded. The interface distinguishes measurements, stale cached readings, and experimental forecasts.
- The interface, assistant templates, permission descriptions, and documentation are in English. Speech input supports selected English or Mandarin, and speech synthesis selects an English or Mandarin voice from the reply text.

For observational research only. The app does not replace CGM, a treatment plan, or clinical judgment. No conclusions about device battery use, usability, or clinical performance have been established.
