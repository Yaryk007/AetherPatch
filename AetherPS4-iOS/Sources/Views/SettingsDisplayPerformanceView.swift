import SwiftUI
import UIKit

struct SettingsDisplayPerformanceView: View {
    @AppStorage("showFpsCounter") private var showFpsCounter: Bool = true
    @AppStorage("consoleLoggingEnabled") private var consoleLoggingEnabled: Bool = false
    @AppStorage("performanceOverlayEnabled") private var performanceOverlayEnabled: Bool = false
    /// See shadps4_set_aspect_mode. Applied live, and again at every game launch.
    @AppStorage("aspectRatioMode") private var aspectRatioMode = 0
    /// See shadps4_set_resolution_override / WidescreenHack. Applies from the next launch.
    @AppStorage("widescreenHack") private var widescreenHack = false

    var body: some View {
        Form {
            Section {
                Toggle("Show In-Game FPS Counter", isOn: $showFpsCounter)
                Toggle("Console Logging", isOn: $consoleLoggingEnabled)
                Toggle("Performance Overlay", isOn: $performanceOverlayEnabled)
            }

            Section {
                Toggle("Widescreen Hack", isOn: $widescreenHack)
                Picker("Aspect Ratio", selection: $aspectRatioMode) {
                    Text("Auto").tag(0)
                    Text("Stretch to Window").tag(1)
                    Text("Zoom to Fill").tag(2)
                }
                .onChange(of: aspectRatioMode) { _, mode in shadps4_set_aspect_mode(Int32(mode)) }
            } header: {
                Text("Widescreen")
            } footer: {
                Text(widescreenHack
                     ? "Widescreen Hack renders games at \(WidescreenHack.resolutionDescription) to match this screen, so games that size their view from the screen show more at the sides and the black bars go away. Games that are locked to 16:9 may look stretched or show glitches at the edges. Takes effect the next time you start a game."
                     : "Auto keeps the game's 16:9 picture with black bars on wider screens. Stretch to Window stretches it to fill the screen. Zoom to Fill fills the screen without distortion by cropping the top and bottom. Widescreen Hack renders the game itself at this screen's shape instead.")
            }
        }
        .navigationTitle("Display & Performance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Picks the render resolution the widescreen hack reports to games: the configured render
/// height, with the width stretched to this device's landscape aspect ratio.
@MainActor
enum WidescreenHack {
    static var resolution: (width: Int, height: Int) {
        let bounds = UIScreen.main.nativeBounds
        let aspect = max(bounds.width, bounds.height) / max(min(bounds.width, bounds.height), 1)
        let height = max(ConfigStore.shared.int("GPU", "internal_screen_height", default: 720), 360)
        // Keep the width a multiple of 8 -- render targets and tiling dislike odd sizes.
        let width = Int((Double(height) * Double(aspect) / 8).rounded()) * 8
        return (width, height)
    }

    static var resolutionDescription: String {
        let r = resolution
        return "\(r.width)×\(r.height)"
    }

    /// Called right before a game starts.
    static func apply() {
        if UserDefaults.standard.bool(forKey: "widescreenHack") {
            let r = resolution
            shadps4_set_resolution_override(UInt32(r.width), UInt32(r.height))
        } else {
            shadps4_set_resolution_override(0, 0)
        }
    }
}
