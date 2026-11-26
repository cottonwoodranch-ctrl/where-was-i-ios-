import SwiftUI
import WhereWasICore

/// First run: what the app does, and why it will ask for the microphone.
struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(Copy.appTitle)
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .foregroundColor(Palette.muted)
                Text(Copy.onboardingTitle)
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .foregroundColor(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(Copy.onboardingPoints.enumerated()), id: \.offset) { index, text in
                        HStack(alignment: .top, spacing: 16) {
                            Text("\(index + 1)")
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .foregroundColor(Palette.onAccent)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Palette.accent))
                                .accessibilityHidden(true)
                            Text(text)
                                .font(.system(.title3, design: .rounded))
                                .foregroundColor(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Text(Copy.onboardingMicNote)
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onContinue) {
                    Text(Copy.onboardingContinue)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundColor(Palette.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(Capsule().fill(Palette.accent))
                        .contentShape(Capsule())
                }
                .accessibilityHint("Your phone will then ask to use the microphone")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
        }
        .background(Palette.background.ignoresSafeArea())
    }
}
