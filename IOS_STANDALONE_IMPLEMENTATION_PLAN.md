# Joe Standalone iOS App — Implementation Plan

## 1. Goal

Build a standalone iOS app for iPhone 15 Pro that:

- fetches CGM, pump, insulin, and meal data directly from Nightscout;
- collects lifestyle context from HealthKit, Calendar, and Core Location;
- stores and aligns data locally;
- runs personalized 30-minute and 60-minute glucose forecasts on-device;
- explains structured forecasts using Apple's on-device Foundation Model;
- works at runtime without a Mac mini or Tailscale.

> The Mac is still required for Xcode development, initial model training, Core ML conversion, and installation. It is not required for normal use after deployment.

## 2. Scope

### In scope

- Native SwiftUI app
- Direct Nightscout HTTPS access
- Keychain credential storage
- SwiftData local database
- HealthKit, EventKit, and low-power Core Location
- Five-minute multimodal feature construction
- Core ML glucose forecasting
- Apple Foundation Models explanation
- Text input and local text-to-speech
- Shadow-mode prediction logging and evaluation

### Out of scope this semester

- Automatic pump control
- Insulin-dose recommendations
- Basal or bolus changes
- On-phone LLM fine-tuning
- Guaranteed five-minute background execution
- Multi-user accounts
- Production App Store release
- Complete native recreation of the current streaming voice pipeline

## 3. Research Questions

### RQ1 — Context-aware forecasting

Does adding insulin, meal, activity, sleep, location, and calendar context improve personalized 30-minute and 60-minute glucose forecasts compared with a CGM-only baseline?

### RQ2 — On-device feasibility

Can forecasting and explanation run on an iPhone 15 Pro with acceptable latency, reliability, privacy, and battery use?

## 4. Success Criteria

- [ ] Mac mini is powered off during the final runtime test.
- [ ] Tailscale is disabled during the final runtime test.
- [ ] iPhone retrieves current CGM and pump data directly from Nightscout.
- [ ] Nightscout credentials are stored in Keychain and never committed.
- [ ] HealthKit, Calendar, and location context are collected with permission.
- [ ] The app constructs timestamp-aligned local feature records.
- [ ] Core ML produces 30-minute and 60-minute forecasts locally.
- [ ] Forecasts are stored and later matched with actual CGM values.
- [ ] Stale, missing, and invalid data are handled explicitly.
- [ ] The assistant explains structured results without inventing values.
- [ ] The app never recommends insulin doses or controls a pump.

## 5. Critical Precondition

Before implementation, verify that Nightscout is reachable without Tailscale:

1. Disable Tailscale on the iPhone.
2. Disable Wi-Fi and use cellular data.
3. Open the Nightscout HTTPS URL in Safari.
4. Test `https://YOUR-NIGHTSCOUT-DOMAIN/api/v1/entries.json?count=1`.

Decision:

- Reachable: the app can connect directly.
- Not reachable: deploy Nightscout behind secure public HTTPS or add a small authenticated cloud proxy.

This is a release gate. A standalone app cannot fetch current CGM data if Nightscout is available only inside the Tailscale network.

## 6. Architecture

```text
Nightscout HTTPS
        | URLSession
        v
Joe iOS App
├── NightscoutClient
├── HealthKitService
├── CalendarService
├── LocationService
├── SwiftData
├── FeatureBuilder
├── Core ML ForecastService
├── Apple Foundation Model
└── SwiftUI / local TTS
```

Runtime requires the iPhone, Nightscout HTTPS, and relevant user permissions. It does not require the Mac mini, Tailscale, Python server, browser client, Ollama, or Gemini TTS.

## 7. Repository Structure

