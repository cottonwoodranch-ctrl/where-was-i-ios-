import SwiftUI
import WhereWasICore

struct ContentView: View {
    @ObservedObject var capture: CaptureController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                // Scrolls only when the content no longer fits (largest Dynamic Type sizes).
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 20)
                    StatusOrb(phase: capture.phase, level: capture.level)
                    statusText
                        .padding(.top, 12)
                    Spacer(minLength: 24)
                    primaryButton
                    if !capture.permissionDenied {
                        secondaryButton
                            .padding(.top, 14)
                        waitSlider
                            .padding(.top, 28)
                    }
                    Spacer(minLength: 16)
                    privacyLine
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(minHeight: geo.size.height)
            }
        }
        .background(Palette.background.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(Copy.appTitle)
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                .foregroundColor(Palette.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(Copy.subtitle)
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(Palette.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var statusText: some View {
        ZStack {
            statusContent
                .id(capture.phase)
                .transition(.opacity)
        }
        // Cross-fade between states (instant with Reduce Motion).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: capture.phase)
        .frame(maxWidth: .infinity)
    }

    private var statusContent: some View {
        VStack(spacing: 8) {
            Text(Copy.status(capture.phase))
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundColor(Palette.ink)
            if !Copy.detail(capture.phase).isEmpty {
                Text(Copy.detail(capture.phase))
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(Palette.muted)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        // Not announced automatically: VoiceOver speech while listening would be picked up
        // by the microphone and replayed. Replay start is announced separately.
    }

    @ViewBuilder
    private var primaryButton: some View {
        if capture.permissionDenied {
            Button(action: { capture.openSettings() }) {
                primaryLabel(Copy.openSettings, enabled: true)
            }
            .accessibilityHint(Copy.openSettingsHint)
        } else {
            Button(action: { capture.replayLast() }) {
                primaryLabel(capture.canReplay ? Copy.replay : Copy.nothingToReplay, enabled: capture.canReplay)
            }
            .disabled(!capture.canReplay)
            .accessibilityLabel(capture.canReplay ? Copy.replay : "Replay. \(Copy.nothingToReplay)")
            .accessibilityHint(capture.canReplay ? Copy.replayHint : "")
        }
    }

    private func primaryLabel(_ text: String, enabled: Bool) -> some View {
        Text(text)
            .font(.system(.title3, design: .rounded, weight: .semibold))
            .foregroundColor(enabled ? Palette.onAccent : Palette.ink)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(Capsule().fill(enabled ? Palette.accent : Palette.track))
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: enabled)
    }

    private var secondaryButton: some View {
        let listening = !capture.userPaused && capture.phase != .unavailable
        return Button(action: { capture.toggleListening() }) {
            Text(listening ? Copy.pauseListening : Copy.startListening)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundColor(Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal, 16)
                .background(Capsule().strokeBorder(Palette.muted, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .disabled(capture.isPlaying)
    }

    private var waitSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    sliderTitle
                    Spacer()
                    sliderValue
                }
                VStack(alignment: .leading, spacing: 4) {
                    sliderTitle
                    sliderValue
                }
            }
            .accessibilityHidden(true) // the slider carries the same label and value
            Slider(value: $capture.stallSeconds, in: 2...6, step: 0.5)
                .tint(Palette.accent)
                .frame(minHeight: 44)
                .accessibilityLabel(Copy.waitTitle)
                .accessibilityValue(Copy.waitValue(capture.stallSeconds))
                .accessibilityHint(Copy.waitHint)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface))
    }

    private var sliderTitle: some View {
        Text(Copy.waitTitle)
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundColor(Palette.ink)
    }

    private var sliderValue: some View {
        Text(Copy.waitValue(capture.stallSeconds))
            .font(.system(.body, design: .rounded, weight: .semibold).monospacedDigit())
            .foregroundColor(Palette.accent)
    }

    private var privacyLine: some View {
        Text(Copy.privacy)
            .font(.system(.footnote, design: .rounded))
            .foregroundColor(Palette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }
}
