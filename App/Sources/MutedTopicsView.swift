import GRDB
import SwiftUI
import ZuluStore

/// A channel's muted topics. Muting takes a topic out of every list, so this is the only
/// way back to one.
struct MutedTopicsView: View {
    let channel: ChannelSummary

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var topics: [MutedTopicRecord] = []

    var body: some View {
        NavigationStack {
            Group {
                if topics.isEmpty {
                    ContentUnavailableView(
                        "Nothing muted",
                        systemImage: "bell",
                        description: Text("Long-press a topic to mute it.")
                    )
                } else {
                    List(topics, id: \.topic) { topic in
                        HStack {
                            Text(topic.topic.isEmpty ? "general chat" : topic.topic)
                            Spacer()
                            Button("Unmute") {
                                Task { await model.setMuted(false, topic: topic.topic, inChannel: channel.id) }
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Muted in #\(channel.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await observe() }
        }
    }

    private func observe() async {
        guard let writer = model.databaseWriter,
              let observation = model.mutedTopicObservation(inChannel: channel.id)
        else { return }
        do {
            for try await rows in observation.values(in: writer) { topics = rows }
        } catch {
            // Ends with the sheet; nothing to recover.
        }
    }
}
