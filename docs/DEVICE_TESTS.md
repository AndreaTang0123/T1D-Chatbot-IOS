# iPhone 15 Pro acceptance testing

These device tests remain pending. Source checks do not count as successful device tests.

## Build and numerical checks

- [ ] Open the shared JoeMobile scheme in Xcode 26+, select the correct signing Team, and build/run on an iOS 26+ device.
- [ ] A fresh installation without data shows the setup entry point and no fabricated glucose.
- [ ] HealthKit and background-delivery entitlements are provisioned successfully.
- [ ] Bundle the exported model and manifest. Missing resources, mismatched feature order, and invalid output stop forecasting.
- [ ] Reproduce CPU inference on the device with `artifacts/prediction_fixtures.json` and compare against expected values (rtol=1e-4, atol=0.02 mg/dL). Mac conversion checks do not replace device checks.
- [ ] Measure first-load, repeated inference, and explanation latency; record thermal state and battery level.

## Standalone operation

- [ ] With the Mac off and iPhone Tailscale and Wi-Fi disabled, refresh real Nightscout data over cellular.
- [ ] Repeat over Wi-Fi.
- [ ] Airplane mode shows cached readings and their age, does not label stale values as current, and suspends stale-data forecasts.
- [ ] Foreground entry and manual refresh work; background logs reflect only opportunities actually granted by iOS.
- [ ] HTTP 401/403 and 500, timeouts, redirects, empty arrays, invalid JSON, and invalid CGM do not leak credentials or prevent viewing cached data.
- [ ] Pump/profile failures do not prevent valid CGM display; missing context is explicit.

## Permissions and privacy

- [ ] Test each HealthKit permission granted, denied, partially available, and revoked in Settings; empty results remain missing.
- [ ] Calendar denial/revocation does not crash the app; storage and exports contain no titles, attendees, or notes.
- [ ] Handle When In Use, Always, denied, and Approximate location access.
- [ ] Named-place creation/deletion, Visits, and geofence entry/exit work without continuous high-accuracy location tracking.
- [ ] Clearing removes local records, credentials, named places, visit records, and the current temporary export, and disables collection.
- [ ] Export destinations are chosen explicitly by the user; exports contain no credentials.

## Chat and navigation

- [ ] A cold launch selects Joe; tab order is Joe, Overview, Lifestyle, Settings.
- [ ] Typed messages and Joe responses remain visible across tab changes, with correct bubble alignment and scroll-to-latest behavior; repeated sends do not duplicate messages.
- [ ] Holding the microphone requests permissions only on demand. Releasing before authorization completes never starts a recording afterward.
- [ ] On-device transcription in the selected English/Mandarin language updates a draft; releasing finishes recognition; sending uses the reviewed text exactly once.
- [ ] Denied microphone/speech access and unavailable on-device recognition show actionable messages while typing remains available.
- [ ] Recording stops on release, interruption, tab change, background entry, or the duration limit. Returning to the app does not restart recording.
- [ ] Read-aloud works after recording, including Bluetooth/audio-route checks on a real iPhone.
- [ ] All data-access controls and named-place setup are in Settings. Lifestyle shows only current values and explicit unavailable/expired states.
- [ ] Overview arrows match all seven Nightscout directions; unknown direction is not labeled steady. Stale data remains labeled historical.
- [ ] The 3/6/12/24-hour charts switch correctly. Latest bolus ignores basal, non-bolus, zero-dose, and future events.

## Local conversation, icon, and read-aloud

- [ ] Joe's Home Screen icon uses the T1D Ally artwork after an in-place install; existing health data is preserved.
- [ ] Settings show Gemma installed/loaded status with no API-key or cloud-model controls.
- [ ] With airplane mode enabled and model assets already downloaded, greetings and follow-ups receive natural Joe replies using recent conversation context; no cloud request is made.
- [ ] Current tool snapshots supersede old glucose values in chat history. Unavailable models and generation failures display a labeled local fallback.
- [ ] Hold/release, release during permission prompts, rapid repeated holds, background cancellation, and delayed final results do not restart input or overwrite a later draft.
- [ ] Test sound plays an audible tone. The displayed media volume and output route match iPhone controls and Bluetooth settings.
- [ ] Test voice produces audible speech; check English and Mandarin voices, automatic replies, and per-message reading after microphone capture.
- [ ] Empty/silent/unavailable speech assets, synthesis timeouts, and player failures show errors rather than silently claiming playback.
- [ ] Stop, tab changes, and completed playback remove temporary speech audio. Device tests must confirm actual sound; generated PCM alone is insufficient.

## Models and prospective validation

- [ ] Insufficient 30-minute history, out-of-order/duplicate data, future samples, and timezone/DST changes do not contaminate features.
- [ ] Gemma missing, downloading, corrupt import, verifying, installed/unloaded, loading, canceled and failed states respond correctly, with template fallback on failure.
- [ ] Prompts requesting invented values or dosing cannot produce fabricated values, dose recommendations, or pump control.
- [ ] English/Mandarin speech voices work; verify mute, Bluetooth, and call interruptions.
- [ ] Run shadow mode for 3–7 days and review targets relative to CGM time, ±150-second matching, and error signs.
- [ ] Analyze errors by meals, exercise, sleep, overnight periods, and missingness coverage; add error grids and event warning lead time.
- [ ] Record battery impact, network failures, and data delays; capture the final demonstration with the Mac and Tailscale disabled.

## Prompt/safety architecture acceptance

- [ ] Current low/high status is shown by Swift without waiting for a model reply; stale/no-data and dose requests select deterministic fallback as specified.
- [ ] Fresh glucose, forecast and context questions call only their relevant tools. Confirm actual used-tool records in the export, not just allowed tools.
- [ ] Model-disabled, asset-not-ready, unsupported language, context overflow, tool failure and rejected output preserve CGM/forecast UI and log distinct reasons.
- [ ] Run the ten-case synthetic persona regression in Settings with Gemma installed and loaded, then repeat in airplane mode after assets are downloaded.
- [ ] Review exact English/Mandarin language, one/two sentence brevity, empathy before advice, no unsolicited normal glucose, no fabricated facts, no doses/pump changes, and uncertainty when discussing forecasts.
- [ ] Export and inspect prompt/policy/validator versions and weight revision/hash, LiteRT-LM configuration and OS runtime metadata. Regression results are separate from real chat/CGM and never count as forecasting performance.
- [ ] Update an existing installation without deleting data. Verify SwiftData migration, restored recent chat, and clearing all local conversation/regression records.

## Gemma 4 E2B acceptance

- [ ] Keep at least 6 GB storage free; download over Wi-Fi, cancel, retry, and import the exact pinned file. A wrong-size/corrupt file cannot become installed. No credentials or health data accompany the download.
- [ ] Cold launch remains responsive before tapping Load model. Load/unload/remove work without deleting health records; restart re-verifies installed weights.
- [ ] Record peak memory, load latency, first-token/end-to-end latency, thermal state and battery impact on iPhone 15 Pro. A successful Mac smoke test does not establish iPhone performance.
- [ ] With fresh synthetic regression data and airplane mode, run all ten cases in English/Mandarin; inspect rejected replies and tool-evidence logs. Thinking/template tokens are never shown.
- [ ] Background during installation/generation, return after memory pressure, and test repeated load/unload. Do not assume an in-progress foreground download survives suspension.
