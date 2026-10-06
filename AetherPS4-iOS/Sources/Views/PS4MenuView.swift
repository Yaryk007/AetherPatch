import AudioToolbox
import SwiftUI
import UIKit

// PS4-style menus that replace the regular SwiftUI screens while the PS4 home screen is on:
// a vertical list on the wave background with the focused row lit up, the value of each
// setting on the right, a description of the focused row at the bottom, and full controller
// navigation (up/down to move, left/right to change a value, Cross to select, Circle to go
// back). Screens that need system pickers (files, photos, drives) open their classic view.

// MARK: - Model

struct PS4MenuItem: Identifiable {
    enum Kind {
        case toggle(get: () -> Bool, set: (Bool) -> Void)
        case choice(options: [String], get: () -> Int, set: (Int) -> Void)
        case stepper(range: ClosedRange<Int>, step: Int, get: () -> Int, set: (Int) -> Void,
                     format: (Int) -> String)
        case link(() -> PS4MenuPage)
        case action(() -> Void)
        case classic(() -> AnyView)
        case info(() -> String)
    }

    let title: String
    let icon: String
    var detail: String = ""
    var isDestructive = false
    let kind: Kind

    var id: String { title }
}

struct PS4MenuPage {
    let title: String
    let icon: String
    let items: () -> [PS4MenuItem]
}

/// Which PS4 menu the home screen opened.
enum PS4MenuRoot: String, Identifiable {
    case settings, library, profile

    var id: String { rawValue }
}

// MARK: - View

struct PS4MenuView: View {
    let root: PS4MenuRoot
    let onClose: () -> Void

    @Environment(GameLibrary.self) private var library
    @Environment(EmulatorProcess.self) private var emulator
    @StateObject private var input = HomeControllerInput()
    @AppStorage("homeMenuSounds") private var soundsEnabled = true

    @State private var stack: [PS4MenuPage] = []
    @State private var focus: [Int] = [0]
    @State private var revision = 0
    @State private var classicScreen: ClassicScreen?
    @State private var confirmation: PS4Confirmation?
    @State private var isImporterPresented = false

    private var page: PS4MenuPage? { stack.last }
    private var items: [PS4MenuItem] {
        _ = revision
        return page?.items() ?? []
    }
    private var focusedIndex: Int {
        min(focus.last ?? 0, max(items.count - 1, 0))
    }

