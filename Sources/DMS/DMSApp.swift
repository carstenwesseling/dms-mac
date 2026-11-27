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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
