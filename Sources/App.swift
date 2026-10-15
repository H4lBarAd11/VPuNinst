// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
import SwiftUI

@main
struct VPuNinstApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var vpn = Tunnels()

    var body: some Scene {
        Window(Brand.name, id: "main") {
            MainView().environmentObject(vpn)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuContent().environmentObject(vpn)
        } label: {
            Image(nsImage: MenuIcon.image(up: vpn.anyUp))
                .accessibilityLabel(vpn.anyUp ? "\(Brand.name), connected" : "\(Brand.name), not connected")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ n: Notification) { Theme.registerFonts() }
    // SwiftUI has put the main window up by now, and nothing has been drawn.
    func applicationDidFinishLaunching(_ n: Notification) { Splash.show() }
    // Closing the window leaves the menu-bar item watching the tunnels.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}
