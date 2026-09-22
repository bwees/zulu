// PROTOTYPE — throwaway. The chosen iPhone navigation shell: an edge rail of channel
// groups and a channel drawer that the message pane slides off of.
//
// Two rejected shells — a native tab bar and a flat topic inbox — live on the
// prototype/nav-shell-variants branch.
import SwiftUI

@main
struct NavShellApp: App {
    var body: some Scene {
        WindowGroup {
            DrawerShell()
        }
    }
}
