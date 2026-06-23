import SwiftUI

/// "Codes" tab: groups you share service codes with, the services linked to
/// them, and the forwarding address to set up the email rule.
struct CodeGroupsView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = CodeGroupsViewModel()
    @State private var showingNewGroup = false
    @State private var showingAddService = false
    @State private var editingGroup: CodeGroup?

    var body: some View {
        NavigationStack {
            List {
                forwardingSection
                groupsSection
                servicesSection
            }
            .navigationTitle("Codes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showingNewGroup = true } label: { Label("New group", systemImage: "person.3") }
                        Button { showingAddService = true } label: { Label("Link a service", systemImage: "key") }
                            .disabled(vm.groups.isEmpty)
                    } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await vm.reload() }
            .alert("Heads up", isPresented: .constant(vm.errorMessage != nil)) {
                Button("OK") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .sheet(isPresented: $showingNewGroup) {
                EditCodeGroupView(vm: vm, existing: nil)
            }
            .sheet(item: $editingGroup) { group in
                EditCodeGroupView(vm: vm, existing: group)
            }
            .sheet(isPresented: $showingAddService) {
                AddServiceLinkView(vm: vm)
            }
        }
        .task { vm.start(ownerEmail: session.email) }
    }

    private var forwardingSection: some View {
        Section("Forward codes here") {
            HStack {
                Text(vm.forwardingAddress)
                    .font(.subheadline).monospaced()
                    .textSelection(.enabled)
                Spacer()
                Button {
                    UIPasteboard.general.string = vm.forwardingAddress
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
            }
            Text("Set up an email rule that forwards your service code emails to this address. The code is then pushed to the linked group.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var groupsSection: some View {
        Section("Groups") {
            if vm.groups.isEmpty {
                Text("No groups yet. Tap + to create one from your connections.")
                    .foregroundStyle(.secondary).font(.footnote)
            }
            ForEach(vm.groups) { group in
                Button { editingGroup = group } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.headline).foregroundStyle(.primary)
                        Text(group.memberEmails.isEmpty ? "No members" : group.memberEmails.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { Task { await vm.deleteGroup(group) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var servicesSection: some View {
        Section("Services") {
            if vm.serviceLinks.isEmpty {
                Text("No services linked yet.")
                    .foregroundStyle(.secondary).font(.footnote)
            }
            ForEach(vm.serviceLinks) { link in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(link.serviceName).font(.headline)
                        Spacer()
                        Text("→ \(vm.groupName(for: link.groupId))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let event = vm.latestCodes[link.serviceName] {
                        Text("Latest code: \(event.code)")
                            .font(.subheadline).monospaced().foregroundStyle(.green)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { Task { await vm.deleteServiceLink(link) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
}
