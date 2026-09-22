import SwiftUI

struct EmojiPicker: View {
    let insert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private static let groups: [(String, [String])] = [
        ("Smileys", ["😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃","😉","😊","😇","🥰","😍","🤩","😘","😗","😚","😙","😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫","🤔","🤐","🤨","😐","😑","😶","😏","😒","🙄","😬","😮‍💨","🤥","😌","😔","😪","🤤","😴","😷","🤒","🤕","🤢","🤮","🥵","🥶","😵","🤯","🤠","🥳","😎","🤓","🧐","😕","😟","🙁","😮","😯","😲","😳","🥺","😦","😧","😨","😰","😥","😢","😭","😱","😖","😣","😞","😓","😩","😫","🥱","😤","😡","😠","🤬"]),
        ("Gestures", ["👍","👎","👌","🤌","✌️","🤞","🤟","🤘","🤙","👈","👉","👆","👇","☝️","✋","🤚","🖐️","🖖","👋","🤝","🙏","💪","🦾","👏","🙌","👐","🤲","🫶","❤️","🧡","💛","💚","💙","💜","🖤","🤍","💔","❤️‍🔥","✨","⭐","🌟","💫","🔥","💯","✅","❌","⚠️","🎉","🎊","🚀","👀","🧠","💡"]),
        ("Objects", ["💻","🖥️","⌨️","🖱️","📱","🗒️","📌","📎","🔒","🔑","🔧","🔨","⚙️","🧪","🔬","📦","📮","📊","📈","📉","🗓️","⏰","⏳","🔔","🔕","📢","🎧","🎵","☕","🍕","🍔","🍟","🌮","🍰","🍺","🍻","🥂","🎂","🍎","🥑"]),
        ("Nature", ["🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯","🦁","🐮","🐷","🐸","🐵","🐔","🐧","🐦","🦆","🦉","🦇","🐺","🐗","🐴","🦄","🐝","🐛","🦋","🌸","🌼","🌻","🌲","🌴","🌵","🍀","🍁","🌊","🌈","☀️","🌙"]),
    ]

    private var results: [(String, [String])] {
        guard !query.isEmpty else { return Self.groups }
        let matches = Self.groups.flatMap(\.1).filter { _ in false }
        return matches.isEmpty ? Self.groups : [("Results", matches)]
    }

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    ForEach(results, id: \.0) { group in
                        Section {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(group.1, id: \.self) { emoji in
                                    Button {
                                        insert(emoji)
                                        dismiss()
                                    } label: {
                                        Text(emoji).font(.system(size: 30))
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            Text(group.0)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .background(.bar)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle("Emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
