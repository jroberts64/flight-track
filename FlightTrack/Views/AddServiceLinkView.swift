import SwiftUI

/// Link a service to a group: pick a preset (or custom), choose the group that
/// receives its codes. The match rules drive how the backend recognizes the
/// service's emails and extracts the code.
struct AddServiceLinkView: View {
    @ObservedObject var vm: CodeGroupsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPreset: ServicePreset? = ServicePreset.presets.first
    @State private var customName = ""
    @State private var customRules = #"{"fromContains":"","subjectContains":"code","codeRegex":"\\b(\\d{4,8})\\b"}"#
    @State private var groupId: String = ""

    private var isCustom: Bool { selectedPreset == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    Picker("Service", selection: $selectedPreset) {
                        ForEach(ServicePreset.presets) { preset in
                            Text(preset.name).tag(Optional(preset))
                        }
                        Text("Custom…").tag(Optional<ServicePreset>.none)
                    }
                    if isCustom {
                        TextField("Service name", text: $customName)
                        TextField("Match rules (JSON)", text: $customRules, axis: .vertical)
                            .font(.caption).monospaced()
                    }
                }

                Section("Send codes to") {
                    if vm.groups.isEmpty {
                        Text("Create a group first.").foregroundStyle(.secondary).font(.footnote)
                    } else {
                        Picker("Group", selection: $groupId) {
                            ForEach(vm.groups) { group in
                                Text(group.name).tag(group.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Link a Service")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = isCustom ? customName : (selectedPreset?.name ?? "")
                        let rules = isCustom ? customRules : (selectedPreset?.matchRules ?? "")
                        Task {
                            await vm.addServiceLink(serviceName: name, groupId: groupId, matchRules: rules)
                            dismiss()
                        }
                    }
                    .disabled(saveDisabled)
                }
            }
            .onAppear { if groupId.isEmpty { groupId = vm.groups.first?.id ?? "" } }
        }
    }

    private var saveDisabled: Bool {
        if groupId.isEmpty { return true }
        if isCustom { return customName.trimmingCharacters(in: .whitespaces).isEmpty }
        return selectedPreset == nil
    }
}
