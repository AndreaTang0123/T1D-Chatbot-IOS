# Prompt and model architecture implementation

This implements the sibling browser repository's `IOS_JOE_PROMPT_AND_MODEL_ARCHITECTURE.md` in the standalone iOS repository. The original plan and browser implementation are unchanged.

| Plan area | Implementation |
|---|---|
| Responsibility boundaries | Core ML owns forecast numbers; Swift owns data quality, safety decisions, routing and validation; Apple Foundation Models owns wording/persona |
| Prompt migration | `JoeInstructions` separates versioned persona, safety, and explanation text; the combined instructions contain no current readings, history, or numerical safety thresholds |
| Safety decision | `SafetyDecisionEngine` evaluates unavailable → stale → low → high → configured forecast risk → normal using `SafetyPolicy` |
| Before-model fallback | No CGM, stale current-glucose questions, current low/high, forecast risk, and dose requests use deterministic responses; no generation is requested |
| Availability/errors | Disabled intelligence, unsupported device/language, assets not ready, context overflow, tool failure, refusal, guardrail failure and generic generation errors are distinguished where the SDK exposes them |
| Structured tools | Four typed `Codable` result structs are wrapped as structured `PromptRepresentable` JSON; output includes freshness, null/absent values, source times, and applicable model/schema metadata |
| Tool selection | Intent-based English/Mandarin routing registers only relevant tools; conversational sharing does not open every tool |
| Tool evidence | A per-turn ledger tracks actual calls, not merely registered tools. Generated data claims must be supported by tools actually used |
| Coordinator | `AssistantCoordinator` owns deterministic gating, availability checks, one generation attempt, response screening and immediate fallback. Rejected responses are never sent for model self-repair |
| Validation | Conservative English/Mandarin checks screen language, brevity, formatting, dose/pump advice, unsupported numbers/tool claims, prediction/current confusion, forecast uncertainty, stale/missing semantics, uncalibrated risk/IOB and causal assertions |
| Session lifecycle | The chat page prewarms static instructions. Each response uses a fresh short session with six bounded recent messages and up to two short older user-reported memory snippets; clinical/numerical material is excluded from older-memory summaries |
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

`foundationModelVersion` records `SystemLanguageModel.default` and the actual OS runtime version. Apple's iOS 26 API does not expose a stable model weight version, so the log explicitly says the weight version is not exposed. It does not invent a version.

Research exports now include conversations and safety logs. Regression records have a non-null `regressionCaseID`; they never enter CGM tables, forecast training data, normal chat restoration, or speech playback. Clearing local data removes the conversation logs too.

## Verification and limits

- 43 XCTest tests pass, including no-generation gating, priority ordering, stale/invalid data, typed summaries, tool routing/evidence, response screening, version serialization and the ten bilingual fallback fixtures.
- `docs/reports/persona-regression.v1.json` is the versioned deterministic fixture result. Its fake-provider runtime is explicitly labeled; it is not a live Foundation Model quality score.
- Settings → Persona regression runs the real model with an isolated synthetic reading. Export the research JSON to inspect outcomes, versions and rejection reasons; manually assess empathy, tone, brevity and usefulness. The run can be canceled and stops requesting cases on background entry.
- Model availability, generation, audio and UI still require iPhone acceptance testing, including airplane mode and permission revocation.

The validator is conservative heuristic screening, not a proof of factual or clinical correctness. It can reject acceptable paraphrases and cannot guarantee detection of every unsafe wording. Live adversarial/device regression and human review remain necessary. English and Mandarin are the regression-covered languages.

A personalized Core ML model, calibrated hypoglycemia probabilities and validated IOB/COB algorithms are separate data-dependent work. Missing scores remain missing; this implementation does not create clinical estimates to fill those gaps. Guided generation is optional in the plan and is not used for unrestricted final prose; final text is screened before display.
