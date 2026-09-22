// PROTOTYPE — throwaway. Three iPhone navigation shells for Zulu, switchable from the
// floating bar. Answers: what is the root navigation structure?
import SwiftUI

enum Variant: String, CaseIterable, Identifiable {
    case a = "A", b = "B", c = "C"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .a: VariantA.name
        case .b: VariantB.name
        case .c: VariantC.name
        }
    }
    var next: Variant {
        let all = Variant.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
    var prev: Variant {
        let all = Variant.allCases
        return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
    }
}

@main
struct NavShellApp: App {
    @State private var variant = Variant(rawValue: ProcessInfo.processInfo.environment["VARIANT"] ?? "A") ?? .a

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                switch variant {
                case .a: VariantA()
                case .b: VariantB()
                case .c: VariantC()
                }
                Switcher(variant: $variant)
            }
        }
    }
}

struct Switcher: View {
    @Binding var variant: Variant
    @State private var offsetY: CGFloat = -72
    @State private var dragY: CGFloat = 0
    @State private var collapsed = false

    var body: some View {
        Group {
            if collapsed {
                Button { withAnimation(.snappy) { collapsed = false } } label: {
                    Text(variant.rawValue)
                        .font(.caption.weight(.bold).monospaced())
                        .frame(width: 28, height: 28)
                        .glassEffect(.regular.tint(.yellow).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 10) {
                    button("chevron.left") { variant = variant.prev }
                    VStack(spacing: 0) {
                        Text("\(variant.rawValue) — \(variant.name)")
                            .font(.caption.weight(.bold))
                        Text("prototype")
                            .font(.system(size: 8, weight: .medium))
                            .opacity(0.6)
                    }
                    .frame(width: 140)
                    button("chevron.right") { variant = variant.next }
                    Divider().frame(height: 18)
                    button("minus") { collapsed = true }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(.yellow), in: .capsule)
            }
        }
        .offset(y: offsetY + dragY)
        .gesture(
            DragGesture()
                .onChanged { dragY = $0.translation.height }
                .onEnded { _ in offsetY += dragY; dragY = 0 }
        )
        .padding(.bottom, 4)
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy, action) } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))

                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
