import SwiftUI

@main
struct opennuraApp: App {
    @StateObject private var device = NuraDeviceManager()
#if os(macOS)
    @StateObject private var hotkeys = HotKeySettings()
#endif
    
    var body: some Scene {
        WindowGroup {
            content
        }
#if os(macOS)
        MenuBarExtra("Nuraphone", systemImage: "headphones") {
            MenuBarView(device: device)
        }
        .menuBarExtraStyle(.window)
#endif
    }
    
    @ViewBuilder
    private var content: some View {
#if os(macOS)
        ContentView(device: device)
            .environmentObject(hotkeys)
            .onAppear {
                HotKeyCenter.shared.install(handlers: makeHotKeyHandlers())
                HotKeyCenter.shared.apply(hotkeys)
            }
            .onChange(of: hotkeys.enabled) { _, _ in HotKeyCenter.shared.apply(hotkeys) }
            .onChange(of: hotkeys.combos) { _, _ in HotKeyCenter.shared.apply(hotkeys) }
#else
        ContentView(device: device)
#endif
    }
    
#if os(macOS)
    private func makeHotKeyHandlers() -> [HotKeyAction: @MainActor () -> Void] {
        // Capture the manager reference directly (not self), so the closures
        // always talk to the live instance.
        let device = self.device
        return [
            .immersionUp: { device.immersionStep(1) },
            .immersionDown: { device.immersionStep(-1) },
            .toggleAncSocial: { device.toggleAncSocial() },
            .nextProfile: { device.cycleProfile(forward: true) },
            .previousProfile: { device.cycleProfile(forward: false) },
        ]
    }
#endif
}
