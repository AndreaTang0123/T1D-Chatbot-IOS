# Gemma 4 E2B setup and customization

Joe now uses only local Gemma 4 E2B for generative conversation. Apple Intelligence and the old browser server are not providers. Nightscout sync and system speech remain separate services.

## Install on iPhone

1. On the development Mac install Git LFS (`brew install git-lfs`), then open `ios/JoeMobile.xcodeproj`. Xcode resolves LiteRT-LM **0.19.1**. Only its `LiteRTLM` product is linked; the Apple Foundation Models adapter is not linked. Apple Silicon simulators are supported; the supplied binary has no Intel simulator slice.
2. Choose the existing signing team, physical iPhone destination and Run. Keep the same bundle ID to preserve local records. No model is bundled in the app or committed to Git.
3. Open **Settings → Gemma 4 E2B → Download model over Wi-Fi**. Allow at least **6 GB** free storage for staging and caches. The model download is **2,588,147,712 bytes** (2.59 GB decimal). Keep Joe open; a suspended/failed transfer can be retried, but partial downloads are not resumed.
4. Wait for size/SHA-256 verification, then tap **Load model**. Initialization is explicit, away from the main actor, and not part of app startup. Loading can require substantial RAM; close other apps if needed. A loaded engine stays in memory until unloaded, backgrounded or the process ends.
5. Return to Joe. Model unavailability/errors select a labeled local fallback. Existing Swift rules also bypass generation for missing CGM, stale current-glucose questions, current low/high readings and dose requests. Install and load the model before running Settings → Persona regression with synthetic data.
6. To free RAM use **Unload model**. **Remove model file** removes weights/runtime caches while retaining health records and chat logs. Health-data clearing is a separate control.

The alternative import path accepts only the exact file below. Download it to Files and choose **Import supported .litertlm file**; the app copies and verifies it before use. GPU-only, MediaPipe `.task`, GGUF and other quantizations are incompatible with this pinned configuration.

| Item | Pinned value |
|---|---|
| Repository | `litert-community/gemma-4-E2B-it-litert-lm` |
| Revision | `3d48132a00cf76de57d926de30f5c5c5ed9b8c0d` |
| Filename | `gemma-4-E2B-it.litertlm` |
| SHA-256 | `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c` |
| Runtime | LiteRT-LM 0.19.1, CPU, four threads, 4096-token context |
| Sampling | top-k 40, top-p 0.9, temperature 0.3; 220 output tokens; thinking disabled |

[Exact model download](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/3d48132a00cf76de57d926de30f5c5c5ed9b8c0d/gemma-4-E2B-it.litertlm), [model card/license](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm), [pinned runtime source](https://github.com/google-ai-edge/LiteRT-LM/tree/v0.19.1), [Google Swift runtime documentation](https://developers.google.com/edge/litert-lm/swift).

## Preserve and change Joe customization

- Edit `Sources/JoeCore/JoeInstructions.swift` for the browser-inspired companion persona, safety and explanation instructions. Bump the corresponding `PromptVersions` string when changing them. These static instructions become the LiteRT-LM system message, with the static Gemma adapter guidance from `GemmaPromptBuilder`.
- `ConversationMemory` supplies bounded recent conversation and nonclinical older user-reported snippets. Current health/context facts are never interpolated into system instructions.
- `QuestionIntent` selects relevant local tools. `GemmaPromptBuilder` executes the selected typed result encodings and puts nested JSON in `localToolResults`; `usedTools` reflects these executions. This is deterministic prefetch, not model-selected native function calling.
- Core ML still owns glucose forecasts. Swift owns freshness, safety decisions, dose-request rejection, evidence checks and fallback. Gemma supplies final wording; it never calculates doses, IOB/COB or forecasts.
- Review Settings → Persona regression and research exports after prompt changes. The historical export field `foundationModelVersion` now contains the exact Gemma/runtime identity; existing records remain readable.

This is prompt/context/orchestration customization, not weight fine-tuning. Browser-specific LoRA weights, training checkpoints, cloud tools and hidden server state are not imported. The model file is read-only; changing it requires a new pinned specification, matching conversion/runtime checks and new device acceptance tests.

## Verification boundary

48 XCTest tests pass, including file-size/hash rejection, selected-tool payloads and existing safety/persona tests. Unsigned device and Apple Silicon simulator builds pass with Xcode 27.2; the updated app launches in the iOS 27.2 simulator with Joe selected and the Gemma header visible. A Mac CPU smoke test verifies the actual downloaded artifact and runs the same production runtime actor against synthetic conversation; this establishes native loading/generation, not iPhone performance or clinical safety. iPhone 15 Pro memory, latency, thermals, audible speech and offline acceptance remain device checks.

The [recorded Mac smoke run](reports/gemma-mac-smoke.v1.json) exercised all ten persona cases with synthetic CGM: nine replies passed screening and one used a rejection fallback. The first exploratory run exposed a Chinese unit substitution; the adapter now requires literal `mg/dL`, and validator v2 rejects unsupported glucose units. This is evidence for the tested paths, not a general safety claim.

Reproduce the actual runtime check on a Mac (downloads the pinned runtime if not already cached):

```sh
python3 scripts/check_gemma_runtime.py --model /absolute/path/gemma-4-E2B-it.litertlm --output /tmp/gemma-persona.json
```

The check extracts the production runtime actor, verifies the exact model, and runs synthetic cases through the core coordinator/validator. It never reads the app database. Use `--runtime-package /path/to/LiteRT-LM` only with a local v0.19.1 checkout. Backgrounding cancels an active generation and unloads weights; returning requires Load model again.

## Xcode reports missing package products

If both `LiteRTLM` and local `JoeCore` appear missing, inspect Report Navigator → Resolve Packages. A `Git LFS is not installed` error can occur even when `git-lfs --version` works in Terminal: Finder-launched Xcode may not inherit Homebrew's PATH. Quit Xcode completely, then double-click `scripts/open_xcode.command` (or run it in Terminal). This launcher starts Xcode with Homebrew on PATH without changing global settings. Resolve Package Versions and build again. Clearing package caches alone does not fix a missing executable in Xcode's environment.

## Direct-answer prompt revision

`joe.persona.v3`, `joe.safety.v2`, `joe.explanation.v2` and `joe.gemma-adapter.v4` distinguish ordinary suggestions from personal clinical claims. Direct questions receive concrete answers first; empathy is used when feelings are expressed rather than as a mandatory opening. General meal ideas do not require a health-data tool. Personal health claims still require evidence; the model must not prescribe food or timing changes as treatment for recurrent highs/lows. Examples demonstrate actual lunch suggestions, and repeated requests ask for additional detail/options. The existing concise-response limits and Swift safety gates remain unchanged.

The native smoke harness now includes the reported four-turn lunch conversation, preserving prior turns to exercise follow-up context. Unit checks alone cannot establish usefulness: inspect the actual replies and review on iPhone after an in-place Xcode update. Model weights do not change and need not be downloaded again.

Verification: 51 core XCTest tests pass. The [recorded direct-answer run](reports/direct-answer-prompts.v1.json) includes ten persona cases plus four consecutive lunch turns using actual Gemma CPU inference. All lunch turns supplied food options; the first follow-up still repeated the prior choices, while the final follow-up offered different choices. Prompts improve task completion but do not guarantee novelty, tone or factual/clinical safety.
