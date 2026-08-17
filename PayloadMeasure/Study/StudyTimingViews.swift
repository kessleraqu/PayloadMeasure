import SwiftUI

/// Temporary on-screen timing audit. Every phase is visible together, while the active clock is
/// highlighted so a researcher can verify that handoff screens leave all timers stopped.
struct StudyTimerStrip: View {
    let study: StudyStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                timerCell(.measure, shortTitle: "Measure", at: context.date)
                timerCell(.pack, shortTitle: "Pack", at: context.date)
                timerCell(.payload, shortTitle: "Load", at: context.date)
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    private func timerCell(
        _ phase: StudyPhase,
        shortTitle: String,
        at date: Date
    ) -> some View {
        let isActive = study.currentPhase == phase
        let seconds = Int(study.elapsedSeconds(for: phase, at: date).rounded(.down))
        return VStack(spacing: 1) {
            Text(shortTitle)
                .font(.system(size: 9, weight: .semibold))
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(.system(.caption2, design: .monospaced).weight(.bold))
        }
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(
            isActive ? Color.red : Color.primary.opacity(0.07),
            in: Capsule()
        )
        .accessibilityLabel("\(phase.title) timer")
        .accessibilityValue("\(seconds) seconds\(isActive ? ", running" : ", stopped")")
    }
}

/// A neutral participant-controlled boundary. Entering this screen must happen only after the
/// previous phase has stopped; its button starts the next phase and then advances the UI.
struct StudyPhaseHandoffView: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let study: StudyStore
    let onStart: () -> Void

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack {
                StudyTimerStrip(study: study)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                Spacer()
            }

            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.black)
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(buttonTitle, action: onStart)
                    .font(.title2.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint("Starts the \(title.lowercased()) timer")
            }
            .padding(.horizontal, 36)
        }
        .preferredColorScheme(.light)
    }
}
