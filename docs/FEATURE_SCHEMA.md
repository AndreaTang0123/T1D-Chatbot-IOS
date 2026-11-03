# joe.features.v1

All timestamps are UTC; conversion to local time is for display only. The latest CGM source timestamp is the forecast origin. The feature timestamp identifies its five-minute bucket, and the 30/60-minute targets are relative to the source timestamp. Forecast generation time and CGM time are distinct.

Model input consists of 19 values followed by 19 missingness flags in the same order (1 means missing). Missing values use a zero placeholder that must always be interpreted with its flag. `FeatureRow.names` and `features.INPUT_NAMES` define the order.

| Index | Field | Definition / units |
|---|---|---|
| 0 | glucose | Latest valid CGM, mg/dL |
| 1 | delta_5m | Current glucose minus glucose five minutes earlier, mg/dL |
| 2 | slope_15m | Current glucose minus glucose 15 minutes earlier, divided by 15; mg/dL/min |
| 3–4 | mean_30m / std_30m | Mean and population standard deviation of seven five-minute points |
| 5 | basal_rate | Most recent Temp Basal absolute rate still within its duration; U/h; actual delivery is not inferred from the profile |
| 6 | bolus_30m | Sum of visible insulin events in the last 30 minutes; missing when no events are visible |
| 7 | estimated_iob | Always missing in this version, pending a validated insulin action model |
| 8 | carbs_2h | Sum of visible carbohydrate events in the last two hours, g; missing when no events are visible |
| 9 | estimated_cob | Always missing in this version |
| 10 | steps_30m | HealthKit 30-minute statistics using system source merging |
| 11 | heart_rate | Most recent visible heart rate within 15 minutes, bpm |
| 12 | workout_active | When a workout is visible within the last two hours, indicates whether it ended within five minutes before the cutoff; missing without records; an approximate feature |
| 13 | sleep_hours | Hours in the latest sleep episode within 36 hours; overlapping intervals are merged and gaps over three hours separate episodes |
| 14 | place | unknown=0, home=1, school=2, work=3, gym=4, restaurant=5, other=6 |
| 15 | calendar | other=0, class=1, meeting=2, meal=3, travel=4, medical=5, exercise=6; missing without a visible event |
| 16–17 | hour_sin / hour_cos | Sine and cosine of UTC seconds since midnight divided by 86400 and multiplied by 2π |
| 18 | weekday | UTC weekday; Monday=0, Sunday=6 |

The CGM grid permits carry-forward only from at most 150 seconds earlier. A missing value at any of the seven grid points blocks forecasting. Forecasting also stops when the latest sample exceeds the configured stale threshold (15 minutes by default). Context must be no later than the CGM source timestamp and no more than 15 minutes old.

Incomplete treatment records, sync failures, and upload delays can affect event coverage. The offline dataset replays source times and cannot fully reconstruct historical Nightscout upload times or HealthKit arrival times. Treat offline results as retrospective analysis and use shadow-mode logs to assess actual runtime performance. Do not describe this replay as validated real-time availability.

Raw profile responses are stored locally for research review, but profile schedules, DIA, and units are not yet parsed. Basal delivery and IOB/COB are therefore not inferred from profiles. Nightscout must provide `sgv` in mg/dL; mmol/L input conversion is not implemented.

Actual-value matching selects the nearest valid CGM reading within ±150 seconds of the target time. Evaluation waits until the entire matching window has elapsed. Error = forecast − measurement. Unmatched actual values remain missing, with no interpolation or zero filling.

The model returns two ordered mg/dL values: 30-minute and 60-minute forecasts. Validation P90 absolute residuals are fixed uncertainty summaries, not calibrated individual prediction intervals. Hypoglycemia probability is currently nil.
