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
        // No title: the window buttons stand in a strip of their own, centred
        // in it as the unified toolbar does. The version is in About.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)

        // Opened from the menu-bar item; the app has no menu bar of its own.
        Settings {
            SettingsView().environmentObject(vpn)
        }

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
