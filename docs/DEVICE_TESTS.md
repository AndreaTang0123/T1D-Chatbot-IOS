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
- [ ] On-device English transcription updates a draft; releasing finishes recognition; sending uses the reviewed text exactly once.
- [ ] Denied microphone/speech access and unavailable on-device recognition show actionable messages while typing remains available.
- [ ] Recording stops on release, interruption, tab change, background entry, or the duration limit. Returning to the app does not restart recording.
- [ ] Read-aloud works after recording, including Bluetooth/audio-route checks on a real iPhone.
- [ ] All data-access controls and named-place setup are in Settings. Lifestyle shows only current values and explicit unavailable/expired states.
- [ ] Overview arrows match all seven Nightscout directions; unknown direction is not labeled steady. Stale data remains labeled historical.
- [ ] The 3/6/12/24-hour charts switch correctly. Latest bolus ignores basal, non-bolus, zero-dose, and future events.

## Models and prospective validation

- [ ] Insufficient 30-minute history, out-of-order/duplicate data, future samples, and timezone/DST changes do not contaminate features.
- [ ] Apple Intelligence enabled, disabled, downloading, and unsupported region/language states respond correctly, with template fallback on failure.
- [ ] Prompts requesting invented values or dosing cannot produce fabricated values, dose recommendations, or pump control.
- [ ] Installed English speech voices work; verify mute, Bluetooth, and call interruptions.
- [ ] Run shadow mode for 3–7 days and review targets relative to CGM time, ±150-second matching, and error signs.
- [ ] Analyze errors by meals, exercise, sleep, overnight periods, and missingness coverage; add error grids and event warning lead time.
- [ ] Record battery impact, network failures, and data delays; capture the final demonstration with the Mac and Tailscale disabled.
