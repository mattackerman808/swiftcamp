#if os(macOS)
import Charts
import SwiftUI

/// Height along the selected route or track, under its fields: what
/// BaseCamp draws in its elevation profile. Closed until opened, and
/// remembered, like the directions.
///
/// Hovering reads the height and the distance at the pointer. A track
/// that recorded its own heights shows those; anything else is read off
/// the DEM, which takes a moment the first time over new ground.
struct ElevationPane: View {
    @Bindable var model: LibraryModel
    let id: String

    @AppStorage("showElevation") private var expanded = false
    @State private var hover: ElevationProfile.Sample?

    private var entry: LibraryModel.ProfileEntry? { model.profiles[id] }
    private var key: String? { model.profileKey(for: id) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content.padding(.top, 4)
        } label: {
            HStack {
                Text("Elevation")
                Spacer()
                if let profile = entry?.profile, entry?.key == key {
                    Text("+\(feet(profile.ascent)) ft, −\(feet(profile.descent)) ft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: expanded ? key : nil) {
            guard expanded else { return }
            await model.loadProfile(for: id)
        }
    }

    @ViewBuilder
    private var content: some View {
        if key == nil {
            note("Add a second point for a profile.")
        } else if let entry, entry.key == key {
            if let profile = entry.profile {
                chart(profile)
            } else {
                note("No elevation data here.")
            }
        } else {
            note("Reading the terrain…")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chart(_ profile: ElevationProfile) -> some View {
        let floor = (profile.minimum / 0.3048 / 100).rounded(.down) * 100 - 100
        let ceiling = (profile.maximum / 0.3048 / 100).rounded(.up) * 100 + 100
        return VStack(alignment: .leading, spacing: 2) {
            Chart {
                ForEach(Array(profile.samples.enumerated()), id: \.offset) { _, sample in
                    AreaMark(x: .value("Distance", sample.distance / 1609.344),
                             yStart: .value("Floor", floor),
                             yEnd: .value("Elevation", sample.elevation / 0.3048))
                        .foregroundStyle(Color.accentColor.opacity(0.25))
                    LineMark(x: .value("Distance", sample.distance / 1609.344),
                             y: .value("Elevation", sample.elevation / 0.3048))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                if let hover {
                    RuleMark(x: .value("Here", hover.distance / 1609.344))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: floor...ceiling)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>().precision(.fractionLength(0)))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine()
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>().precision(.fractionLength(0)))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let origin = geometry[proxy.plotFrame!].origin
                                if let miles: Double = proxy.value(atX: location.x - origin.x) {
                                    hover = nearest(miles * 1609.344, in: profile)
                                }
                            case .ended:
                                hover = nil
                            }
                        }
                }
            }
            .frame(height: 110)
            .font(.caption2)

            Text(hover.map { "\(feet($0.elevation)) ft at \(String(format: "%.1f", $0.distance / 1609.344)) mi" }
                 ?? "\(feet(profile.minimum))–\(feet(profile.maximum)) ft over \(String(format: "%.0f", profile.length / 1609.344)) mi")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func nearest(_ metres: Double, in profile: ElevationProfile) -> ElevationProfile.Sample? {
        profile.samples.min { abs($0.distance - metres) < abs($1.distance - metres) }
    }

    private func feet(_ metres: Double) -> String {
        Int((metres / 0.3048).rounded()).formatted()
    }
}
#endif
