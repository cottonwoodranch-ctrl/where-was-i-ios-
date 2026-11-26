# Where Was I? iOS — changes in 0.2 (technical review, 20 Nov 2026)

## Pause detection (Sources/WhereWasICore/StallDetector.swift)
- FIX (high): a steady noise that starts after calibration (fan, AC, TV hum) held the
  detector in "speaking" forever, so auto-replay never fired again. Added a 2.5 s
  minimum-statistics noise window so the floor can rise during a segment.
- FIX (high): all-zero buffers (typical for the first buffers after the engine starts or a
  route change) calibrated the floor to -75 dB, so ordinary room noise then counted as
  speech. Digital silence no longer calibrates or lowers the floor.
- FIX (low): calibration used a "-60 sentinel" instead of "first frame" (differed from Android).
- NEW: when a long monologue is capped at 10 s, the replay starts at a phrase boundary
  instead of mid-word when one fits.
- NEW: cancelPendingStall() — keeps the last utterance for a manual replay, but stops
  an auto-replay of something said before the app was paused or interrupted.

## Ring buffer (Sources/WhereWasICore/RingBuffer.swift)
- NEW: oldestAvailable and holds(start:end:) so the app only offers a replay that is still
  fully in memory.

## Audio (App/CaptureController.swift)
- FIX (high): removed overrideOutputAudioPort(.speaker) (3 places). It forced replies to
  the loudspeaker even with AirPods / wired headphones / car audio connected.
- FIX (high): Bluetooth / route changes stop AVAudioEngine (configuration change). The old
  code only reinstalled the tap and never restarted the engine, so listening went silent.
  Now observes AVAudioEngineConfigurationChange and restarts.
- FIX (high): no handling of audio interruptions (calls, Siri, alarms). Now pauses, ends any
  replay, cancels the pending auto-replay, and resumes when the interruption ends.
- FIX (medium): possible crash — AVAudioPlayerNode.play() on a stopped engine raises an
  exception; playback now aborts cleanly if the engine cannot start.
- FIX (medium): mic buffers were converted on the main thread with whatever converter was
  current, so after a route change old-format buffers could be converted with the new
  converter. Conversion now runs on the audio thread with the tap's own converter, and only
  [Int16] crosses to the main actor. The tap block is built outside the main actor.
- FIX (medium): "Replay" was disabled right after an automatic replay (the detector had
  forgotten it). The last replayed range is kept while still in the 30 s buffer.
- FIX (medium): after returning to the app, a pause from before could auto-replay 3 s later.
- FIX (low): 0.35 s hold-off after a replay so its tail / room echo is not heard as speech.
- FIX (low): duplicate permission requests from onAppear + scenePhase.
- NEW: medium haptic tap when an automatic replay starts (haptics allowed while recording).
- NEW: when VoiceOver is on, announces "Playing back what you said", then plays 1 s later
  (mic already off) so the two do not overlap.
- NEW: the "Wait before replaying" setting is remembered (UserDefaults).
- NEW: mediaServicesWereReset handling (stop + start).

## Accessibility / UI (App/ContentView.swift)
- FIX (high): all fonts were fixed sizes and ignored Dynamic Type; now text styles
  (largeTitle, title3, body, subheadline, footnote). Layout scrolls at very large sizes;
  slider title/value stack vertically when they do not fit; removed minimumScaleFactor.
- FIX (medium): disabled Replay button was white on 35% brown (about 2:1 contrast); now ink on
  a beige fill (9.2:1) and says "Nothing to replay yet".
- FIX: level meter hidden from VoiceOver (it changed 20×/s); status dot hidden (decorative);
  status text has the updatesFrequently trait; title is a header.
- FIX: slider's duplicate visual label hidden from VoiceOver; slider has label, value and hint;
  44 pt minimum heights on controls.
- FIX: meter animation off with Reduce Motion.
- NEW: "Open Settings" button when microphone permission is denied.
- Plain language: "Listens only while this app is open", "You paused…",
  "Playing back what you said…", "Replay what I said", "Wait before replaying".

## Project / store
- App/Info.plist: UIUserInterfaceStyle = Light (fixed light palette; avoids unreadable status
  bar in Dark Mode); ITSAppUsesNonExemptEncryption = false (skips the export-compliance
  question on every TestFlight upload).
- App/PrivacyInfo.xcprivacy (new): no tracking, no collected data; required-reason APIs
  SystemBootTime 35F9.1 (ProcessInfo.systemUptime) and UserDefaults CA92.1.
- project.yml: privacy manifest added to Resources; MARKETING_VERSION 0.2.
- iPhone only (21 Nov 2026): TARGETED_DEVICE_FAMILY = "1" (project, app, framework and test targets),
  SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO, and the iPad-only
  UISupportedInterfaceOrientations~ipad key removed from App/Info.plist. No iPad screenshots
  are needed. iPads can still run it in iPhone compatibility mode, and App Review may test it that way.
- codemagic.yaml and .github/workflows/ios.yml: unique build number per CI run
  (App Store Connect rejects a repeated build number).

## Tests
- 19 → 26 tests (all pass on Linux, Swift 6.4.2). New: steady-noise regression, digital-silence
  regression, speech over adapted noise, phrase-boundary cap, cancelPendingStall, segment reset,
  RingBuffer.holds. The 10 s cap test now uses a speech-like signal (a perfectly steady 15 s
  tone is now, correctly, treated like steady noise); the noise-floor test calibrates on very
  quiet noise instead of exact zeros.

## Android
- The detector fixes were ported to Android 0.2 on 21 Nov 2026 (/workspace/where-was-i,
  release/WhereWasI-0.2.apk, same signing certificate as 0.1). Android still uses a release
  smoothing factor of 0.35, where iOS uses 0.15.