```text
T1D-Chatbot/
├── analysis/forecast/
│   ├── build_dataset.py
│   ├── features.py
│   ├── train.py
│   ├── evaluate.py
│   ├── export_coreml.py
│   └── reports/
├── ios/JoeMobile/
│   ├── App/
│   ├── Models/
│   ├── Services/
│   │   ├── NightscoutClient.swift
│   │   ├── HealthKitService.swift
│   │   ├── CalendarService.swift
│   │   ├── LocationService.swift
│   │   ├── ForecastService.swift
│   │   ├── AssistantService.swift
│   │   └── SpeechService.swift
│   ├── Storage/
│   │   ├── LocalStore.swift
│   │   └── KeychainStore.swift
│   ├── Features/
│   │   ├── FeatureBuilder.swift
│   │   └── ContextClassifier.swift
│   ├── Views/
│   └── Resources/GlucoseForecaster.mlpackage
└── IOS_STANDALONE_IMPLEMENTATION_PLAN.md
```

## 8. Local Data Model

### CGMSample

- timestamp in UTC
- glucose in mg/dL
- direction
- source timestamp
- received timestamp

### PumpEvent

- timestamp in UTC
- event type
- insulin units
- basal rate
- carbohydrates
- duration

### ContextSample

- timestamp in UTC
- steps in the last 30 minutes
- heart rate
- workout type
- previous-night sleep duration
- place category
- calendar category
- freshness flags

### ForecastRecord

- generation timestamp
- source CGM timestamp
- current glucose
- 30-minute and 60-minute forecasts
- hypoglycemia risk
- uncertainty
- later actual values
- errors
- model and feature-schema versions
- data-quality flags

### Time rules

- Store timestamps in UTC and convert only for display.
- Store source and receive timestamps separately.
- Never present an old reading as current.
- Use a configurable 15-minute CGM stale threshold.

## 9. Nightscout Integration

Required endpoints:

- `GET /api/v1/entries.json`
- `GET /api/v1/treatments.json`
- `GET /api/v1/profile.json`

Tasks:

- [ ] Validate the Nightscout base URL.
- [ ] Store URL and token in Keychain.
- [ ] Fetch the latest CGM reading.
- [ ] Incrementally fetch CGM history and treatments.
- [ ] Fetch the active pump profile.
- [ ] Deduplicate records.
- [ ] Retry transient failures with bounded backoff.
- [ ] Reject malformed or implausible values.
- [ ] Expose typed error states to the UI.

Refresh on app launch, foreground entry, manual refresh, and any background opportunity granted by iOS. Do not claim guaranteed five-minute background polling.

## 10. HealthKit Integration

Initial read types:

- Step count
- Heart rate
- Workouts
- Sleep analysis

Tasks:

- [ ] Add the HealthKit capability and purpose strings.
- [ ] Request only required data types.
- [ ] Query historical samples for alignment.
- [ ] Calculate steps over the last 30 minutes.
- [ ] Retrieve the latest valid heart-rate sample.
- [ ] Summarize the most recent sleep interval.
- [ ] Detect recent workouts.
- [ ] Register observer/background delivery where appropriate.
- [ ] Support denied and partially available permissions.

Missing HealthKit context must be represented explicitly and never guessed.

## 11. Calendar Integration

Features:

- current event category
- next event category
- event start and end time
- time until next event

Local categories:

`class`, `meeting`, `meal`, `travel`, `medical`, `exercise`, `other`

Tasks:

- [ ] Add EventKit access and purpose strings.
- [ ] Request full read access only when enabled.
- [ ] Query a narrow window around the current time.
- [ ] Classify events locally.
- [ ] Avoid storing notes or participant lists.
- [ ] Support denied permission.

## 12. Location Integration

Use Visits, significant location changes, and user-defined geofences instead of continuous high-accuracy GPS.

Place categories:

`home`, `school`, `work`, `gym`, `restaurant`, `other`, `unknown`

Tasks:

- [ ] Request minimum necessary permission.
- [ ] Let the user define named locations.
- [ ] Convert coordinates into categories locally.
- [ ] Save category, arrival time, and departure time.
- [ ] Avoid long-term raw-coordinate storage by default.
- [ ] Measure battery impact.

## 13. Feature Engineering

Five-minute feature row:

```text
timestamp_utc
glucose
glucose_delta_5m
glucose_slope_15m
glucose_mean_30m
glucose_std_30m
basal_rate
bolus_last_30m
estimated_iob
carbs_last_2h
estimated_cob
steps_last_30m
heart_rate
workout_active
sleep_hours_last_night
place_category
calendar_category
hour_sin
hour_cos
weekday
missingness_flags
```

