import Foundation

/// What the app is doing, as the person using it should understand it.
/// Shared by the UI and VoiceOver. Android has the same phases and wording in `UiCopy.java`.
public enum ListeningPhase: String, CaseIterable, Equatable, Sendable {
    case starting
    case needsPermission
    case listening       // quiet, waiting for speech
    case hearing         // speech in progress
    case paused          // the person stopped mid-thought; replay is coming
    case replaying
    case stoppedByUser   // "Pause listening" was tapped
    case interrupted     // phone call, Siri, alarm
    case unavailable     // microphone could not start

    /// Map the detector state while capture is live.
    public static func live(_ state: StallDetector.State) -> ListeningPhase {
        switch state {
        case .listening: return .listening
        case .speaking: return .hearing
        case .paused: return .paused
        }
    }

    /// True when the microphone is (or should be) open in this phase.
    public var micIsLive: Bool {
        switch self {
        case .listening, .hearing, .paused: return true
        default: return false
        }
    }
}

/// All user-facing wording in one place. Keep identical to Android `UiCopy.java`.
public enum Copy {
    public static let appTitle = "Where Was I?"
    public static let subtitle = "Listens only while this app is open"
    public static let privacy = "Audio stays on this device. Nothing is uploaded or saved."

    public static let replay = "Replay what I said"
    public static let nothingToReplay = "Nothing to replay yet"
    public static let replayHint = "Plays back the last thing you said"
    public static let pauseListening = "Pause listening"
    public static let startListening = "Start listening"
    public static let openSettings = "Open Settings"
    public static let openSettingsHint = "Opens Settings so you can turn on the microphone for this app"

    public static let waitTitle = "Wait before replaying"
    public static let waitHint = "How long you can pause before the app plays back what you said"
    public static func waitValue(_ seconds: Double) -> String {
        String(format: "%.1f seconds", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    public static let replayAnnouncement = "Playing back what you said"

    public static let onboardingTitle = "Lost your train of thought?"
    public static let onboardingPoints = [
        "Talk as usual. If you stop in the middle for a few seconds, the app plays back what you just said.",
        "It listens only while the app is open on your screen.",
        "It keeps only the last 30 seconds of sound, in this phone's memory. Nothing is ever saved or sent anywhere.",
    ]
    public static let onboardingMicNote = "Next, your phone will ask to use the microphone."
    public static let onboardingContinue = "Continue"

    public static func status(_ phase: ListeningPhase) -> String {
        switch phase {
        case .starting: return "Starting…"
        case .needsPermission: return "The app needs the microphone"
        case .listening: return "Listening…"
        case .hearing: return "Hearing you…"
        case .paused: return "You paused…"
        case .replaying: return "Playing back what you said…"
        case .stoppedByUser: return "Listening is paused"
        case .interrupted: return "Paused while another app uses audio"
        case .unavailable: return "Could not start the microphone"
        }
    }

    public static func detail(_ phase: ListeningPhase) -> String {
        switch phase {
        case .starting: return ""
        case .needsPermission: return "Tap Open Settings and turn on Microphone."
        case .listening: return "Talk as usual. If you stop mid-thought, I'll play it back."
        case .hearing: return "Keep going."
        case .paused: return "Replaying in a moment…"
        case .replaying: return "Pick up where you left off."
        case .stoppedByUser: return "Tap Start listening when you're ready."
        case .interrupted: return "Listening starts again when the call or other app is done."
        case .unavailable: return "Close the app and open it again."
        }
    }
}
