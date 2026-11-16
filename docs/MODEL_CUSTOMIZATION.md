# Joe model customization

Joe uses the pinned Gemma 4 E2B weights. Current customization is runtime instructions, selected local facts, bounded conversation history, generation settings and Swift validation; it is not weight fine-tuning or a LoRA adapter.

| File | Responsibility |
|---|---|
| `Sources/JoeCore/JoeInstructions.swift` | Joe persona, tone, safety/explanation instructions and bounded conversation memory |
| `Sources/JoeCore/GemmaModel.swift` | Pinned model/revision/checksum, Gemma adapter instructions, tool JSON, evidence projection and output budgets |
| `Sources/JoeCore/GemmaAudioQuestion.swift` | Isolated native-audio question prompt, language hint, capture duration and unusable-result screening; no persona or health facts |
| `ios/JoeMobile/Services/AssistantService.swift` | LiteRT-LM engine/audio backend, system-message injection, sampler, text/audio conversations, loading and cancellation |
| `Sources/JoeCore/SafetyDecisionEngine.swift` | Deterministic question intent, tool permissions and safety decisions |
| `Sources/JoeCore/AssistantSnapshot.swift` | Actual structured local facts supplied to the model |
| `Sources/JoeCore/AssistantCoordinator.swift` | Model/fallback orchestration and immutable evidence validation |
| `Sources/JoeCore/ResponseValidator.swift` | Numerical, time, calendar and other response checks |
| `Sources/JoeCore/ReplyFreshnessReview.swift` | Independent freshness checks after generation |
| `Sources/JoeCore/ExplanationFallback.swift` | Local responses when data, model or validation is unavailable |
| `Sources/JoeCore/AssistantReplyPresentation.swift` | Today/yesterday local date formatting and schema-label cleanup after checking |
| `ios/JoeMobile/App/AppState.swift` | Permission-gated source refresh, chat history and model lifecycle integration |
| `ios/JoeMobile/Services/SpeechService.swift` | Microphone WAV capture and existing local speech playback; no Apple Speech ASR |

For conversational tone start with JoeInstructions; for data access or inaccurate fact handling inspect the tool payload and validator rather than weakening the safety checks. Update prompt versions and regression fixtures when changing model behavior.

Native audio flow: microphone → temporary WAV → Gemma audio encoder and isolated question-understanding task → editable draft → Send → existing Joe fact-query/answer pipeline. Both model passes are local. The first pass does not answer the medical question or receive health facts. This review step lets the user correct numbers/units and lets Swift select tools before generating a grounded answer. Audio is not retained in chat/research logs or uploaded.

## Andrea's T1D Ally persona revision

Persona v5 integrates Andrea's supplied companion prompt: friend/teammate identity, language matching, plain text, brief answer-first conversation (25 English words / about 50 Chinese characters as the ordinary-chat generation target), concrete suggestions, non-judgmental tone, stable silence and avoiding repeated readings in supplied memory. Requested complete calendar/history results and app-authored safety responses are explicit length exceptions. These are prompt instructions, not a guarantee of a hard word count or full-session memory.

The supplied medical table is not a second source of clinical thresholds. Swift safety policy remains authoritative, including handling the gaps in that table. The prompt does not suggest an insulin correction at night, declare a post-meal rise harmless, suppress urgent responses due to a meal/repeated reading, or invent clock/activity/meal evidence. Existing deterministic safety wording is unchanged. This update changes conversational generation instructions, not clinical treatment protocols or autonomous session notifications.

## Apple Health activity evidence

`HealthActivity.swift` defines recognized step/HR queries, structured query status, today's local step window, and the latest dated heart-rate observation within a day. `HealthKitService.activity(at:)` reads merged cumulative steps and the most recent HR sample independently of the older causal forecast snapshot. `AppState.ask` refreshes this evidence on context questions; the existing context tool exposes it as healthActivity. `GemmaModel` supplies a direct-answer hint, and `ResponseValidator` requires requested available values and the HR measurement timestamp. Old samples are records, never real-time monitoring. Read permission is intentionally unknown to the app; successful authorization is not proof that any particular read type was allowed.

## Calendar interpretation and iCloud scope

For conversational calendar style edit JoeInstructions and the calendar hint in GemmaModel. CalendarReplyStyle.swift selects overview versus explicit full-list mode, supplies grounded highlights, and validates highlight time/date associations. CalendarService.swift filters EventKit source calendars before both explicit queries and lifestyle snapshots; source identification is conservative and based on public EventKit type/name metadata. Ordinary summaries may select highlights; only explicit all/full-list requests require every event. Interpretations are tentative impressions of recorded commitments, never evidence of mood or free time. Local factual fallback is still used on model/check failure.
