# Where Was I? (iOS prototype)

A minimal iPhone-only app (no iPad or Mac build) that listens **only while it is open**, notices when you stop talking, and plays back the last thing you said so you can pick up your train of thought.

This repository is **source only**. It is ready for a cloud macOS build (Codemagic or GitHub Actions) or for Xcode on a Mac. It is not a signed, installable iPhone file. Getting it onto a phone still needs either a paid Apple Developer account or a Mac and a free Apple ID (see below).

The voice-activity and stall-detection logic started as a port of the Android prototype (`StallDetector` + `RingBuffer`) with the same thresholds. Version 0.2 fixes are in both the iOS and Android 0.2 builds (see `CHANGES-0.2.md`).

## What the app does

- Uses `AVAudioEngine` to capture 16 kHz mono audio into a rolling **30-second in-memory** ring buffer. Nothing is written to disk or uploaded.
- Energy-based voice activity detection with an adaptive noise floor.
- After you speak, a configurable silence of **2–6 seconds** (default 3 s, slider in the UI) automatically plays the last utterance, capped at about **10 seconds**.
- A **Replay what I said** button plays the same segment on demand, including right after an automatic replay.
- Capture pauses during playback, then listening resumes.
- Foreground only: leaving the app stops the microphone. iOS will show the orange microphone indicator while it is listening.
- A first-run welcome screen, a large animated status orb with plain-language status text, one primary **Replay** button, a **Pause listening / Start listening** toggle, and a privacy line: “Audio stays on this device.”
- Light and dark appearance (WCAG-checked palette shared with Android), Dynamic Type, VoiceOver labels, Reduce Motion, and haptics.
- The audio analysis runs on its own queue (`ListeningPipeline`), not on the main thread.

## Project layout

```
Sources/WhereWasICore/     Pure Swift VAD, stall detector, ring buffer, ListeningPipeline, shared wording (no iOS APIs)
Resources/Core/            Privacy manifest for the core framework
Tests/WhereWasICoreTests/  Unit tests for that logic
App/                       SwiftUI app, audio engine, Info.plist, assets
Package.swift              Swift package so the logic can be tested on Linux or a Mac
project.yml                XcodeGen spec (run `xcodegen generate` to create the .xcodeproj)
codemagic.yaml             TestFlight workflow (placeholders for bundle id and API keys)
.github/workflows/ios.yml  Unsigned simulator build + tests; optional signed TestFlight job
```

The Xcode project is generated, not checked in. On a Mac:

```bash
brew install xcodegen
xcodegen generate
open WhereWasI.xcodeproj
```

Bundle identifier placeholder: `com.iqbal.wherewasi`. Change it in `project.yml` if that id is already taken.

## How to test the idea (once installed)

1. Read the welcome screen, tap **Continue**, and allow the microphone when iOS asks.
2. Speak a short sentence, then go quiet for about 3 seconds. You should hear it played back.
3. Try **Replay what I said** to hear it again.
4. Move the **Wait before replaying** slider (2–6 s) and repeat.
5. Leave the app: listening should stop. Come back and it starts again.
6. Tap **Pause listening**: the orb turns grey and nothing is heard until you tap **Start listening**.
7. Try it with VoiceOver, the largest text size, Dark Mode, and Reduce Motion turned on.

Speak at a normal conversation level, reasonably close to the phone. Very short clicks and bumps under 300 ms are ignored on purpose.

## (a) TestFlight via Codemagic — needs a $99/year Apple Developer account

This is the path that lets you (and testers) install from the TestFlight app without keeping a Mac plugged in. A cloud Mac at Codemagic signs the build. You have to create the Apple and Codemagic accounts yourself; nothing here signs you up or pays for you.

