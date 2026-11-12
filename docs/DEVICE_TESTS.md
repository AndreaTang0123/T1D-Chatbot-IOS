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
- [ ] Calendar denial/revocation does not crash the app; lifestyle records contain categories only. Explicit day-query titles can appear in chat/export; notes and attendees remain excluded.
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

## Permission collection switches

- [ ] Settings uses switches for Apple Health collection, calendar categories, foreground location and optional background visits/geofences.
- [ ] Enabling a switch requests the relevant iOS authorization when needed. Calendar/location denial leaves the effective switch off and offers a system-settings link; Health read denial remains undisclosed by iOS and is not claimed as granted.
- [ ] Health/calendar switches cannot be changed while their authorization request is pending. Changes remain visible after reopening Settings.
- [ ] Turning collection off stops the relevant observers/monitoring without deleting records or claiming to revoke iOS permission. Turning background location off stops Visits, significant changes and region monitoring while retaining foreground collection.
- [ ] When Always location permission is already granted, background collection still requires its own enabled switch; saving a named place does not restart disabled monitoring.

## Explicit today-calendar lists

- [ ] Ask “What is on my calendar today?” / “今天日历有什么安排？”; compare the title/time list with iPhone Calendar. Verify earlier-today, all-day, overnight and recurring occurrences, local midnight/DST boundaries, and canceled-event exclusion.
- [ ] With Gemma unloaded and no CGM, the local fallback list still works; with Gemma loaded, verify the event list actually enters the context tool and a screened model response is displayed.
- [ ] Disabled collection, missing full authorization, unavailable query and empty local results have distinct messages. EventKit's synchronous event query has no error callback: empty local results cannot establish remote account sync completeness.
- [ ] Requested titles appear in saved chat and explicit exports, and in the requested local-model context/recent replay, but not lifestyle/forecast records. Review UI privacy text and clearing behavior.

## Calendar week ranges

- [ ] Default/calendar-this-week queries include Monday through Sunday in the device timezone, with range header and each event's date/time. Earlier days are not silently omitted.
- [ ] Explicit today/tomorrow queries use their own local day; next-week, specified/ambiguous dates request clarification instead of substituting this week.
- [ ] Verify Sunday and year crossover, DST, overnight/multiday/all-day events, and events exactly at the exclusive range end.
- [ ] Missing range headers, missing event dates and swapped event dates trigger full-range local fallback. Large model contexts never cause silent event truncation.
- [ ] Chinese “本周日历/本周日程” is interpreted as this week, not Sunday.

## Automatic Gemma lifecycle acceptance

- [ ] Cold launch stays responsive; sending an eligible message waits for file verification/loading, displays Loading Gemma, and then generates. A safety-only reply avoids an unnecessary load.
- [ ] Two simultaneous requests/manual preload share one initialization. Backgrounding during initialization does not leave a ready zombie engine.
- [ ] Brief app switching retains the model; idle expiry releases after 5 minutes foreground / 2 minutes background, with elapsed-time recheck after suspension. Active generation cannot be unloaded by the idle timer.
- [ ] Memory warnings cancel model work and release the engine. Next eligible chat automatically reloads. Test on iPhone 15 Pro for actual memory pressure, latency and thermals.
- [ ] Manual unload followed by a new message reloads automatically; removing weights requires an explicit new download/import. Load errors show status and do not retry continuously.
- [ ] Persona regression automatically loads and retains one engine for the run, and cancels on background entry.
