import AppKit
import SwiftUI

@main
struct EKStreamDLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WebAppView()
                .frame(minWidth: 920, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 700)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("偏好设置…") {
                    NSApp.sendAction(#selector(AppDelegate.showPreferencesWindow(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}
