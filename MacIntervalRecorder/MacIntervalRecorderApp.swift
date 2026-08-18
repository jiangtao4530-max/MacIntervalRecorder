import SwiftUI

@main
struct MacIntervalRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = RecorderController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

