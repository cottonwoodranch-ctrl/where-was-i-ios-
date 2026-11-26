# Where Was I? iOS — changes in 0.3 (UI polish, 21 Nov 2026)

All 0.2 fixes and behaviours are kept (steady-noise fix, digital-silence fix, phrase-boundary
replay, cancelPendingStall, interruptions, route changes, no forced speaker, hold-off, VoiceOver
lead-in, iPhone only, privacy manifest, unique CI build numbers).

## Flow
- First-run onboarding (App/OnboardingView.swift, App/WhereWasIApp.swift → RootView): three
  numbered points (what it does, only while open, the 30-second memory), a note that the microphone
  prompt comes next, and one **Continue** button. The prompt appears only after Continue. Shown once
  (@AppStorage "onboardingDone").
- One primary action: a large **Replay what I said** button, at least 64 pt tall. It shows "Nothing to
  replay yet" when there is nothing, and **Open Settings** when the microphone is denied.
- New secondary **Pause listening / Start listening** toggle. While paused, the microphone is released
  and nothing is analysed. The pause lasts until you tap Start listening (also across app switches)
  or the app is relaunched.
- A single phase model (`ListeningPhase`) drives the UI: Starting, Listening, Hearing you, You paused,
  Playing back what you said, Listening is paused, Paused while another app uses audio, The app needs
  the microphone, Could not start the microphone. Each has a one-line plain-language hint.

## Visual design (App/Theme.swift, App/ContentView.swift)
- Large status orb: the halo breathes slowly while listening, follows your voice while you
  speak, holds still when you pause, and pulses gently during a replay. The colours ease between states.
  Status text cross-fades. With Reduce Motion on, all of this is static or instant.
- Dark mode is now supported. The palette has light and dark variants, with the same hex values as
  Android, and passes WCAG 2.1 AA: body text 12.4/15.1:1, secondary text 5.2/8.7:1, button text 7.0/7.4:1,
  disabled button 9.1/10.0:1, state colours ≥ 4.4:1 on the background. `UIUserInterfaceStyle = Light`
  was removed from Info.plist.
- The slider sits in a card. Text styles throughout, so everything follows Dynamic Type, and the screen
  scrolls at the largest sizes.

## Accessibility
- VoiceOver:
  - the title is a header;
  - status and hint are read as one element;
  - the orb is hidden, as decoration;
  - each onboarding point is one element;
  - the slider has a label, a spoken value ("3.0 seconds") and a hint;
  - the disabled Replay button says "Replay. Nothing to replay yet".
  
  The status is deliberately not auto-announced, because VoiceOver speech would be recorded and replayed.
  Replay start is still announced, followed by the 1-second lead-in.
- Haptics: a soft impact when an automatic replay starts, a light tap on Pause/Start listening, and
  selection ticks on slider steps.

## Smoothness / threading
- New `ListeningPipeline` (Sources/WhereWasICore/ListeningPipeline.swift): the audio tap converts
  on the audio thread and hands samples straight to a private serial queue, which does the framing,
  the ring buffer, the detector, the post-replay hold-off and the "replay again" memory. The main
  actor now gets only a small snapshot about 20 times a second (state, level, canReplay) and the replay
  PCM. Before, every tap buffer hopped to the main thread.
- App/CaptureController.swift was rewritten around the pipeline and the phase model. Session,
  interruption and route handling are unchanged.

## Wording (Sources/WhereWasICore/Copy.swift)
- All user-facing text is in one file and matches Android `UiCopy.java` exactly. Android's
  `tools/check_copy.py` checks this.

## Privacy
- The privacy manifest has also been added to the WhereWasICore framework (Resources/Core/), because
  `ProcessInfo.systemUptime` is now called there (reason 35F9.1). The app manifest still declares
  UserDefaults (CA92.1) for the wait setting and the onboarding flag.

## Project
- MARKETING_VERSION 0.3. XcodeGen validated on Linux (all targets iPhone-only, both privacy manifests
  in Resources, new sources included).

## Tests (Linux, Swift 6.4.2): 26 → 35, all pass
- ListeningPipelineTests (6):
  - stall delivers PCM off the main thread and stops input;
  - replay is available again after an automatic replay;
  - hold-off ignores echo;
  - not-accepting drops input;
  - cancelPendingStall keeps manual replay;
  - snapshots are throttled to about 20 Hz with valid levels.
- CopyTests (3): phase mapping, every phase has text, wording pinned to the Android strings.
- The core library also builds cleanly with `-strict-concurrency=complete -warnings-as-errors`.

## Not verified (needs a Mac / iPhone)
- The app target (SwiftUI/UIKit/AVFoundation) has not been compiled: there is no iOS SDK on Linux.
- Rendering, animations, Dynamic Type layouts, dark mode, real VoiceOver and haptics, and on-device audio.
