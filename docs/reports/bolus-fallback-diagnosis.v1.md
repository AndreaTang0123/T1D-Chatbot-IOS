# Bolus fallback diagnosis — 2026-11-12

Scope: diagnosis of the two supplied screenshots, using current source and a synthetic executable linked against the production JoeCore package. No real Nightscout credentials or device health database were read. App behavior was not changed during this diagnosis.

## Observed paths

- First phone reply is `Local fallback · modelNotReady`. `AssistantService.availability` returns this when a verified model file is installed but `isLoaded` is false, including loading/error/unloaded states. `JoeMobileApp` currently unloads on background entry and `prewarm` does nothing. Automatic loading has been discussed but is not implemented in the inspected worktree. The screenshot does not establish whether this particular turn followed background entry, manual unloading, loading in progress, or a failed load.
- Second phone reply is `Local fallback · Response rejected` with `unsupported_number`. That path requires a generated model reply and validation failure. It is distinct from a missing/unloaded model and from speech playback warnings.
- The displayed fallback is app-authored; it is not the rejected model wording. The rejected wording is not persisted, so the precise offending number in the actual turn cannot be recovered from these screenshots.

## Reproduced validator defects

The synthetic snapshot has a visible 0.3 U bolus at `2026-11-12T01:27:00Z`, query time `2026-11-12T15:51:59Z`, and computed age 864 minutes. CGM is fresh so normal generation is permitted. Evidence is insulin only.

| Controlled reply | At query time | After 2 seconds |
|---|---|---|
| Last visible bolus 0.3 U, 864 minutes ago; IOB unavailable | Accepted | `unsupported_number` |
| Same bolus at 20:27 (the correct previous-day America/New_York clock time) | `unsupported_number` | `unsupported_number` |
| Same bolus 14 hours and 24 minutes ago | `unsupported_number` | `unsupported_number` |
| Fabricated 5 U, 864 minutes ago | `unsupported_number` | `unsupported_number` |

A synthetic provider delayed by two seconds reproduced the actual coordinator path: `Local fallback · Response rejected`, reason `unsupported_number`, despite returning the initially supported 0.3 U / 864-minute values. A provider reporting `modelNotReady` reproduced the other displayed mode.

Cause: the coordinator rechecks the snapshot after generation and passes the newer snapshot to the validator. The insulin numeric whitelist contains only dose, basal rate and the *new* age in minutes, not the exact numeric evidence seen at generation time or a typed/preformatted clock time. Crossing an integer-minute boundary rejects a valid earlier age. Date/time components and alternate duration units are also not recognized semantically. None of this proves which wording the actual model generated; a genuinely fabricated number remains possible.

## Data freshness and logs

864 minutes is 14 hours 24 minutes. The insulin record is marked stale after six hours by current policy. It means this is the latest visible stored bolus, not proof no later insulin was delivered; the screenshots do not establish source sync completeness. IOB is unavailable by design.

The console includes UIKit keyboard diagnostics, native mel-filterbank warnings, and AVAudioSession/AVAudioBuffer warnings. These messages are not the coordinator's availability/numeric-validation triggers. The audio-session warning is consistent with synchronous `setActive` calls in main-actor speech services and deserves separate performance/audio testing; screenshots alone do not establish a crash, memory kill, or audio failure. `unsafeForcedSync` has no stack trace here, so its exact caller is not established.

## Recommended repair boundaries

- Separate model load lifecycle handling from generation validation; add on-demand loading if requested, with explicit error/loading states.
- Preserve exactly executed tool evidence for factual-number checks; recheck freshness/safety separately after generation. Do not simply broaden numeric tolerance, especially for insulin amounts.
- Supply explicitly formatted bolus date/time, timezone and age reference time from Swift, then validate their semantics. Distinguish permissible timestamp components from dose values.
- Improve fallback wording for a historical timestamp question so it gives the absolute visible bolus time and source freshness, without implying complete pump coverage.

Evidence: the temporary diagnostic executable in `/tmp/Joe-bolus-diagnosis` completed successfully; results are in `/tmp/Joe-bolus-diagnosis.log`. This is a controlled core/coordinator reproduction, not a real iPhone or clinical validation.

## Subsequent repair

The following implementation now returns the executed fact snapshot, validates it immutably, and performs freshness/safety as a separate gate. Model-facing bolus/CGM age fields are replaced by preformatted local timestamps; outputs use absolute event times. New regressions prove correct local-time replies survive the 864→865-minute boundary while genuinely stale CGM/context/calendar results still trigger post-generation expiry. This preserves the original diagnosis above as a historical record of the earlier code.
