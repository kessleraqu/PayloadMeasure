import SwiftUI

/// Neutral screen between phases. Shown after the previous phase has stopped; the button starts
/// the next one.
struct StudyPhaseHandoffView: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let onStart: () -> Void

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

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
