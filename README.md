# Joe — Standalone iOS Research App

A native SwiftUI iPhone app with a direct **iPhone → Nightscout HTTPS** connection. Context collection, storage, Core ML inference, Apple Foundation Models, and speech synthesis run on the phone. The app does not call the original Python server, Mac mini, Tailscale, Ollama, or Gemini.

**Current status: source code and a testable research pipeline are implemented, but full Xcode builds and iPhone acceptance testing remain pending. No personalized model is bundled, and forecasts are never fabricated.** See the [implementation plan](IOS_STANDALONE_IMPLEMENTATION_PLAN.md) for requirements and [implementation status](docs/IMPLEMENTATION_STATUS.md) for delivered functionality and remaining work.

## Open and install

1. Install the full **Xcode 26 or later** and update the iPhone 15 Pro to **iOS 26 or later**. This project targets iOS 26 to use Foundation Models. If the model is disabled or not downloaded, the app uses deterministic templates. See [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels).
2. Open `ios/JoeMobile.xcodeproj` and select the `JoeMobile` scheme.
3. Under Signing & Capabilities, choose your Apple Developer Team and change the bundle ID if necessary. Signing and provisioning must support HealthKit; entitlements are included. Do not commit personal signing settings.
4. Connect the iPhone, enable Developer Mode, select the phone, and run the app. A Mac is needed for development installation, but not for normal use afterward. Development signing expires; long-term installation requires an appropriate developer distribution method.
5. In **Settings**, enter the **public HTTPS Nightscout base URL** and a read-only access token, or the API secret's 40-character SHA-1 hash. The URL and credentials are stored only in the device's Keychain. Do not include the token in the base URL.
6. In **Lifestyle**, enable HealthKit, calendar, and location access separately. Background Visits and geofences require the user to grant Always location access separately.

**First device acceptance test:** disable Tailscale and Wi-Fi, then open Nightscout's `/api/v1/entries.json?count=1` in Safari over cellular, authenticating if required. Refresh the app afterward. If Nightscout is reachable only through Tailscale, first provide a public, authenticated HTTPS service.

Without a Core ML model, you can still sync real CGM and pump data, collect context, view charts, and use local explanations. The forecast panel explicitly displays “No trained Core ML model is installed.”

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

- The app uses URLSession only to read Nightscout entries, treatments, and profiles. It does not write to Nightscout or include a pump-control path.
- SwiftData does not enable CloudKit. Keychain credentials use ThisDeviceOnly protection. Tokens and authentication URLs are not logged. System backup behavior depends on device settings; exported files are managed by the destination you choose.
- Calendar titles are used only for transient local classification. Titles, notes, and attendees are not stored. HealthKit requests only the required read permissions. Empty results mean data is unavailable, not necessarily that permission was denied. See [HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data).
- Location records normally contain categories and visit times. Coordinates are stored only for places you explicitly name; continuous routes are not stored.
- Apple's model generates only a constrained explanation focus. Four local tools supply visible values through templates. Unavailability or refusal triggers a deterministic fallback.
- Background refresh, HealthKit observers, Visits, and geofences are opportunistic and cannot guarantee five-minute execution. Do not depend on this app for emergency alerts.
- Invalid, future, or unsupported CGM readings outside 40–400 mg/dL are excluded. The interface distinguishes measurements, stale cached readings, and experimental forecasts.
- The interface, assistant templates, permission descriptions, and documentation are in English. Speech synthesis prefers an installed English voice.

For observational research only. The app does not replace CGM, a treatment plan, or clinical judgment. No conclusions about device battery use, usability, or clinical performance have been established.
