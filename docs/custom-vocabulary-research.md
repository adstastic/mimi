# Custom vocabulary research

## Decision

Mimi v1 should treat custom vocabulary as a local, backend-independent canonicalization layer after ASR. Recognition hints may improve recall, but only deterministic correction can guarantee identical behavior, spelling, and casing for Apple and Parakeet output. Source data should be one canonical written form plus explicit spoken aliases; no model-specific fields belong in the v1 contract.

## 1. Product precedent: hints are not replacements

[Wispr Flow’s official dictionary documentation](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary) exposes two distinct behaviors: vocabulary words **boost** uncommon terms during transcription, while replacement rules swap a known wrong spelling for the desired spelling after dictation. Flow says replacement rules are more reliable when a term is consistently misrecognized, recommends entering singular and plural separately, limits a word to one replacement rule, and caps a vocabulary entry at 60 characters. These are recognition-probability and deterministic-output tools, not interchangeable implementations.

[Superwhisper documents the same split](https://superwhisper.com/docs/get-started/interface-vocabulary). Vocabulary words travel with audio as recognition hints and can affect punctuation, language detection, and formatting; too many or multilingual hints may reduce quality. Replacements run after transcription, programmatically rather than through AI. Matching is case-insensitive, configured output casing is exact, multiple observed variants may point to one output, and replacements behave consistently across voice models.

Product constraint: call recognition-time features **hints/boosting**, never “corrections.” They can raise target-term recall but do not promise exact orthography or absence of false insertions. Call spoken-form-to-written-form rules **replacements/canonicalization**; they provide deterministic output when a configured rendering appears.

## 2. Apple Speech APIs

Mimi currently constructs Apple’s general-purpose [`SpeechTranscriber`](https://developer.apple.com/documentation/speech/speechtranscriber), with empty transcription options, inside [`AppleSpeechTranscriberBackend.swift`](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Sources/MimiSpeech/AppleSpeechTranscriberBackend.swift#L246-L256). Its analyzers are created without an `AnalysisContext` ([batch](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Sources/MimiSpeech/AppleSpeechTranscriberBackend.swift#L74-L83), [streaming](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Sources/MimiSpeech/AppleSpeechTranscriberBackend.swift#L114-L124)).

### Legacy request API

[`SFSpeechRecognitionRequest.contextualStrings`](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/contextualstrings) is an array of short phrases that improves their likelihood of recognition. Apple recommends one or two words, something speakable without pausing, and no more than 100 phrases. It is a probabilistic hint list: no alias mapping, per-entry weight, or exact-output guarantee is documented. Apple’s availability metadata on that page starts at iOS/iPadOS/Mac Catalyst 10.0, macOS 10.15, and visionOS 1.0.

Compiled customization is separate. [`SFCustomLanguageModelData`](https://developer.apple.com/documentation/speech/sfcustomlanguagemodeldata) creates training data containing weighted phrase counts, templates, and custom pronunciations; [`SFSpeechLanguageModel.prepareCustomLanguageModel`](https://developer.apple.com/documentation/speech/sfspeechlanguagemodel/preparecustomlanguagemodel(for:configuration:completion:)) compiles it. [`SFSpeechLanguageModel.Configuration`](https://developer.apple.com/documentation/speech/sfspeechlanguagemodel/configuration) identifies compiled language-model and vocabulary files plus an optional weight, and an `SFSpeechRecognitionRequest` accepts it through [`customizedLanguageModel`](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/customizedlanguagemodel). The request/configuration APIs begin at iOS/iPadOS/Mac Catalyst 17, macOS 14, and visionOS 1; `SFCustomLanguageModelData` begins at visionOS 1.1, according to Apple’s symbol availability.

### SpeechAnalyzer-era API

[`AnalysisContext.contextualStrings`](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings), available from macOS/iOS 26, groups phrases by tag and retains the same brief-phrase and 100-total limits. Its documentation explicitly says “with the `DictationTranscriber` module.” A `SpeechAnalyzer` can hold or replace an [`AnalysisContext`](https://developer.apple.com/documentation/speech/speechanalyzer/setcontext(_:)), but Apple documents contextual-string consumption as a [`DictationTranscriber` accuracy feature](https://developer.apple.com/documentation/speech/dictationtranscriber#Improve-accuracy).

Compiled models likewise attach to `DictationTranscriber` through the [`customizedLanguage(modelConfiguration:)` content hint](https://developer.apple.com/documentation/speech/dictationtranscriber/contenthint/customizedlanguage(modelconfiguration:)). Apple’s current [live-speech sample](https://developer.apple.com/documentation/speech/recognizing-speech-in-live-audio#Customize-the-language-model) demonstrates phrase counts and custom pronunciations, compiles the model, and initializes `DictationTranscriber` with that hint.

Narrow conclusion: official documentation establishes contextual strings and compiled custom language models for `DictationTranscriber`, and the legacy equivalents for `SFSpeechRecognitionRequest`. It does **not** establish that Mimi’s current general-purpose `SpeechTranscriber` consumes either customization. This is not a claim that `SpeechAnalyzer` lacks context—the analyzer has it—or that future `SpeechTranscriber` versions cannot gain support.

## 3. Current Parakeet path and FluidAudio

Mimi’s Python sidecar pins [`parakeet-mlx==0.5.1`](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Sidecars/mimi_mlx_server.py#L1-L5); upstream identifies that exact version in [`pyproject.toml`](https://github.com/senstella/parakeet-mlx/blob/ba03a1b6e8df4edadc83aca312a32600831dd481/pyproject.toml#L5-L8). Mimi sends only `id`, `command`, and audio `path` in each request ([protocol source](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Sources/Mimi/ASRService.swift#L196-L208)). The sidecar constructs greedy decoding plus sentence splitting and calls `model.transcribe` with path, dtype, decoding config, and chunking ([sidecar source](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Sidecars/mimi_mlx_server.py#L30-L36), [call](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Sidecars/mimi_mlx_server.py#L66-L74)). Upstream 0.5.1’s public [`DecodingConfig`](https://github.com/senstella/parakeet-mlx/blob/ba03a1b6e8df4edadc83aca312a32600831dd481/parakeet_mlx/parakeet.py#L77-L93) contains only decoder and sentence configuration, and its [`transcribe` signature](https://github.com/senstella/parakeet-mlx/blob/ba03a1b6e8df4edadc83aca312a32600831dd481/parakeet_mlx/parakeet.py#L133-L147) exposes no prompt, hotword, or contextual-bias parameter. Therefore neither Mimi’s current protocol nor the exact decoder call surface it uses can carry such input.

Mimi separately pins [`FluidAudio` 0.15.4](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Package.swift#L13-L20). That pinned upstream revision does contain a [CTC-based custom-vocabulary pipeline](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Documentation/ASR/CustomVocabulary.md#L1-L16): it scores terms against CTC acoustic evidence, rescoring Parakeet output; its model supports canonical terms and aliases ([documented semantics](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Documentation/ASR/CustomVocabulary.md#L293-L326)) and passes `CustomVocabularyContext` into ASR ([usage](https://github.com/FluidInference/FluidAudio/blob/b9d43724cbdb5a980e441fd54180964e94d470f7/Documentation/ASR/CustomVocabulary.md#L404-L425)). This is verified capability, not assumed from current `main`.

Mimi does not use FluidAudio for ASR today: ASR selection routes Parakeet to the Python sidecar and Apple to `SpeechTranscriber` ([routing](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Sources/Mimi/DictationController.swift#L528-L537)); FluidAudio is used for speaker diarization/voiceprint work ([source](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Sources/MimiSpeech/VoiceprintPrototype.swift#L219-L259)). Its vocabulary feature therefore requires an ASR backend migration or new integration, not a sidecar flag.

## 4. Recommended v1 semantics

Each entry has one nonempty **canonical written form** and zero or more explicit **spoken aliases**. The canonical form is also an implicit match key, allowing `pytorch` to canonicalize to `PyTorch`; aliases capture observed renderings such as `pie torch`. Output always uses the canonical string exactly, including case and punctuation.

Matching decisions:

1. Normalize source and keys to Unicode NFC for comparison, then apply locale-independent Unicode case folding. Preserve original source ranges and untouched text.
2. Match only whole boundaries: adjacent characters outside a match must not be Unicode letters, numbers, combining marks, or connector punctuation. This prevents `API` matching inside `myAPI2` or `_api`; punctuation remains outside replacement spans.
3. Find every candidate against the original normalized source. At each position, choose the longest source span; then select earliest, non-overlapping matches. Apply selected edits to original text from end to start.
4. Run one pass only. Replacement output is never searched again, preventing cascades such as alias A → canonical B → canonical C.
5. Enforce one normalized key owner. Deduplicate repeated keys within an entry. Reject an alias or canonical key already owned by another canonical form and identify the conflicting entry; one normalized canonical form represents one editable entry. No hidden priority or insertion-order tie-breaker.
6. Do not invent plural, possessive, edit-distance, phonetic, or fuzzy variants. Users add each observed alias explicitly.

This policy favors correction precision over speculative recall. Technical text contains short acronyms, identifiers, homophones, and intentional nonstandard casing; automatic fuzzy or phonetic replacement can silently change meaning. Explicit aliases make every mutation explainable, while recognition hints can later improve cases where neither canonical form nor a known alias appears.

Run this one pure corrector after backend transcription and existing mechanical cleanup, but before transcript history and paste. Capture one immutable vocabulary snapshot when recording begins so edits during dictation cannot make partial and final processing disagree. Apple partials may use the same projection for display, but only finalized text is authoritative; [Parakeet remains batch-only in the current sidecar](https://github.com/adstastic/mimi/blob/5a8bcec7e4635817422f848dab5913a2cbae61c4/Sidecars/mimi_mlx_server.py#L47-L77). Persist neither matches nor learned aliases from volatile partials. Given identical input text and snapshot, Apple and Parakeet must produce identical corrected output.

## 5. Deferred experiments and adoption gates

### Apple `DictationTranscriber`

Prototype `AnalysisContext.contextualStrings` and compiled `SFSpeechLanguageModel` only behind the deterministic layer. Measure against current `SpeechTranscriber`: target-term recall; harmful non-target insertions; exact casing; overall WER; volatile/final stability; first-result and finalization latency; context-update cost; model compilation/preparation time; asset size, memory, and energy; locale/device coverage; and quality as lists approach Apple’s 100-phrase limit. Adopt only if recall improves without unacceptable general-transcription or latency regressions.

### FluidAudio or Parakeet migration

Compare current `parakeet-mlx` 0.5.1 with FluidAudio 0.15.4’s acoustic vocabulary rescoring using fixed target and adversarial audio. Measure target recall, correction precision, false replacements, overall WER, exact casing after canonicalization, batch and streaming latency, multiword behavior across chunk boundaries, peak memory/energy, model download and disk cost, startup time, and maintenance cost of replacing the sidecar. Adopt backend biasing only when gains survive realistic vocabulary sizes and ambiguous aliases; retain deterministic canonicalization as source of truth regardless of backend.