    var body: some View {
        ZStack {
            PS4WaveBackground(paused: emulator.isRunning)
                .overlay(Color.black.opacity(0.35))
                .ignoresSafeArea()

            GeometryReader { geo in
                let unit = min(min(geo.size.width, geo.size.height), 700)
                VStack(alignment: .leading, spacing: 0) {
                    header(unit: unit)
                    list(unit: unit)
                    footer(unit: unit)
                }
                .padding(.horizontal, max(geo.size.width * 0.07, 20))
                .padding(.vertical, 14)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if stack.isEmpty {
                stack = [rootPage]
                focus = [0]
            }
            input.onCommand = handle
            input.start()
        }
        .onDisappear { input.stop() }
        .sheet(item: $classicScreen) { screen in
            NavigationStack {
                screen.view()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { classicScreen = nil }
                        }
                    }
            }
            .environment(library)
            .environment(emulator)
            .onDisappear { revision += 1 }
        }
        .alert(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        )) {
            Button(confirmation?.actionTitle ?? "OK", role: .destructive) {
                confirmation?.action()
                confirmation = nil
                revision += 1
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation?.message ?? "")
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.pkgPackage],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                await library.importPkg(from: url)
                revision += 1
            }
        }
    }

    // MARK: Layout

    private func header(unit: CGFloat) -> some View {
        HStack(spacing: unit * 0.025) {
            Image(systemName: page?.icon ?? "gearshape")
                .font(.system(size: unit * 0.05, weight: .light))
            Text(page?.title ?? "")
                .font(.system(size: unit * 0.058, weight: .light))
            Spacer()
            if stack.count > 1 {
                Text(stack.dropLast().map(\.title).joined(separator: "  ›  "))
                    .font(.system(size: unit * 0.028))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.bottom, unit * 0.03)
        .contentShape(Rectangle())
        .onTapGesture { goBack() }
    }

    private func list(unit: CGFloat) -> some View {
        let current = items
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: unit * 0.008) {
                    ForEach(Array(current.enumerated()), id: \.offset) { index, item in
                        PS4MenuRow(item: item, isFocused: index == focusedIndex, unit: unit,
                                   adjust: { delta in adjust(item, by: delta) })
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                setFocus(index)
                                activate(item)
                            }
                    }
                    if current.isEmpty {
                        Text("Nothing here yet.")
                            .font(.system(size: unit * 0.035, weight: .light))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.top, unit * 0.05)
                    }
                }
                .padding(.vertical, unit * 0.01)
            }
            .onChange(of: focusedIndex) { _, index in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    private func footer(unit: CGFloat) -> some View {
        HStack(alignment: .bottom) {
            let detail = items.indices.contains(focusedIndex) ? items[focusedIndex].detail : ""
            Text(detail)
                .font(.system(size: unit * 0.03))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: unit * 0.035) {
                hint("xmark.circle", "Enter", unit)
                hint("circle.circle", "Back", unit)
            }
            .opacity(input.isConnected ? 1 : 0)
        }
        .padding(.top, unit * 0.02)
    }

    private func hint(_ symbol: String, _ text: String, _ unit: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.system(size: unit * 0.03))
        .foregroundStyle(.white.opacity(0.8))
    }

    // MARK: Behaviour

    private func setFocus(_ index: Int) {
        guard !focus.isEmpty else { return }
        focus[focus.count - 1] = index
    }

    private func activate(_ item: PS4MenuItem) {
        switch item.kind {
        case .toggle(let get, let set):
            set(!get())
            revision += 1
            playSound(1104)
        case .choice(let options, let get, let set):
            set((get() + 1) % max(options.count, 1))
            revision += 1
            playSound(1104)
        case .stepper:
            adjust(item, by: 1)
        case .link(let makePage):
            playSound(1103)
            withAnimation(.easeOut(duration: 0.2)) {
                stack.append(makePage())
                focus.append(0)
            }
        case .action(let perform):
            playSound(1103)
            perform()
            revision += 1
        case .classic(let makeView):
            playSound(1103)
            classicScreen = ClassicScreen(title: item.title, view: makeView)
        case .info:
            break
        }
    }

    private func adjust(_ item: PS4MenuItem, by delta: Int) {
        switch item.kind {
        case .choice(let options, let get, let set):
            let count = max(options.count, 1)
            set((get() + delta + count) % count)
        case .stepper(let range, let step, let get, let set, _):
            set(min(max(get() + delta * step, range.lowerBound), range.upperBound))
        case .toggle(let get, let set):
            set(delta > 0)
            _ = get
        default:
            return
        }
        revision += 1
        playSound(1104)
    }

    private func goBack() {
        playSound(1104)
        if stack.count > 1 {
            withAnimation(.easeOut(duration: 0.2)) {
                stack.removeLast()
                focus.removeLast()
            }
        } else {
            onClose()
        }
    }

    private func handle(_ command: HomeControllerInput.Command) {
        guard !emulator.isRunning else { return }
        if classicScreen != nil {
            if command == .back { classicScreen = nil }
            return
        }
        guard confirmation == nil, !isImporterPresented else { return }
        let current = items
        switch command {
        case .up:
            if focusedIndex > 0 {
                setFocus(focusedIndex - 1)
                playSound(1104)
            }
        case .down:
            if focusedIndex < current.count - 1 {
                setFocus(focusedIndex + 1)
                playSound(1104)
            }
        case .left, .right:
            if current.indices.contains(focusedIndex) {
                adjust(current[focusedIndex], by: command == .left ? -1 : 1)
            }
        case .confirm:
            if current.indices.contains(focusedIndex) {
                activate(current[focusedIndex])
            }
        case .back:
            goBack()
        case .options:
            break
        }
    }

    private func playSound(_ id: UInt32) {
        guard soundsEnabled else { return }
        AudioServicesPlaySystemSoundWrapper.play(id)
    }

    // MARK: Pages

    private var rootPage: PS4MenuPage {
        switch root {
        case .settings: PS4MenuPages.settings(context: context)
        case .library: PS4MenuPages.library(context: context)
        case .profile: PS4MenuPages.personalization(context: context)
        }
    }

    private var context: PS4MenuContext {
        PS4MenuContext(
            library: library,
            emulator: emulator,
            openClassic: { title, view in classicScreen = ClassicScreen(title: title, view: view) },
            confirm: { confirmation = $0 },
            importGame: { isImporterPresented = true },
            close: onClose
        )
    }
}

