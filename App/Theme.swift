import SwiftUI
import UIKit
import WhereWasICore

/// Shared palette (same hex values as Android `Theme.java`). Light and dark variants were
/// checked against WCAG 2.1: body text ≥ 12:1, secondary text ≥ 5.2:1, button text ≥ 7:1,
/// state colours ≥ 4.3:1 on the background (non-text UI needs 3:1).
enum Palette {
    static let background = dynamic(light: 0xF5EDE0, dark: 0x1A1714)
    static let surface    = dynamic(light: 0xFFFFFF, dark: 0x26221E)
    static let ink        = dynamic(light: 0x2E2924, dark: 0xF2EBE0)
    static let muted      = dynamic(light: 0x6B6157, dark: 0xBFB3A5)
    static let accent     = dynamic(light: 0x8C452E, dark: 0xE0957A)
    static let onAccent   = dynamic(light: 0xFFFFFF, dark: 0x1A1714)
    static let track      = dynamic(light: 0xDBCCB8, dark: 0x3D3631)
    static let listening  = dynamic(light: 0x386B5C, dark: 0x7FC2AE)
    static let hearing    = dynamic(light: 0xA85A22, dark: 0xE8A66E)
    static let paused     = dynamic(light: 0x73598C, dark: 0xB9A2D6)
    static let alert      = dynamic(light: 0xB33330, dark: 0xF08A85)

    static func color(for phase: ListeningPhase) -> Color {
        switch phase {
        case .listening: return listening
        case .hearing: return hearing
        case .paused: return paused
        case .replaying: return accent
        case .needsPermission, .unavailable: return alert
        case .starting, .stoppedByUser, .interrupted: return muted
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            uiColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Large, calm status indicator: a solid core and a soft halo.
/// Listening: the halo breathes slowly. Hearing you: the halo follows your voice.
/// You paused: the halo holds still. Replaying: a gentle pulse.
/// With Reduce Motion on, the halo is static in every state.
struct StatusOrb: View {
    let phase: ListeningPhase
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let color = Palette.color(for: phase)
        ZStack {
            Circle()
                .fill(color.opacity(haloOpacity))
                .frame(width: 150, height: 150)
                .scaleEffect(haloScale)
            Circle()
                .fill(color)
                .frame(width: 88, height: 88)
        }
        .frame(width: 180, height: 180)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: phase)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .onAppear { restartBreathing() }
        .onChange(of: phase) { _ in restartBreathing() }
        .onChange(of: reduceMotion) { _ in restartBreathing() }
        .accessibilityHidden(true) // the status text says the same thing
    }

    private var haloScale: CGFloat {
        if reduceMotion { return phase.micIsLive || phase == .replaying ? 1.08 : 0.9 }
        switch phase {
        case .listening: return breathe ? 1.10 : 0.94
        case .hearing: return 0.95 + CGFloat(min(1, level)) * 0.3
        case .paused: return 1.05
        case .replaying: return breathe ? 1.12 : 1.0
        default: return 0.85
        }
    }

    private var haloOpacity: Double {
        switch phase {
        case .listening, .hearing, .paused, .replaying: return 0.22
        default: return 0.10
        }
    }

    private func restartBreathing() {
        breathe = false
        guard !reduceMotion, phase == .listening || phase == .replaying else { return }
        let period = phase == .listening ? 2.8 : 1.4
        withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) {
            breathe = true
        }
    }
}