Rules:

- Use only information available at prediction time.
- Never backfill with future information.
- Carry values forward only when justified.
- Represent missing values and missingness separately.
- Version the feature schema.
- Reproduce identical transformations in Python and Swift.

## 14. Forecast Model

Targets:

- glucose at 30 minutes
- glucose at 60 minutes
- hypoglycemia within 60 minutes

Required experiments:

| Experiment | Inputs |
|---|---|
| A | CGM only |
| B | CGM + insulin |
| C | CGM + insulin + meals |
| D | CGM + insulin + meals + lifestyle context |

Required baselines:

- persistence
- Ridge or regularized linear regression
- one additional model if Core ML export is reliable

Use chronological splitting: earliest 70% training, next 15% validation, latest 15% test. Do not randomly shuffle adjacent CGM samples.

Metrics:

- MAE and RMSE at 30 and 60 minutes
- improvement over persistence
- hypoglycemia sensitivity and specificity
- warning lead time
- Clarke or Parkes error grid
- performance around meals, exercise, sleep, and overnight periods

Core ML tasks:

- [ ] Freeze feature order.
- [ ] Export preprocessing constants.
- [ ] Convert the selected model.
- [ ] Add model and schema versions.
- [ ] Validate Python/iOS numerical parity with fixed fixtures.

## 15. On-Device Forecasting

`ForecastService` must:

- load the bundled Core ML model;
- build the latest valid feature window;
- reject prediction when critical inputs are invalid;
- produce 30-minute and 60-minute forecasts;
- produce hypoglycemia risk and uncertainty;
- attach data-quality flags;
- save every forecast;
- match later CGM values with previous forecasts;
- calculate prospective error.

The forecast service must never output an insulin dose or send commands to a pump.

## 16. Local Assistant

Use Apple's on-device `SystemLanguageModel` when available.

Local tools:

- `GetCurrentGlucoseTool`
- `GetForecastTool`
- `GetRecentInsulinTool`
- `GetCurrentContextTool`

Rules:

- Every factual value must come from a typed tool.
- Distinguish measurements from predictions.
- State data age and uncertainty.
- Refuse to guess missing data.
- Do not recommend insulin doses.
- Do not describe associations as causal.

Check `SystemLanguageModel.default.availability`. If unavailable, use deterministic templates rather than failing.

## 17. Voice

Required:

- [ ] Text input
- [ ] Local response display
- [ ] `AVSpeechSynthesizer` output

Stretch:

- [ ] Speech framework transcription
- [ ] `AVAudioEngine` capture
- [ ] Interruption and Bluetooth-route testing

Do not port the current Opus/WebSocket pipeline unless all higher-priority work is complete.

## 18. Four-Week Schedule

### Week 1 — Remove the Mac runtime dependency

- [ ] Create the SwiftUI project and install it on the iPhone.
- [ ] Implement Keychain and Nightscout settings.
- [ ] Fetch CGM, treatments, and profile directly.
- [ ] Add SwiftData persistence.
- [ ] Build the Dashboard.
- [ ] Add loading, error, missing, and stale states.
- [ ] Test with the Mac off and Tailscale disabled.

Exit criterion: the iPhone displays real CGM and pump data over cellular while the Mac is off.

### Week 2 — Add lifestyle context

- [ ] Implement HealthKit.
- [ ] Implement EventKit and event categorization.
- [ ] Implement place definitions and low-power location updates.
- [ ] Build the Context screen.
- [ ] Implement the five-minute feature schema.
- [ ] Test all permission-denied states.

Exit criterion: the app creates a local timestamped record containing available glucose, insulin, activity, sleep, place, and calendar data.

### Week 3 — Train and deploy forecasting

- [ ] Build the aligned historical dataset.
- [ ] Generate a data-quality report.
- [ ] Train persistence, Ridge, and one additional model.
- [ ] Run experiments A–D.
- [ ] Evaluate chronologically.
- [ ] Export the selected model to Core ML.
- [ ] Validate Python/iOS parity.
- [ ] Save predictions for prospective evaluation.

