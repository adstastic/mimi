# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] - 2026-08-01

### Added

- Independent before/after-paste keystrokes and delays for shortcut and ambient dictation.

### Fixed

- Improved synthetic key delivery to terminal sessions, including SSH workflows.
- Paste-delay fields now finish editing when clicking elsewhere in Settings.

## [0.1.3] - 2026-07-29

### Fixed

- Removed standalone filler sounds such as “um,” “uh,” and “ah” consistently from live previews and pasted transcripts, with a setting to disable cleanup.

## [0.1.2] - 2026-07-29

### Changed

- Improved final batch transcription accuracy without slowing live transcript or ambient-mode updates.
- Adopted macOS 27's speech input converter while retaining the macOS 26 fallback.

## [0.1.1] - 2026-07-29

### Fixed

- Fixed ambient mode missing quiet speech when Apple's transcript arrived after the microphone level had fallen, which could require repeating the phrase or speaking louder.

## [0.1.0] - 2026-07-28

### Added

- Ambient mode that starts on speech and stops after a pause.
- Right Command dictation using hold-to-record or tap-to-toggle.
- Beta voiceprint filtering that keeps matching speaker segments before transcription.
- Local Apple SpeechTranscriber with NVIDIA Parakeet v2 on MLX as a fallback.
- Configurable microphone, silence detection, shortcuts, and Return after paste.
- Local-only operation with no account or telemetry.

[Unreleased]: https://github.com/adstastic/mimi/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/adstastic/mimi/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/adstastic/mimi/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/adstastic/mimi/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/adstastic/mimi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/adstastic/mimi/releases/tag/v0.1.0
