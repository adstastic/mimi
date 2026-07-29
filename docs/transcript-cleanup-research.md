# Transcript cleanup research

## Bottom line

First-party evidence supports a layered design, not one “magic dictation model”:

1. ASR produces literal or lightly formatted text.
2. Narrow deterministic rules handle safe mechanical cleanup.
3. An optional language model rewrites prose when extra latency and semantic risk are acceptable.

Superwhisper explicitly documents stages 1 and 3; VoiceInk documents all three; TypeWhisper exposes the same split in an open implementation. Closed products advertise polished output, but usually do not disclose whether normal dictation uses decoder behavior, rules, a generative pass, or some combination.

**Recommendation for Mimi:** keep Apple’s live ASR generation and event cadence untouched; show each volatile result through the same conservative deterministic cleaner used on finalized text; paste only Apple’s finalized result after deterministic cleanup. Later, offer deadline-bounded on-device model cleanup for opt-in prose modes. Never put a language model on the default fast path.

### Evidence labels

- **Confirmed:** stated in first-party documentation, privacy material, official model card, or official source repository.
- **Vendor claim:** first-party performance/quality claim, not independent validation.
- **Unknown/inference:** first-party material does not disclose enough to confirm.

## Product findings

### Wispr Flow

- **Confirmed:** Smart Formatting performs punctuation, capitalization, list formatting, filler cleanup, app-aware spacing/casing, and Backtrack correction. Flow exposes “Undo AI edit” and describes disabled formatting as raw transcription, confirming post-ASR AI formatting but not its implementation ([Smart Formatting & Backtrack](https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack)).
- **Confirmed:** context may include active app, nearby textbox text, screen text/screenshot, conversation content, and coding identifiers. It is sent with dictation unless context is disabled/Privacy Mode applies ([Context Awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)). Transcription always runs in the cloud ([privacy controls](https://docs.wisprflow.ai/articles/4709791908-understanding-privacy-mode-and-cloud-sync)).
- **Unknown:** ASR engine, deterministic-versus-generative split, live-preview/final topology, and absolute latency. Treat polished-output and speed language as vendor claims, not architecture evidence.

### superwhisper

- **Confirmed:** every dictation has independently configurable voice-to-text and optional language-model post-processing stages; either can be local or cloud ([data-flow documentation](https://superwhisper.com/docs/security/sensitive-data.md)). Voice Mode skips AI; Message, Email, Note, Super, and Custom modes apply AI after transcription ([Modes](https://superwhisper.com/docs/modes/modes.md)).
- **Confirmed:** local ASR includes whisper.cpp Whisper and Parakeet; cloud options also exist ([Voice models](https://superwhisper.com/docs/models/voice.md)). Live preview currently requires Nova cloud ASR ([Realtime](https://superwhisper.com/docs/common-issues/realtime.md)).
- **Confirmed:** Super/Custom modes may use app text, selection, and clipboard context. Vocabulary and text replacements remain local. **Unknown:** exact rule-versus-model contribution and whether realtime preview is ever the polished final.

### MacWhisper / Whisper Transcription

- **Confirmed:** these are direct-download and App Store variants of one product family; system-wide dictation is direct-download-only ([version comparison](https://macwhisper.helpscoutdocs.com/article/40-macwhisper-whisper-transcription-difference)). Local Whisper and Parakeet are supported, and the product page says normal transcription can remain on device ([official listing](https://goodsnooze.gumroad.com/l/macwhisper)).
- **Confirmed:** dictation can run user-defined, app-specific ChatGPT prompts for grammar cleanup, translation, or expansion into email; the documented setup uses the user’s OpenAI API key ([Dictation](https://macwhisper.helpscoutdocs.com/article/14-how-to-use-the-dictation-feature)). Automatic filler removal is advertised, but its mechanism is undisclosed.
- **Unknown:** whether direct dictation has live partials, how finalization differs from preview, and whether listed local AI providers can run the documented dictation-cleanup path. File-transcription speed claims are not dictation latency evidence.

### VoiceInk

- **Confirmed:** transcription and enhancement models are separate. Default Dictation mode has no AI; other modes can clean, rewrite, or draft after transcription ([Modes](https://tryvoiceink.com/docs/modes), [model guidance](https://tryvoiceink.com/docs/recommended-models)). Parakeet, Whisper, and Apple Speech can run locally; Parakeet supports realtime output ([Local models](https://tryvoiceink.com/docs/local-models)).
- **Confirmed:** configured standalone fillers are removed before formatting/enhancement, and word replacements are deterministic, boundary-aware, ordered longest-first, and applied before AI ([Filler Words](https://tryvoiceink.com/docs/filler-words), [Word Replacements](https://tryvoiceink.com/docs/word-replacements)).
- **Confirmed:** optional context is selected text, clipboard, or locally OCR-extracted window text, sent only to the chosen enhancement provider ([Context Awareness](https://tryvoiceink.com/docs/context-awareness)). Local ASR is default; cloud ASR/enhancement is opt-in ([privacy policy](https://tryvoiceink.com/privacy)). **Unknown:** exact preview-to-final replacement behavior.

### Aqua Voice

- **Confirmed:** Aqua’s proprietary Avalon ASR supports Instant and Streaming modes ([Avalon guide](https://aquavoice.com/guide/how-to-use-avalon)); Aqua requires internet/cloud processing ([FAQ](https://aquavoice.com/info/faq)). Custom Instructions control email structure, locale, punctuation, and filler removal ([guide](https://aquavoice.com/guide/custom-intructions)). Optional Deep Context reads screen content.
- **Vendor claim:** startup under 50 ms and finished text about 450 ms after speech ends ([FAQ](https://aquavoice.com/info/faq)).
- **Unknown:** whether cleanup occurs inside Avalon decoding, in deterministic rules, or in a second generative pass; whether streamed text and committed text use the same pipeline. Privacy Mode affects retention, not locality ([privacy policy](https://aquavoice.com/info/privacy)).

### Willow Voice

- **Confirmed:** Willow advertises filler removal, punctuation, lists/paragraphs, mid-dictation correction, app-specific style matching, dictionary/shortcuts, and a separate Scribe mode that writes from intent rather than transcribing literally ([formatting guide](https://help.willowvoice.com/en/articles/13183983-voice-commands-and-automatic-formatting-guide), [style matching](https://help.willowvoice.com/en/articles/12864746-personalization-and-style-matching), [Scribe](https://help.willowvoice.com/en/articles/15043797-introduction-to-scribe-in-willow)).
- **Vendor claim:** homepage says text can appear in 200 ms and advertises offline mode ([homepage](https://willowvoice.com/)).
- **Conflict/unknown:** privacy documentation says Willow uses cloud AI and says on-device models cannot match it ([privacy article](https://help.willowvoice.com/en/articles/12854269-how-willow-protects-your-data-and-privacy)). ASR engine, default local/cloud routing, live/final topology, and deterministic/generative split are undisclosed.

### TypeWhisper

- **Confirmed:** official open repository separates ASR from reusable AI workflows. It offers local and cloud engines, app-aware insertion, dictionary correction/learning, number normalization, and local Gemma processing through MLX; live preview is documented for WhisperKit ([official README](https://github.com/TypeWhisper/typewhisper-mac/blob/main/README.md)).
- **Confirmed:** workflows can transform, rewrite, or format output by app/site; local model loading has explicit memory and unload controls. This is strong evidence for mixed deterministic-plus-generative cleanup.
- **Unknown:** no single canonical default polished pipeline or absolute latency is documented; behavior depends on chosen engine/workflow.

### Extra open/local comparator: OpenWhispr

- **Confirmed:** OpenWhispr supports system-wide dictation with local Whisper/Parakeet or cloud ASR. Its AI agent is a separate path, explicitly described as having “no cleanup pass” ([official repository](https://github.com/OpenWhispr/openwhispr/blob/main/README.md)). It therefore demonstrates local ASR and local AI availability, not a documented default polishing architecture.

## Lowest-latency fully local Mimi architecture

### Current seam

Mimi enables Apple `.volatileResults` and `.fastResults`, forwards both partial and final events to the live overlay, then calls `finishAppleStream()` for normal Apple streaming or batch-transcribes voiceprint-filtered audio. Final text is trimmed, recorded, and inserted with no cleanup stage ([stream setup](https://github.com/adstastic/mimi/blob/d9e7bcdf251601840405b0d204e59fb6ba076187/Sources/MimiSpeech/AppleSpeechTranscriberBackend.swift#L93-L147), [preview events](https://github.com/adstastic/mimi/blob/d9e7bcdf251601840405b0d204e59fb6ba076187/Sources/Mimi/DictationController.swift#L545-L581), [final insertion](https://github.com/adstastic/mimi/blob/d9e7bcdf251601840405b0d204e59fb6ba076187/Sources/Mimi/DictationController.swift#L344-L383)).

Apple says volatile results arrive quickly, are tentative, and are replaced by better finalized results; `finalize` ensures volatile content is finalized. SpeechTranscriber is on-device, low-latency, and outside the app’s memory space ([WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/)). Therefore:

1. **Do not paste the last preview.** That sacrifices Apple’s final accuracy.
2. **Use one pure deterministic cleaner for preview and final.** This makes cleanup policy consistent, not text byte-identical: Apple may legitimately revise words between volatile and final.
3. **Do not feed cleaned preview back into ASR or delay partial delivery.** Display a cleaned projection only.

### Default fast path

At each preview and at finalization, run whole-string O(n) cleanup:

- remove high-confidence standalone fillers by default: `um`, `uh`, `erm`;
- also remove standalone `ah`: Mimi's reproducible fixture maps spoken “uh” to finalized “Ah,” so omitting it leaves the reported bug unfixed; quoted/metalinguistic uses remain protected;
- repair punctuation/whitespace immediately adjacent to removed fillers;
- preserve substrings (`Ummagumma`, `uh-huh`), quoted/metalinguistic uses, URLs, paths, flags, identifiers, and acronyms;
- do not default-remove `like`, `so`, `well`, `right`, or `you know` because they can carry meaning.

Run final cleanup before history/paste. Keep raw text ephemeral except opt-in diagnostics; persistent raw-plus-clean histories add privacy/storage scope without solving current cleanup. Do not add another ASR pass for cleanup.

### Optional polished-prose path

Foundation Models is available from macOS 26, subject to Apple Intelligence device/settings/model readiness; check `SystemLanguageModel.default.availability` at runtime ([Apple overview](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel#overview)). For an explicit prose mode only:

- prewarm at recording start when at least one second is expected; Apple says prewarm is only a request and may not load immediately ([prewarm](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm%28promptprefix%3A%29));
- wait behind a strict stop-to-paste deadline, then fall back to deterministic text;
- use guided generation for typed output shape, not trust: constrained sampling prevents malformed structure but does **not** guarantee semantic fidelity or calibrated confidence ([guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation));
- validate protected spans deterministically; never use model-supplied “confidence” as a gate;
- disable by default for code, terminal, commands, URLs, and short literal utterances; never mutate already-pasted text asynchronously.

**Local observation, not general benchmark:** on an M3 Max/128 GB/macOS 27 beta, one short cleanup prompt took 1.36 s cold and about 0.61 s warm/prewarmed. It failed to resolve one spoken correction; another sampled run dropped meaningful words. This is enough to reject mandatory LLM cleanup for Mimi’s fast path, not enough to characterize Foundation Models generally.

## Minimal validation plan

1. Reproduce fixtures through Apple streaming and voiceprint batch paths.
2. Test start/middle/end fillers, punctuation/capitalization, empty output, substrings, quoted fillers, technical tokens, and preview/final **policy** consistency.
3. Instrument first-partial, Apple-finalization, deterministic-cleanup, optional-model, and paste latency separately; compare cold/warm p50/p95.
4. For optional model output, fail closed to deterministic text on timeout, protected-span change, empty output, or validation error.

## Draft claims removed or corrected

- Removed unverified exact ASR providers/topologies and internal latency budgets for Wispr, Aqua, and Willow.
- Removed broad claim that polished products generally use deterministic plus generative cleanup; only some products document that split.
- Corrected Foundation Models from “macOS 27-only” to macOS 26+ with runtime eligibility.
- Removed implication that guided generation guarantees semantic preservation or useful confidence.
- Rejected persistent raw/diff storage as default and rejected pasting last preview.
- Removed speculative confidence-triggered second ASR and unsupported cleanup details/competitor memory figures.
- Omitted extra tools from draft whose cleanup mechanism lacked adequate first-party evidence.