Exit criterion: the iPhone produces 30-minute and 60-minute forecasts without contacting the Mac.

### Week 4 — Explanation and prospective validation

- [ ] Implement Foundation Models availability handling.
- [ ] Implement the four local tools.
- [ ] Add tool-backed explanations and deterministic fallbacks.
- [ ] Add local text-to-speech.
- [ ] Run shadow mode for 3–7 days where possible.
- [ ] Match forecasts with actual CGM readings.
- [ ] Measure error, latency, battery behavior, and failure cases.
- [ ] Test offline and unavailable-permission/model states.

Exit criterion: with the Mac off and Tailscale disabled, the app fetches Nightscout data, gathers context, forecasts locally, and safely explains the result.

## 19. Priorities

### P0 — Must complete

- Direct Nightscout access
- Keychain
- SwiftData
- CGM freshness validation
- HealthKit
- Feature construction
- Core ML forecast
- Forecast logging and actual matching
- Safe error behavior

### P1 — Should complete

- Calendar context
- Location category
- Foundation Model explanation
- Deterministic fallback
- Local TTS
- Offline cache behavior

### P2 — Stretch

- Speech input
- Widgets and Live Activity
- Cloud push for more reliable background updates
- On-device personalization
- Signed model downloads
- Custom local LLM

## 20. Test Plan

Connectivity:

- [ ] Mac powered off
- [ ] Tailscale disabled
- [ ] Cellular only
- [ ] Wi-Fi only
- [ ] Airplane mode with cached data
- [ ] Nightscout timeout, bad response, and authentication failure

Data quality:

- [ ] no CGM
- [ ] stale CGM
- [ ] duplicate and out-of-order records
- [ ] missing pump or meal data
- [ ] daylight-saving and timezone changes

Permissions:

- [ ] each permission allowed, denied, and later revoked

Model behavior:

- [ ] insufficient history
- [ ] Core ML loading failure
- [ ] feature-schema mismatch
- [ ] Foundation Model available, disabled, and not ready
- [ ] deterministic fallback

Safety:

- [ ] no fabricated glucose
- [ ] no stale value shown as current
- [ ] no insulin-dose recommendation
- [ ] no pump-control path
- [ ] prediction labeled experimental
- [ ] uncertainty displayed

## 21. Risks

| Risk | Mitigation |
|---|---|
| Nightscout is not publicly reachable | Resolve before Week 1 or use an authenticated cloud proxy |
| iOS does not wake every five minutes | Treat background refresh as best effort and refresh immediately in foreground |
| Context data is sparse | Report coverage and run ablation; do not hide negative results |
| Location drains battery | Use Visits, significant changes, and geofences |
| Foundation Model is unavailable | Use deterministic templates |
| Python and iOS model outputs differ | Require fixture-based parity tests |
| Closed-loop pump feedback confounds analysis | Describe the work as observational forecasting, not causal control |
| Scope expands toward pump control | Keep shadow mode and omit all control APIs |

## 22. Final Deliverables

- [ ] Native iOS source code
- [ ] Core ML forecast model
- [ ] Reproducible training and evaluation scripts
- [ ] Data dictionary and feature schema
- [ ] Offline metrics and ablation results
- [ ] Prospective shadow-mode results
- [ ] Architecture diagram
- [ ] Privacy, safety, and limitations documentation
- [ ] Short recording with the Mac and Tailscale disabled

## 23. Final Claim

> Joe demonstrates a standalone, context-aware iOS research prototype that directly accesses the user's Nightscout data, collects consented lifestyle context, produces personalized glucose forecasts on-device, and explains those forecasts without requiring a Mac mini or Tailscale at runtime.

Do not claim that the prototype safely controls insulin delivery or replaces the existing CGM, automated insulin delivery system, treatment plan, or clinical guidance.

## 24. References

- [Apple Core ML](https://developer.apple.com/documentation/coreml)
- [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [Configuring HealthKit access](https://developer.apple.com/documentation/Xcode/configuring-healthkit-access)
- [Apple EventKit](https://developer.apple.com/documentation/eventkit)
- [Apple Core Location](https://developer.apple.com/documentation/corelocation)
