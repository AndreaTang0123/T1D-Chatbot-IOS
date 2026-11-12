# Prompt and model architecture implementation

This implements the sibling browser repository's `IOS_JOE_PROMPT_AND_MODEL_ARCHITECTURE.md` in the standalone iOS repository. The original plan and browser implementation are unchanged.

| Plan area | Implementation |
|---|---|
| Responsibility boundaries | Core ML owns forecast numbers; Swift owns data quality, safety decisions, routing and validation; Gemma 4 E2B owns wording/persona |
| Prompt migration | `JoeInstructions` separates versioned persona, safety, and explanation text; the combined instructions contain no current readings, history, or numerical safety thresholds |
| Safety decision | `SafetyDecisionEngine` evaluates unavailable → stale → low → high → configured forecast risk → normal using `SafetyPolicy` |
| Before-model fallback | No CGM, stale current-glucose questions, current low/high, forecast risk, and dose requests use deterministic responses; no generation is requested |
| Availability/errors | Missing or unloaded Gemma assets, tool preparation failures, cancellation and generic native generation failures trigger fallback; legacy availability/error codes remain decodable |
| Structured tools | Four typed `Codable` result structs are serialized as nested JSON objects; output includes freshness, null/absent values, source times, and applicable model/schema metadata |
| Tool selection | Intent-based English/Mandarin routing executes only relevant local tools before generation; conversational sharing does not open every tool |
| Tool evidence | A per-turn ledger tracks actual Swift tool-result serializations, not merely allowed tools. Generated data claims must be supported by tools actually used |
| Coordinator | `AssistantCoordinator` owns deterministic gating, availability checks, one generation attempt, response screening and immediate fallback. Rejected responses are never sent for model self-repair |
| Validation | Conservative English/Mandarin checks screen language, brevity, formatting, dose/pump advice, unsupported numbers/tool claims, prediction/current confusion, forecast uncertainty, stale/missing semantics, uncalibrated risk/IOB and causal assertions |
| Session lifecycle | Model loading is explicit in Settings; one engine is retained. Each response uses a fresh short conversation with six bounded recent messages and up to two short older user-reported memory snippets; clinical/numerical material is excluded from older-memory summaries |
| Persistence | Final replies and versioned research records are saved locally; recent non-regression messages restore on launch. Rejected raw model text is not retained or displayed |
| Persona regression | Ten bilingual cases from the plan are defined in `PersonaRegressionCase`; deterministic fixtures run in XCTest, and Settings exposes isolated on-device generation with versioned logs |

## Structured result details

- `CurrentGlucoseResult`: status, glucose, direction, age and source timestamp. Future or invalid readings are unavailable; stale readings retain historical semantics.
- `ForecastToolResult`: availability, source/generation times, predictions, validation uncertainty, data-quality flags, model and feature-schema versions. Risk is absent unless both a supplied score and explicit calibrated-risk policy are available.
- `RecentInsulinResult`: latest visible bolus, age/freshness, an active visible absolute temp basal if available, and explicit incomplete coverage. IOB remains unavailable.
- `CurrentContextResult`: semantic activity/sleep/place/calendar categories, heart rate, next-event category/minutes, and freshness. No raw coordinates, titles, notes or participants are exposed.

Tools use a consistent local snapshot for the turn and recheck time-based validity when called. The coordinator checks freshness again after generation before displaying the response. Tools do not contact Nightscout or command a pump.

## Logs and versions

Every stored `AssistantTurnRecord` includes persona/safety/explanation versions, the safety policy and its version, validator version, decision, availability, error/rejection reasons, allowed/used tool kinds, source CGM time, forecast model version, latency and optional regression case ID.

`foundationModelVersion` is retained as a historical schema key for export compatibility. New records contain the Gemma model ID, immutable weight revision, SHA-256, LiteRT-LM version, CPU/thread/context configuration and OS version. Legacy Apple availability codes remain solely for old records.

Research exports now include conversations and safety logs. Regression records have a non-null `regressionCaseID`; they never enter CGM tables, forecast training data, normal chat restoration, or speech playback. Clearing local data removes the conversation logs too.

## Verification and limits

- 48 XCTest tests pass, including no-generation gating, priority ordering, stale/invalid data, typed summaries, tool routing/evidence, response screening, version serialization and the ten bilingual fallback fixtures.
- `docs/reports/persona-regression.v1.json` is the versioned deterministic fixture result. Its fake-provider runtime is explicitly labeled; it is not a live Gemma quality score.
- Settings → Persona regression runs the real model with an isolated synthetic reading. Export the research JSON to inspect outcomes, versions and rejection reasons; manually assess empathy, tone, brevity and usefulness. The run can be canceled and stops requesting cases on background entry.
- Model availability, generation, audio and UI still require iPhone acceptance testing, including airplane mode and permission revocation.

The validator is conservative heuristic screening, not a proof of factual or clinical correctness. It can reject acceptable paraphrases and cannot guarantee detection of every unsafe wording. Live adversarial/device regression and human review remain necessary. English and Mandarin are the regression-covered languages.

A personalized Core ML model, calibrated hypoglycemia probabilities and validated IOB/COB algorithms are separate data-dependent work. Missing scores remain missing; this implementation does not create clinical estimates to fill those gaps. Guided generation is optional in the plan and is not used for unrestricted final prose; final text is screened before display.

## Gemma adaptation

The original plan's `LanguageModelSession` and Apple `Tool` APIs are replaced by LiteRT-LM `Engine`/`Conversation`. `JoeInstructions.combined` plus a static adapter section is the system message. Only final response contents are read; thinking is disabled and never displayed or logged. The output cap is 220 tokens, context is 4096 tokens, CPU uses four threads, and sampling uses top-k 40, top-p 0.9, temperature 0.3. Context overflow/native errors fall back; no cloud retry exists.

The four read-only tools are executed deterministically in Swift because the pinned runtime's native tool decoder recreates tool instances without the per-turn snapshot. `usedTools` records the results actually encoded. This preserves evidence gating without claiming autonomous function calls. The model file is installed outside the app bundle and excluded from backup; download/import must pass pinned size and SHA-256 checks. See [Gemma setup](GEMMA_SETUP.md).

## Explicit day-calendar queries

Calendar-only requests use EventKit's local-day interval. The transient `CalendarDayResult` contains titles, start/end timestamps, all-day markers and timezone; `calendarDisplay` provides preformatted local times so Gemma need not convert timezones. These fields enter the local context tool only for an explicit calendar request. Gemma answers using this list; event titles are untrusted data and cannot override instructions. The calendar path relaxes the two-sentence limit, checks title/time inclusion, unsupported numbers and promise-only replies, and uses the exact app-rendered list on rejection/error/model unavailability. It cannot prove semantic correctness or detect every invented nonnumeric claim.

No-CGM state does not block an otherwise available calendar-only query. Empty/unavailable/error states use app-authored messages. Titles can persist in chat, bounded model replay and explicit exports; lifestyle/forecast records remain categorical. Event notes, attendees and event locations are not passed. The synchronous EventKit query exposes no error callback; full-access checks bracket the fetch, and empty local results cannot establish remote-account completeness.
