#if os(macOS)
import SwiftUI

/// The selected route's turns, under its fields in the inspector: what
/// BaseCamp puts on a route's Directions tab. Closed until opened, and
/// remembered, since a planner who wants the list wants it for every
/// route and one who does not wants the sidebar back.
///
/// Clicking a turn looks at it on the map. The list never reaches the
/// device: Garmin's format carries the road and the unit narrates it
/// itself, so this is for planning and printing, as BaseCamp's was.
struct DirectionsPane: View {
    @Bindable var model: LibraryModel
    let detail: RouteDetail

    @AppStorage("showDirections") private var expanded = false

    private var entry: LibraryModel.DirectionsEntry? { model.directionsByRoute[detail.route.id] }
    private var key: String? { model.directionsKey(for: detail.route.id) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content
                .padding(.top, 4)
        } label: {
            HStack {
                Text("Directions")
                Spacer()
                if let directions = entry?.directions, entry?.key == key {
                    Text("\(Self.miles(directions.length)) · \(Self.duration(directions.time))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        // Recomputed when the route or its settings change, and only
        // while the pane is open: closed, the list is not worth a search.
        .task(id: expanded ? key : nil) {
            guard expanded else { return }
            await model.loadDirections(for: detail.route.id)
        }
    }

    @ViewBuilder
    private var content: some View {
        if detail.route.mode == .direct {
            note("A direct route has no turns.")
        } else if detail.points.count < 2 {
            note("Add a second point for directions.")
        } else if key == nil {
            note("Routing…")
        } else if let entry, entry.key == key {
            if let directions = entry.directions {
                list(directions)
            } else {
                note(entry.failure.map { "No directions: \($0)" } ?? "No directions.")
            }
        } else {
            note("Calculating…")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(_ directions: RouteDirections) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(directions.maneuvers) { maneuver in
                    row(maneuver)
                    if maneuver.id < directions.maneuvers.count - 1 { Divider() }
                }
            }
        }
        .frame(maxHeight: 260)
    }

    private func row(_ maneuver: RouteDirections.Maneuver) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: maneuver.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(maneuver.instruction)
                    .fixedSize(horizontal: false, vertical: true)
                if maneuver.length > 0 {
                    // The stretch after this turn, which is what a rider
                    // wants to know about it.
                    Text("\(Self.miles(maneuver.length)) · \(Self.duration(maneuver.time))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(Self.miles(maneuver.distanceFromStart))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.look(at: maneuver.coordinate) }
        .help("Show on the map")
    }

    static func miles(_ metres: Double) -> String {
        let miles = metres / 1609.344
        return miles < 10 ? String(format: "%.1f mi", miles) : String(format: "%.0f mi", miles)
    }

    /// "4 h 12 min", "18 min", "< 1 min".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
#endif
