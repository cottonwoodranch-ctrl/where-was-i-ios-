import SwiftUI

@main
struct WhereWasIApp: App {
    @StateObject private var capture = CaptureController()

    var body: some Scene {
        WindowGroup {
            RootView(capture: capture)
        }
    }
}

/// Shows onboarding on first run, then the main screen. Starts listening only after
/// onboarding, and only while the app is in the foreground.
struct RootView: View {
    @ObservedObject var capture: CaptureController
    @AppStorage("onboardingDone") private var onboardingDone = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if onboardingDone {
                ContentView(capture: capture)
                    .transition(.opacity)
            } else {
                OnboardingView {
                    onboardingDone = true
                    capture.start() // shows the system microphone prompt
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: onboardingDone)
        .onAppear {
            if onboardingDone { capture.start() }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                if onboardingDone { capture.start() }
            default:
                capture.stop()
            }
        }
    }
}
