import SwiftUI

@main
struct ZuluMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(model)
                .task { await model.bootstrap() }
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .commands {
            // The sidebar toggle is the one command worth having before the rest of
            // the Mac keyboard surface is designed.
            SidebarCommands()
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct MacRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            MacSignInView()
        case .signedIn:
            MacShellView()
        }
    }
}
