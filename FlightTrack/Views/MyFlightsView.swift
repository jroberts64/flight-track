import SwiftUI

struct MyFlightsView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = FlightsViewModel()
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.flights.isEmpty && !vm.isLoading {
                    ContentUnavailableView(
                        "No flights yet",
                        systemImage: "airplane.departure",
                        description: Text("Tap + to add a flight by its number.")
                    )
                } else {
                    List {
                        ForEach(vm.flights) { flight in
                            FlightRowView(flight: flight)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        Task { await vm.delete(flight) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                    Button {
                                        Task { await vm.refreshStatus(for: flight) }
                                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                                    .tint(.blue)
                                }
                        }
                    }
                    .refreshable { await vm.reload() }
                }
            }
            .navigationTitle("My Flights")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddFlightView { number, date, note in
                    Task { await vm.addFlight(flightNumber: number, date: date, note: note) }
                }
            }
            .overlay {
                if vm.isLoading { ProgressView() }
            }
            .alert("Heads up", isPresented: .constant(vm.errorMessage != nil)) {
                Button("OK") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
        }
        .task {
            if let profileId = session.profileId {
                vm.start(profileId: profileId, ownerEmail: session.email)
            }
        }
    }
}

struct AddFlightView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flightNumber = ""
    @State private var date = Date()
    @State private var note = ""

    let onAdd: (String, Date, String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Flight") {
                    TextField("Flight number (e.g. UA328)", text: $flightNumber)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    DatePicker("Departure date", selection: $date, displayedComponents: .date)
                }
                Section("Note (optional)") {
                    TextField("e.g. Picking up Mom", text: $note)
                }
            }
            .navigationTitle("Add Flight")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(flightNumber, date, note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(flightNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
