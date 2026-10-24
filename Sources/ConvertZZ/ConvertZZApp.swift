import AppKit
import SwiftUI

@main
struct ConvertZZApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("ConvertZZ") {
            ContentView()
                .environmentObject(AppModel.shared)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以 `swift run` 執行時沒有 .app bundle，需手動設成一般 App 才會出現視窗與 Dock 圖示
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 檔案拖到 Dock 圖示或用「打開方式」開啟時
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.process(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
