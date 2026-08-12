import SwiftUI

// The first thing shown on launch: pick how to work through a load. Nothing runs until one is
// chosen, so the AR session does not start behind this screen.
//
// In:  nothing.
// Out: the chosen MeasurementFlow. Shown again only after a full reset or a relaunch.

struct StartView: View {
    let warmup: AppWarmup
    let onSelect: (MeasurementFlow) -> Void

    @State private var pendingFlow: MeasurementFlow?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.tint)
                    Text("PayloadMeasure")
                        .font(.largeTitle.weight(.semibold))
                    Text("Measure a payload, then work out how to load it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    ForEach(MeasurementFlow.allCases) { flow in
                        Button {
                            choose(flow)
                        } label: {
                            HStack(alignment: .top, spacing: 13) {
                                Image(systemName: flow.systemImage)
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(flow.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(flow.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 18)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(flow.title)
                        .accessibilityHint(flow.detail)
                    }
                }

                // Only shown when there is genuinely something left to wait for.
                if !warmup.isReady {
                    VStack(spacing: 7) {
                        ProgressView(value: warmup.progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 260)
                        Text(
                            pendingFlow == nil
                                ? "Preparing camera and object detection…"
                                : "Starting as soon as this finishes…"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else {
                    Text("You can switch by resetting.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 520)
        }
        .animation(.snappy(duration: 0.2), value: warmup.isReady)
        .onAppear(perform: warmup.start)
        .onChange(of: warmup.isReady) { _, ready in
            if ready, let pendingFlow {
                onSelect(pendingFlow)
            }
        }
    }

    /// Tapping before the frameworks are loaded queues the choice rather than freezing on it.
    private func choose(_ flow: MeasurementFlow) {
        guard warmup.isReady else {
            pendingFlow = flow
            return
        }
        onSelect(flow)
    }
}
