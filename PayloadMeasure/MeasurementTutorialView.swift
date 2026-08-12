import SwiftUI

// How to measure, shown while the environment is still being understood — and held on screen for a
// moment longer if that finishes quickly, so the loop is always seen at least once.
//
// In:  whether the environment is ready yet.
// Out: on screen only. Calls onFinished when it is done and the scan can begin.
//
// Four beats, looping: hold the phone over the object, hold still while it measures, done, next
// object. No assets — everything is drawn, so there is nothing to keep in step with the UI.

struct MeasurementTutorialView: View {
    let isEnvironmentReady: Bool
    let onFinished: () -> Void

    /// Long enough to watch the loop through once even on a fast start.
    private static let minimumOnScreen: Duration = .seconds(6)

    @State private var beat = Beat.position
    @State private var hasWaitedLongEnough = false

    private enum Beat: CaseIterable {
        case position, hold, done, next

        var title: String {
            switch self {
            case .position: "Hold the phone over the object"
            case .hold: "DON'T MOVE"
            case .done: "Measured"
            case .next: "Next object"
            }
        }

        var detail: String {
            switch self {
            case .position: "Flat, looking straight down at it."
            case .hold: "Keep it still while the size settles."
            case .done: "Name it and give it a weight."
            case .next: "Then point at the next one."
            }
        }

        var seconds: Double {
            switch self {
            case .position: 2.2
            case .hold: 2.4
            case .done: 1.4
            case .next: 1.6
            }
        }
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer(minLength: 0)

                stage
                    .frame(height: 210)

                VStack(spacing: 8) {
                    Text(beat.title)
                        .font(beat == .hold ? .largeTitle.weight(.heavy) : .title2.weight(.semibold))
                        .foregroundStyle(beat == .hold ? Color.orange : Color.primary)
                        .contentTransition(.opacity)
                    Text(beat.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .animation(.snappy(duration: 0.25), value: beat)

                Spacer(minLength: 0)

                footer
            }
            .padding(28)
            .frame(maxWidth: 520)
        }
        .task { await run() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("How to measure. \(beat.title). \(beat.detail)")
    }

    // MARK: - Drawing

    private var stage: some View {
        ZStack {
            // The table.
            Capsule()
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 250, height: 14)
                .offset(y: 92)

            // The object being measured, swapped for a different one on the last beat.
            RoundedRectangle(cornerRadius: 8)
                .fill(beat == .next ? Color.purple.opacity(0.75) : Color.accentColor.opacity(0.75))
                .frame(
                    width: beat == .next ? 62 : 96,
                    height: beat == .next ? 66 : 46
                )
                .offset(y: beat == .next ? 58 : 68)
                .overlay {
                    if beat == .done || beat == .hold {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.green, lineWidth: 3)
                            .frame(
                                width: beat == .next ? 62 : 96,
                                height: beat == .next ? 66 : 46
                            )
                            .offset(y: beat == .next ? 58 : 68)
                    }
                }

            // The phone, dropping into place and then holding.
            phone
                .offset(y: beat == .position ? -78 : -46)

            if beat == .hold {
                measuringSweep
            }

            if beat == .done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.green)
                    .offset(y: 10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.45), value: beat)
    }

    private var phone: some View {
        RoundedRectangle(cornerRadius: 7)
            .stroke(Color.primary.opacity(0.75), lineWidth: 2.5)
            .frame(width: 54, height: 96)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
                    .padding(5)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.primary.opacity(0.4))
                    .frame(width: 16, height: 3)
                    .padding(.top, 6)
            }
    }

    private var measuringSweep: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .green.opacity(0.55), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 120, height: 60)
            .offset(y: 40)
            .transition(.opacity)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if isEnvironmentReady && hasWaitedLongEnough {
                Button("Start measuring", action: onFinished)
                    .font(.headline)
                    .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(
                        isEnvironmentReady
                            ? "Almost ready…"
                            : "Finding the surface and warming up object detection…"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Text("You cannot measure until this finishes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 62)
        .animation(.snappy(duration: 0.2), value: isEnvironmentReady && hasWaitedLongEnough)
    }

    // MARK: - Timing

    private func run() async {
        let started = ContinuousClock.now
        Task {
            try? await Task.sleep(for: Self.minimumOnScreen)
            hasWaitedLongEnough = true
        }
        _ = started
        while !Task.isCancelled {
            for step in Beat.allCases {
                guard !Task.isCancelled else { return }
                beat = step
                try? await Task.sleep(for: .seconds(step.seconds))
            }
        }
    }
}
