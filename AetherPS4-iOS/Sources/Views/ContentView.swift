import SwiftUI

struct ContentView: View {
    // No persistence across launches: the user asked for this check every time the
    // app launches, not once ever -- resetting to false on every fresh ContentView
    // means every cold launch re-verifies rather than trusting a stale prior result.
    @State private var setupVerified = false

    @Environment(EmulatorProcess.self) private var emulator
    @ObservedObject private var theme = AppTheme.shared
    /// "ps4" for the PS4-style home screen (default), "classic" for the tabbed library.
    @AppStorage("homeScreenStyle") private var homeScreenStyle = "ps4"
    /// Off by default: JIT is still requested when a game starts (EmulatorProcess.launch).
    @AppStorage("showStartupCheck") private var showStartupCheck = false

    var body: some View {
        Group {
            if homeScreenStyle == "classic" {
                classicTabs
            } else {
                HomeMenuView()
            }
        }
        .tint(theme.accentColor)
        // fullScreenCover (not .sheet): no swipe-to-dismiss, so the only way past this
        // is actually passing both checks -- matches "only let them proceed if" working.
        .task {
            if !showStartupCheck {
                emulator.resumeIfRestartPending()
            }
        }
        .fullScreenCover(isPresented: Binding(get: { showStartupCheck && !setupVerified }, set: { _ in })) {
            SetupCheckView(onPassed: {
                setupVerified = true
                // Only meaningful right after a restart prompt's exit(0) brought the app
                // back up fresh -- see EmulatorProcess.resumeIfRestartPending()'s own
                // comment. Gated on setup passing first since a normal launch() needs JIT
                // attached too, same requirement this resume goes through.
                emulator.resumeIfRestartPending()
            })
        }
    }

    private var classicTabs: some View {
        TabView {
            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("Library", systemImage: "square.grid.2x2")
            }

            NavigationStack {
                GameStatusView()
            }
            .tabItem {
                Label("Game Status", systemImage: "checklist")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .background(theme.backgroundTint)
    }
}