1. **Enroll** in the [Apple Developer Program](https://developer.apple.com/programs/) ($99 USD / year) at the same Apple ID you want to use for the app. Approval can take a few hours to a couple of days.
2. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list), register an **App ID** (bundle identifier). Use `com.iqbal.wherewasi` if it is available, otherwise pick another and put it in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`) and in `codemagic.yaml` (`bundle_identifier` / `BUNDLE_ID`).
3. In [App Store Connect](https://appstoreconnect.apple.com), create a new **iOS app** with that bundle id. Note the numeric Apple ID of the app.
4. In App Store Connect → Users and Access → **Integrations** → App Store Connect API, create an **API key** with the App Manager or Admin role. Download the `.p8` file (you only get it once) and copy the **Key ID** and **Issuer ID**.
5. Create a free [Codemagic](https://codemagic.io) account and add this project (connect a Git repo, or use Codemagic’s other upload options). Open the workflow **iOS TestFlight** from `codemagic.yaml`.
6. In the Codemagic UI:
   - Add encrypted environment variables (do not paste the private key into the yaml file):
     - `APP_STORE_CONNECT_PRIVATE_KEY` — contents of the `.p8`
     - `APP_STORE_CONNECT_KEY_IDENTIFIER` — Key ID
     - `APP_STORE_CONNECT_ISSUER_ID` — Issuer ID
   - Set `APP_STORE_APP_ID` and, if you changed it, `BUNDLE_ID`.
   - Enable iOS code signing. Codemagic can create an Apple Distribution certificate and an App Store provisioning profile from the API key. Allow it to manage signing, or upload your own certificate and profile.
7. Run **ios-workflow**. It installs XcodeGen, generates the project, signs, builds an IPA, and publishes to TestFlight.
8. In App Store Connect, wait until the build finishes processing (often 10–30 minutes). Add yourself as an internal tester, install **TestFlight** on the iPhone, and accept the invite.

GitHub Actions is an alternative if you already have a GitHub repo: `.github/workflows/ios.yml` always builds for the simulator and runs the unit tests. The signed TestFlight job runs only when these GitHub secrets are all set: `APP_STORE_CONNECT_API_KEY`, `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `BUILD_PROVISION_PROFILE_BASE64`, `APPLE_TEAM_ID`.

## (b) Free option — sideload with a free Apple ID on a Mac

You do not need to pay Apple for a personal test, but you **do need a Mac** (yours, or a friend’s) with Xcode, and the app will **expire after 7 days**. You then reopen Xcode and install it again. There is no TestFlight and no way to do this from Linux alone.

1. On the Mac, install **Xcode** from the Mac App Store and open it once to accept the license and install components. Sign in under **Xcode → Settings → Accounts** with a free Apple ID (any iCloud account).
2. Copy this folder onto the Mac. In Terminal, from the project root:

   ```bash
   brew install xcodegen
   xcodegen generate
   open WhereWasI.xcodeproj
   ```

3. In Xcode, select the **WhereWasI** target → **Signing & Capabilities**. Tick **Automatically manage signing**, choose your personal team, and if Xcode complains that the bundle id is taken, change it to something unique such as `com.yourname.wherewasi`.
4. On the iPhone: Settings → Privacy & Security → **Developer Mode** (iOS 16+) → on, then restart and confirm. Unlock the phone, connect it with a cable, and trust the computer if asked.
5. In Xcode, pick your iPhone as the run destination and press Run. The first time, the phone may say the developer is not trusted: Settings → General → VPN & Device Management → trust the Apple ID.
6. Test as described above.

**7-day limit:** a free Apple ID provisioning profile expires about every 7 days. The app icon stays, but opening it will say the developer needs to be re-verified. Plug the phone back into the same Mac, open the project, and Run again.

A friend’s Mac works the same way, but the signing identity is theirs. After 7 days you need that Mac (or another Mac signed into the same Apple ID) to refresh it.

## Unit tests (no Mac required for the logic)

The detector and ring buffer have no iOS dependencies. On a machine with Swift 5.9+:

```bash
swift test
```

The GitHub Actions workflow also runs these tests on a simulator after `xcodegen generate`.

## What you still need in order to put this on an iPhone

This zip is not an installable `.ipa`. To get it onto a phone you still need **one** of:

- A paid Apple Developer Program membership ($99/year), an App Store Connect API key, and a Codemagic (or GitHub Actions) account so a cloud Mac can sign a TestFlight build; or
- A Mac with Xcode and a free Apple ID, for a 7-day sideload.

There is no free, official way to produce a signed iPhone build from Linux alone.
