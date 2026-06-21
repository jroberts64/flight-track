import SwiftUI

/// Reusable row showing a flight's route, times, and live status.
struct FlightRowView: View {
    let flight: Flight

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(flight.flightNumber)
                    .font(.headline)
                Spacer()
                StatusBadge(status: flight.status, delayed: flight.isDelayed)
            }

            HStack(spacing: 8) {
                Text(flight.originIata.isEmpty ? "—" : flight.originIata)
                    .font(.title3).bold()
                Image(systemName: "airplane")
                    .foregroundStyle(.secondary)
                Text(flight.destinationIata.isEmpty ? "—" : flight.destinationIata)
                    .font(.title3).bold()
                Spacer()
            }

            HStack {
                timeColumn(label: "Departs", date: flight.effectiveDeparture, gate: flight.originGate, terminal: flight.originTerminal)
                Spacer()
                timeColumn(label: "Arrives", date: flight.effectiveArrival, gate: flight.destinationGate, terminal: flight.destinationTerminal, alignment: .trailing)
            }

            if let note = flight.note, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func timeColumn(label: String, date: Date?, gate: String?, terminal: String?, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            if let date {
                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline).monospacedDigit()
            } else {
                Text("—").font(.subheadline).monospacedDigit()
            }
            if gate != nil || terminal != nil {
                Text([terminal.map { "T\($0)" }, gate.map { "Gate \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBadge: View {
    let status: FlightStatus
    var delayed: Bool = false

    var body: some View {
        Text(delayed && status != .cancelled ? "Delayed" : status.label)
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        if delayed { return .orange }
        switch status {
        case .landed: return .green
        case .enroute, .departed, .boarding: return .blue
        case .cancelled, .diverted: return .red
        case .delayed: return .orange
        default: return .gray
        }
    }
}
