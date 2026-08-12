import AppKit
import SwiftUI

@main
struct NextDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EffectModel.shared

    var body: some Scene {
        MenuBarExtra {
            EffectPanel(model: model)
        } label: {
            Label(
                "За стеной",
                systemImage: model.isEnabled ? "waveform.circle.fill" : "waveform.circle"
            )
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        EffectModel.shared.shutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "nextdoor" && $0.host == "toggle" }) else {
            return
        }

        Task { @MainActor in
            await EffectModel.shared.toggle()
        }
    }
}