private struct ClassicScreen: Identifiable {
    let title: String
    let view: () -> AnyView
    var id: String { title }
}

struct PS4Confirmation {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void
}

/// What the page builders can reach: app state and ways to leave the PS4 menu.
struct PS4MenuContext {
    let library: GameLibrary
    let emulator: EmulatorProcess
    let openClassic: (String, @escaping () -> AnyView) -> Void
    let confirm: (PS4Confirmation) -> Void
    let importGame: () -> Void
    let close: () -> Void
}

private enum AudioServicesPlaySystemSoundWrapper {
    static func play(_ id: UInt32) {
        AudioServicesPlaySystemSound(id)
    }
}

// MARK: - Row

private struct PS4MenuRow: View {
    let item: PS4MenuItem
    let isFocused: Bool
    let unit: CGFloat
    let adjust: (Int) -> Void

    var body: some View {
        HStack(spacing: unit * 0.03) {
            Image(systemName: item.icon)
                .font(.system(size: unit * 0.038, weight: .light))
                .frame(width: unit * 0.06)
            Text(item.title)
                .font(.system(size: unit * 0.038, weight: isFocused ? .regular : .light))
                .foregroundStyle(item.isDestructive ? Color(red: 1, green: 0.55, blue: 0.55) : .white)
                .lineLimit(1)
            Spacer(minLength: unit * 0.02)
            value
        }
        .foregroundStyle(.white)
        .padding(.horizontal, unit * 0.03)
        .padding(.vertical, unit * 0.022)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [.white.opacity(isFocused ? 0.26 : 0.0),
                                              .white.opacity(isFocused ? 0.12 : 0.0)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.white.opacity(isFocused ? 0.85 : 0), lineWidth: 1.5)
        )
        .shadow(color: .white.opacity(isFocused ? 0.3 : 0), radius: 8)
        .overlay(alignment: .bottom) {
            if !isFocused {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    @ViewBuilder
    private var value: some View {
        let font = Font.system(size: unit * 0.034, weight: .light)
        switch item.kind {
        case .toggle(let get, _):
            Image(systemName: get() ? "checkmark.square.fill" : "square")
                .font(.system(size: unit * 0.04, weight: .light))
                .foregroundStyle(get() ? Color(red: 0.45, green: 0.75, blue: 1) : .white.opacity(0.7))
        case .choice(let options, let get, _):
            adjuster(text: options.indices.contains(get()) ? options[get()] : "", font: font)
        case .stepper(_, _, let get, _, let format):
            adjuster(text: format(get()), font: font)
        case .link, .classic:
            Image(systemName: "chevron.right")
                .font(.system(size: unit * 0.03, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
        case .info(let text):
            Text(text()).font(font).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        case .action:
            EmptyView()
        }
    }

    private func adjuster(text: String, font: Font) -> some View {
        HStack(spacing: unit * 0.02) {
            Image(systemName: "chevron.left")
                .opacity(isFocused ? 0.8 : 0)
                .onTapGesture { adjust(-1) }
            Text(text).font(font).lineLimit(1)
            Image(systemName: "chevron.right")
                .opacity(isFocused ? 0.8 : 0)
                .onTapGesture { adjust(1) }
        }
        .font(.system(size: unit * 0.028, weight: .light))
        .foregroundStyle(.white.opacity(0.85))
    }
}

// MARK: - Bindings

@MainActor
private enum Setting {
    static func configBool(_ section: String, _ key: String, _ def: Bool) -> PS4MenuItem.Kind {
        .toggle(get: { ConfigStore.shared.bool(section, key, default: def) },
                set: { ConfigStore.shared.setBool(section, key, $0) })
    }

    static func defaultsBool(_ key: String, _ def: Bool, inverted: Bool = false) -> PS4MenuItem.Kind {
        .toggle(get: {
                    let value = UserDefaults.standard.object(forKey: key) as? Bool ?? def
                    return inverted ? !value : value
                },
                set: { UserDefaults.standard.set(inverted ? !$0 : $0, forKey: key) })
    }

    static func configChoice(_ section: String, _ key: String, _ options: [String], _ def: Int) -> PS4MenuItem.Kind {
        .choice(options: options,
                get: { ConfigStore.shared.int(section, key, default: def) },
                set: { ConfigStore.shared.setInt(section, key, $0) })
    }

    static func configStepper(_ section: String, _ key: String, _ range: ClosedRange<Int>, step: Int,
                              _ def: Int, format: @escaping (Int) -> String) -> PS4MenuItem.Kind {
        .stepper(range: range, step: step,
                 get: { ConfigStore.shared.int(section, key, default: def) },
                 set: { ConfigStore.shared.setInt(section, key, $0) },
                 format: format)
    }
}

// MARK: - Pages

@MainActor
enum PS4MenuPages {
    static func settings(context: PS4MenuContext) -> PS4MenuPage {
        PS4MenuPage(title: "Settings", icon: "gearshape") {
            [
                PS4MenuItem(title: "Personalization", icon: "paintbrush",
                            detail: "Home screen style, sounds, profile and theme color.",
                            kind: .link { personalization(context: context) }),
                PS4MenuItem(title: "Display and Performance", icon: "gauge.with.dots.needle.67percent",
                            detail: "FPS counter, overlays and widescreen.",
                            kind: .link { displayPerformance() }),
                PS4MenuItem(title: "System", icon: "cpu",
                            detail: "PS4 Pro mode, dev kit mode, memory and splash screen.",
                            kind: .link { console() }),
                PS4MenuItem(title: "Network", icon: "network",
                            detail: "Online features.",
                            kind: .link { network() }),
                PS4MenuItem(title: "Graphics", icon: "cube",
                            detail: "Render resolution, upscaling and GPU options.",
                            kind: .link { graphics() }),
                PS4MenuItem(title: "Sound", icon: "speaker.wave.2",
                            detail: "Audio backend and output.",
                            kind: .link { audio() }),
                PS4MenuItem(title: "Devices", icon: "gamecontroller",
                            detail: "Controllers, motion and the touch controls.",
                            kind: .link { input(context: context) }),
                PS4MenuItem(title: "Storage", icon: "externaldrive",
                            detail: "Where games are installed, including external drives.",
                            kind: .classic { AnyView(SettingsStorageView()) }),
                PS4MenuItem(title: "System Modules", icon: "shippingbox",
                            detail: "Import system modules dumped from your own PS4.",
                            kind: .classic { AnyView(SettingsSystemModulesView()) }),
                PS4MenuItem(title: "Debug", icon: "wrench.and.screwdriver",
                            detail: "Diagnostics for testing games.",
                            kind: .link { advanced(context: context) }),
                PS4MenuItem(title: "Compatibility List", icon: "checklist",
                            detail: "How well known games run.",
                            kind: .classic { AnyView(GameStatusView()) }),
            ]
        }
    }

    static func personalization(context: PS4MenuContext) -> PS4MenuPage {
        PS4MenuPage(title: "Personalization", icon: "paintbrush") {
            let theme = AppTheme.shared
            let presets = AppTheme.presets
            return [
                PS4MenuItem(title: "Profile", icon: "person.crop.circle",
                            detail: "Change your username and picture.",
                            kind: .classic { AnyView(SettingsPersonalizationView()) }),
                PS4MenuItem(title: "Home Screen", icon: "house",
                            detail: "PS4 replaces the app's menus with these. Classic uses the tabbed library.",
                            kind: .choice(options: ["PS4", "Classic"],
                                          get: { UserDefaults.standard.string(forKey: "homeScreenStyle") == "classic" ? 1 : 0 },
                                          set: { UserDefaults.standard.set($0 == 1 ? "classic" : "ps4", forKey: "homeScreenStyle") })),
                PS4MenuItem(title: "Navigation Sounds", icon: "speaker.wave.1",
                            detail: "Clicks when moving around the PS4 menus.",
                            kind: Setting.defaultsBool("homeMenuSounds", true)),
                PS4MenuItem(title: "Theme Color", icon: "paintpalette",
                            detail: "Accent color used across the app.",
                            kind: .choice(options: presets.map(\.name),
                                          get: {
                                              let hex = theme.accentColor.toHex()
                                              return presets.firstIndex { $0.color.toHex() == hex } ?? 0
                                          },
                                          set: { theme.accentColor = presets[$0].color })),
                PS4MenuItem(title: "Startup Check", icon: "checkmark.shield",
                            detail: "Show the JIT and memory-limit check every time the app opens.",
                            kind: Setting.defaultsBool("showStartupCheck", false)),
            ]
        }
    }

    static func displayPerformance() -> PS4MenuPage {
        PS4MenuPage(title: "Display and Performance", icon: "gauge.with.dots.needle.67percent") {
            [
                PS4MenuItem(title: "FPS Counter", icon: "speedometer",
                            detail: "Show frames per second in game.",
                            kind: Setting.defaultsBool("showFpsCounter", true)),
                PS4MenuItem(title: "Performance Overlay", icon: "chart.xyaxis.line",
                            detail: "FPS and CPU load in a small badge while playing.",
                            kind: Setting.defaultsBool("performanceOverlayEnabled", false)),
                PS4MenuItem(title: "Console Logging", icon: "text.alignleft",
                            detail: "Keep the emulator's console output.",
                            kind: Setting.defaultsBool("consoleLoggingEnabled", false)),
                PS4MenuItem(title: "Widescreen Hack", icon: "rectangle.expand.vertical",
                            detail: "Render games at \(WidescreenHack.resolutionDescription) to match this screen. Games that size their view from the screen show more at the sides; games locked to 16:9 may stretch. Applies from the next game.",
                            kind: Setting.defaultsBool("widescreenHack", false)),
                PS4MenuItem(title: "Aspect Ratio", icon: "aspectratio",
                            detail: "Auto keeps 16:9 with black bars, Stretch fills the screen, Zoom fills it by cropping.",
                            kind: .choice(options: ["Auto", "Stretch to Window", "Zoom to Fill"],
                                          get: { UserDefaults.standard.integer(forKey: "aspectRatioMode") },
                                          set: {
                                              UserDefaults.standard.set($0, forKey: "aspectRatioMode")
                                              shadps4_set_aspect_mode(Int32($0))
                                          })),
            ]
        }
    }

    static func console() -> PS4MenuPage {
        PS4MenuPage(title: "System", icon: "cpu") {
            [
                PS4MenuItem(title: "PS4 Pro Mode", icon: "bolt",
                            detail: "Report a PS4 Pro to games. Takes effect next launch.",
                            kind: Setting.configBool("General", "neo_mode", false)),
                PS4MenuItem(title: "Dev Kit Mode", icon: "hammer",
                            detail: "Report a development console.",
                            kind: Setting.configBool("General", "dev_kit_mode", false)),
                PS4MenuItem(title: "Extra Flexible Memory", icon: "memorychip",
                            detail: "More memory for games that run out of it.",
                            kind: Setting.configStepper("General", "extra_dmem_in_mbytes", 0...2048, step: 128, 0,
                                                        format: { "\($0) MB" })),
                PS4MenuItem(title: "Splash Screen", icon: "photo",
                            detail: "Show the game's splash art while it boots.",
                            kind: Setting.configBool("General", "show_splash", true)),
            ]
        }
    }

    static func network() -> PS4MenuPage {
        PS4MenuPage(title: "Network", icon: "network") {
            [
                PS4MenuItem(title: "Connect to the Internet", icon: "wifi",
                            detail: "Needed by online games.",
                            kind: Setting.defaultsBool("networkEnabled", true)),
            ]
        }
    }

    private static let resolutions: [(String, Int, Int)] = [
        ("720p", 1280, 720), ("1080p", 1920, 1080), ("1440p", 2560, 1440), ("4K", 3840, 2160),
    ]

    static func graphics() -> PS4MenuPage {
        PS4MenuPage(title: "Graphics", icon: "cube") {
            let store = ConfigStore.shared
            return [
                PS4MenuItem(title: "Render Resolution", icon: "rectangle.on.rectangle",
                            detail: "Higher is sharper but much slower.",
                            kind: .choice(options: resolutions.map(\.0),
                                          get: {
                                              let h = store.int("GPU", "internal_screen_height", default: 720)
                                              return resolutions.firstIndex { $0.2 == h } ?? 0
                                          },
                                          set: {
                                              store.setInt("GPU", "internal_screen_width", resolutions[$0].1)
                                              store.setInt("GPU", "internal_screen_height", resolutions[$0].2)
                                          })),
                PS4MenuItem(title: "FSR Upscaling", icon: "wand.and.stars",
                            kind: Setting.configBool("GPU", "fsr_enabled", false)),
                PS4MenuItem(title: "Sharpening", icon: "triangle.lefthalf.filled",
                            kind: Setting.configBool("GPU", "rcas_enabled", true)),
                PS4MenuItem(title: "Sharpening Strength", icon: "slider.horizontal.3",
                            detail: "Lower values sharpen more.",
                            kind: Setting.configStepper("GPU", "rcas_attenuation", 0...1000, step: 25, 250,
                                                        format: { "\($0)" })),
                PS4MenuItem(title: "VBlank Frequency", icon: "waveform",
                            kind: Setting.configStepper("GPU", "vblank_frequency", 30...240, step: 10, 60,
                                                        format: { "\($0) Hz" })),
                PS4MenuItem(title: "GPU Readbacks", icon: "arrow.left.arrow.right",
                            kind: Setting.configChoice("GPU", "readbacks_mode", ["Disabled", "Relaxed", "Precise"], 0)),
                PS4MenuItem(title: "Direct Memory Access", icon: "memorychip",
                            kind: Setting.configBool("GPU", "direct_memory_access_enabled", false)),
                PS4MenuItem(title: "Allow HDR", icon: "sun.max",
                            kind: Setting.configBool("GPU", "hdr_allowed", false)),
                PS4MenuItem(title: "Pipeline Cache", icon: "tray.full",
                            kind: Setting.configBool("Vulkan", "pipeline_cache_enabled", false)),
                PS4MenuItem(title: "Null GPU", icon: "eye.slash",
                            detail: "Skip rendering entirely (diagnostic).",
                            kind: Setting.configBool("GPU", "null_gpu", false)),
                PS4MenuItem(title: "Dump Shaders", icon: "doc.on.doc",
                            kind: Setting.configBool("GPU", "dump_shaders", false)),
                PS4MenuItem(title: "Vulkan Validation", icon: "checkmark.seal",
                            kind: Setting.configBool("Vulkan", "vkvalidation_enabled", false)),
                PS4MenuItem(title: "Vulkan Crash Diagnostics", icon: "stethoscope",
                            kind: Setting.configBool("Vulkan", "vkcrash_diagnostic_enabled", false)),
            ]
        }
    }

    static func audio() -> PS4MenuPage {
        PS4MenuPage(title: "Sound", icon: "speaker.wave.2") {
            [
                PS4MenuItem(title: "Audio Backend", icon: "hifispeaker",
                            kind: Setting.configChoice("Audio", "audio_backend", ["SDL", "OpenAL"], 0)),
                PS4MenuItem(title: "Disable Audio Output", icon: "speaker.slash",
                            detail: "Run games silently (diagnostic).",
                            kind: Setting.configBool("Audio", "disable_audio_output", false)),
            ]
        }
    }

    static func input(context: PS4MenuContext) -> PS4MenuPage {
        PS4MenuPage(title: "Devices", icon: "gamecontroller") {
            [
                PS4MenuItem(title: "Motion Controls", icon: "gyroscope",
                            kind: Setting.configBool("Input", "motion_controls_enabled", true)),
                PS4MenuItem(title: "Background Controller Input", icon: "rectangle.on.rectangle.angled",
                            kind: Setting.configBool("Input", "background_controller_input", false)),
                PS4MenuItem(title: "Treat Mice as Mice", icon: "computermouse",
                            kind: Setting.configBool("Input", "use_mice_as_mice", false)),
                PS4MenuItem(title: "Touch Controls", icon: "hand.tap",
                            kind: Setting.defaultsBool("touchControlsDisabled", false, inverted: true)),
                PS4MenuItem(title: "Touch Controls With a Controller", icon: "hand.raised",
                            detail: "Keep the touch controls on screen while a controller is connected.",
                            kind: Setting.defaultsBool("touchControlsShowWithController", false)),
                PS4MenuItem(title: "Expanded Touchpad", icon: "rectangle.and.hand.point.up.left",
                            kind: Setting.defaultsBool("touchpadExpanded", true)),
                PS4MenuItem(title: "Touch Controls Opacity", icon: "circle.lefthalf.filled",
                            kind: .stepper(range: 20...100, step: 5,
                                           get: { Int(((UserDefaults.standard.object(forKey: "touchControlsOpacity") as? Double) ?? 0.85) * 100) },
                                           set: { UserDefaults.standard.set(Double($0) / 100, forKey: "touchControlsOpacity") },
                                           format: { "\($0)%" })),
                PS4MenuItem(title: "Customize Layout", icon: "arrow.up.and.down.and.arrow.left.and.right",
                            kind: .classic { AnyView(TouchControlsLayoutEditorView()) }),
                PS4MenuItem(title: "Reset Layout", icon: "arrow.counterclockwise", isDestructive: true,
                            kind: .action {
                                context.confirm(PS4Confirmation(title: "Reset Layout?",
                                                                message: "Every touch control goes back to its default place.",
                                                                actionTitle: "Reset",
                                                                action: { TouchLayoutStore.shared.resetAll() }))
                            }),
            ]
        }
    }

    static func advanced(context: PS4MenuContext) -> PS4MenuPage {
        PS4MenuPage(title: "Debug", icon: "wrench.and.screwdriver") {
            [
                PS4MenuItem(title: "Debug Register Dump", icon: "doc.text.magnifyingglass",
                            kind: Setting.configBool("Debug", "debug_dump", false)),
                PS4MenuItem(title: "Collect Shaders", icon: "square.stack.3d.up",
                            kind: Setting.configBool("Debug", "shader_collect", false)),
                PS4MenuItem(title: "More Tools", icon: "ellipsis.circle",
                            detail: "Exporting game executables and other tools.",
                            kind: .classic { AnyView(SettingsAdvancedView()) }),
            ]
        }
    }

    // MARK: Library

    static func library(context: PS4MenuContext) -> PS4MenuPage {
        PS4MenuPage(title: "Library", icon: "square.grid.2x2") {
            var items: [PS4MenuItem] = context.library.games
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { game in
                    PS4MenuItem(title: game.name, icon: game.isAvailable ? "gamecontroller" : "exclamationmark.triangle",
                                detail: [game.titleId, game.appVersion.map { "v\($0)" },
                                         PlayTimeStore.formatted(forTitleId: game.titleId)]
                                    .compactMap { $0 }.joined(separator: "  ·  "),
                                kind: .link { gamePage(game, context: context) })
                }
            items.append(PS4MenuItem(title: "Add Game…", icon: "plus.square",
                                     detail: "Install a .pkg file.",
                                     kind: .action { context.importGame() }))
            return items
        }
    }

    static func gamePage(_ game: Game, context: PS4MenuContext) -> PS4MenuPage {
        PS4MenuPage(title: game.name, icon: "gamecontroller") {
            [
                PS4MenuItem(title: "Start", icon: "play.fill",
                            detail: game.isAvailable ? "" : "The game's data is missing.",
                            kind: .action {
                                guard game.isAvailable, !context.emulator.isBusy else { return }
                                context.close()
                                context.emulator.launch(pkgPath: game.absolutePkgPath, gameName: game.name)
                            }),
                PS4MenuItem(title: "Title ID", icon: "number",
                            kind: .info { game.titleId ?? "Unknown" }),
                PS4MenuItem(title: "Version", icon: "tag",
                            kind: .info { game.appVersion ?? "Unknown" }),
                PS4MenuItem(title: "Play Time", icon: "clock",
                            kind: .info { PlayTimeStore.formatted(forTitleId: game.titleId) ?? "Not played yet" }),
                PS4MenuItem(title: "Information", icon: "info.circle",
                            kind: .classic { AnyView(GameDetailView(game: game)) }),
                PS4MenuItem(title: "Delete", icon: "trash", isDestructive: true,
                            kind: .action {
                                context.confirm(PS4Confirmation(title: "Delete \(game.name)?",
                                                                message: "This removes the installed copy from the app.",
                                                                actionTitle: "Delete",
                                                                action: { context.library.removeGame(game) }))
                            }),
            ]
        }
    }
}
