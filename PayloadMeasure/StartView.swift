import SwiftUI

// The first thing shown on launch: pick how to work through a load. Nothing runs until one is
// chosen, so the AR session does not start behind this screen.
//
// In:  nothing.
// Out: the chosen MeasurementFlow. Shown again only after a full reset or a relaunch.

struct StartView: View {
    let onSelect: (MeasurementFlow) -> Void

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
                            onSelect(flow)
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

                Text("You can switch by resetting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 520)
        }
    }
}
