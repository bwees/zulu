import SwiftUI
import ZuluStore

/// Drag the rail's groups into the order you want. A sheet for the same reason as
/// ``ReorderChannelsView``: the drawer already spends its drags and long presses.
struct ReorderGroupsView: View {
    let groups: [ChannelGroupSummary]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var ordered: [ChannelGroupSummary] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(ordered) { group in
                    HStack(spacing: 10) {
                        GroupAvatar(name: group.name, icon: group.icon, size: 28)
                        Text(group.name).lineLimit(1)
                    }
                }
                .onMove { source, destination in
                    ordered.move(fromOffsets: source, toOffset: destination)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        model.reorderGroups(ordered.map(\.id))
                        dismiss()
                    }
                }
            }
            .task { if ordered.isEmpty { ordered = groups } }
        }
    }
}
