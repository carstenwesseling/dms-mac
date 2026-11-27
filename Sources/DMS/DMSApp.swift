import AppKit
import SwiftUI

@main
struct DMSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("DMS") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 600)
                .onAppear { state.startBackgroundWork() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Ordner hinzufügen …") { state.addSourceWithPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Alle Quellen neu scannen") { state.scanAll() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

/// Sorgt dafür, dass die App beim Start aus Xcode bzw. `swift run` als normales Fenster erscheint.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Fenster nach vorne holen (beim Start aus Xcode liegt es sonst oft hinter Xcode)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }

    /// App bleibt offen, auch wenn das Fenster geschlossen wird (über das Dock wieder öffnen).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
