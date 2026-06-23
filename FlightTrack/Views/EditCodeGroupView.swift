import SwiftUI

/// Create or edit a code group: name it and toggle which accepted connections
/// are members (recipients of the group's codes).
struct EditCodeGroupView: View {
    @ObservedObject var vm: CodeGroupsViewModel
    let existing: CodeGroup?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var selected: Set<String>
    @State private var connections: [String] = []
    @State private var loading = true

    init(vm: CodeGroupsViewModel, existing: CodeGroup?) {
        self.vm = vm
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _selected = State(initialValue: Set(existing?.memberEmails ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Group name (e.g. Family)", text: $name)
                }
                Section("Members") {
                    if loading {
                        ProgressView()
                    } else if connections.isEmpty {
                        Text("No accepted connections yet. Add connections first.")
                            .foregroundStyle(.secondary).font(.footnote)
                    } else {
                        ForEach(connections, id: \.self) { email in
                            Button {
                                if selected.contains(email) { selected.remove(email) }
                                else { selected.insert(email) }
                            } label: {
                                HStack {
                                    Text(email).foregroundStyle(.primary)
                                    Spacer()
                                    if selected.contains(email) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Group" : "Edit Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let members = Array(selected)
                            if let existing {
                                await vm.updateGroup(existing, name: name, members: members)
                            } else {
                                await vm.createGroup(name: name, members: members)
                            }
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task {
                connections = await vm.acceptedConnections()
                loading = false
            }
        }
    }
}
