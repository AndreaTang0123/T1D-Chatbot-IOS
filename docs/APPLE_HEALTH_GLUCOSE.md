# Apple Health glucose history

Joe can read up to 30 days of blood glucose visible in Apple Health. This is a
separate historical source: it never replaces Nightscout current glucose, feeds
forecasting, or merges with the Nightscout research training records.

## On iPhone

1. Enable blood glucose sharing to Apple Health in the Dexcom app.
2. In Joe → Settings → HealthKit, tap **Enable glucose history, steps, heart rate,
   sleep, and workouts**, and allow blood glucose reading. Existing installations
   must request authorization again to add the new data type.
3. In **Apple Health · Historical glucose**, select 7, 14, or 30 days and refresh.
4. Inspect source names, latest sample time, coverage and statistics. All visible
   HealthKit glucose sources are included; these are not necessarily exclusively
   Dexcom. Older Clarity records are not guaranteed to backfill.
5. Tap **Ask Joe about this history** and view the reply in Joe, or ask in chat,
   e.g. “总结最近两周血糖表现” or “Summarize my glucose history for the last week.”
   Explicit supported windows override the selected window. Load Gemma for generated
   explanations; otherwise a calculated local summary is provided.

Dexcom-to-Health sharing can lag about three hours. These values never establish
current glucose. Do not use this history for current alerts or treatment decisions.
Empty results may mean no data or denied read access; iOS does not disclose read
permission denial. Refresh errors clear the in-memory history rather than reuse
unlabeled cached observations.

## Calculation and privacy

- Convert HealthKit quantities to mg/dL; exclude nonfinite, future, out-of-window,
  or outside 20–600 mg/dL values. These limits are data screening, not targets.
- Deduplicate overlapping samples/sources into UTC five-minute bins, selecting
  the latest sample in each bin, with identifier as deterministic tie-breaker.
- Coverage is observed bins / expected bins across the full selected window;
  partial history and delayed uploads reduce coverage. Missing bins are excluded
  from glucose statistics, never treated as normal.
- Mean, population CV and below-70 / 70–180 / above-180 percentages use equal
  weight per observed bin. These are descriptive sample percentages, not validated
  clinical time-in-range or individualized treatment targets.
- Raw history is queried on launch/foreground/manual refresh and HealthKit change
  opportunities, held in memory, and re-read before history chat requests. iOS
  controls background delivery. Pausing HealthKit clears history on refresh;
  clearing local data also clears memory and pauses collection.
- No new raw glucose database or export collection is created. Summaries used in
  conversation are stored in existing local chat/research logs and included in
  explicit research exports. Gemma generation remains on device.

## Device acceptance (requires full Xcode and iPhone)

- Build and install; enable/deny/revoke glucose access and check empty/error states.
- Verify known Apple Health readings and source names, including mmol/L conversion.
- Verify 7/14/30-day windows and recent reading time against Apple Health.
- Repeat refresh, foreground entry, pausing, and clearing while a query is pending.
- With no Nightscout configured, ask history questions both with Gemma loaded and
  unloaded; confirm a useful historical response and no invented current reading.
- Check English/Mandarin, dose-request refusal, unknown data and offline queries.
- Confirm current-glucose/forecast screens do not show Apple Health history as live.

Command-line core tests can run without Xcode via `python3 scripts/check_core.py`.
Full `swift test` includes GlucoseHistoryTests and requires Xcode/XCTest on macOS.
