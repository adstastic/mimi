# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.12] - 2026-08-20

### Fixed

- Settings panes now stay visible inside the window instead of collapsing into Tahoe's Navigation Toolbar Items overflow menu.
- Live transcript previews now stream with the default audio-level stop detection mode instead of appearing only with Apple VAD or ambient mode.

## [0.1.11] - 2026-08-12

### Fixed

- Fresh installs now open Settings on launch so required permissions can be granted even when macOS Tahoe hides the menu-bar item.
- Global shortcuts now start after permissions are granted without requiring Mimi to be relaunched.
- AirPods playback and media controls now remain uninterrupted after dictation by preferring the built-in microphone for automatic Bluetooth input and skipping unnecessary speaker echo capture for Bluetooth output.
- AirPods microphone mute gestures are handled during active recording instead of producing a “Cannot Control Mic” notification.

## [0.1.10] - 2026-08-08

### Changed

- Redesigned Settings as five native macOS toolbar panes—General, Paste, Shortcuts, My Voice, and Advanced—so the window fits comfortably on a MacBook display.
- Kept expert timing, vocabulary, and paste-preset collection options in the canonical config file while exposing Open and Reload actions from Advanced.
- Moved Copy Last Dictation to the menu-bar menu and kept live transcription in the recording overlay instead of mixing transient content into Settings.

### Fixed

- Settings now surface config persistence errors across every pane.
- The audio input picker now uses the same control size and typography as neighboring settings.

## [0.1.9] - 2026-08-08

### Added

- Paste presets: named pre/post-paste keystroke sets (Terminal agent, RevDiff, TUICR by default) selectable in Settings or cycled with a global shortcut (default Control-Option-P) that shows the active preset in the overlay.

### Fixed

- Mimi no longer reads its own pasted keystrokes back as global shortcuts, so pre/post-paste keys such as C no longer trigger Correct Last Dictation while modifiers are held.

## [0.1.8] - 2026-08-06

### Fixed

- Escape now cancels an active recording without being sent to the focused app, while still passing through normally outside recording.

## [0.1.7] - 2026-08-04

### Changed

- Correct Last Dictation now opens in its own window from the menu, global shortcut, or Settings without opening the full Settings window.

### Fixed

- Multiple corrections can now update existing vocabulary entries without failing on conflicts.
- The correction shortcut now keeps the correction window open instead of immediately dismissing it.

## [0.1.6] - 2026-08-03

### Fixed

- Prevented speaker playback from reaching dictation by using system audio only as an echo-cancellation reference.
- Restored a responsive microphone level meter that remains sensitive to quiet speech.

## [0.1.5] - 2026-08-03

### Added

- Custom vocabulary with deterministic spelling and casing across Apple SpeechTranscriber and Parakeet.
- Correct Last Dictation from the menu bar or configurable global shortcut, with a preview of reusable word-level corrections before saving.
- User-editable settings and vocabulary in `~/.config/mimi/config.json`, with Open Config File and Reload Config commands.

### Changed

- Mimi now primes the microphone after wake and waits for cold audio inputs before finishing dictation.

### Fixed

- Restored Escape cancellation while holding the dictation shortcut on macOS 27.
- Improved recovery when CoreAudio reassigns or temporarily loses the selected microphone.

## [0.1.4] - 2026-08-01

### Added

- Independent before/after-paste keystrokes and delays for shortcut and ambient dictation.

### Changed

- Mimi now runs from the menu bar and opens its full Settings window on demand instead of showing a window at launch.

### Fixed

- Improved synthetic key delivery to terminal sessions, including SSH workflows.
- Fixed intermittent “Request was rejected” errors and stale microphone routing when switching dictation modes or audio inputs.
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

[Unreleased]: https://github.com/adstastic/mimi/compare/v0.1.12...HEAD
[0.1.12]: https://github.com/adstastic/mimi/compare/v0.1.11...v0.1.12
[0.1.11]: https://github.com/adstastic/mimi/compare/v0.1.10...v0.1.11
[0.1.10]: https://github.com/adstastic/mimi/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/adstastic/mimi/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/adstastic/mimi/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/adstastic/mimi/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/adstastic/mimi/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/adstastic/mimi/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/adstastic/mimi/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/adstastic/mimi/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/adstastic/mimi/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/adstastic/mimi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/adstastic/mimi/releases/tag/v0.1.0
