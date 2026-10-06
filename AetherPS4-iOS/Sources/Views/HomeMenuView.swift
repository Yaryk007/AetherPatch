import AudioToolbox
import GameController
import SwiftUI
import UIKit

/// PS4-style home screen: the selected game's backdrop (or the animated wave theme), a
/// horizontal content row whose focused tile grows with its title and Start button underneath,
/// and the function area along the top. Navigable by touch or controller (D-pad/left stick,
/// Cross to start, Circle to go back, Options for information).
///
/// Everything here is drawn from the user's own games (icon0/pic1 from each game's sce_sys)
/// and SF Symbols; no Sony assets are bundled.
struct HomeMenuView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EmulatorProcess.self) private var emulator
    @ObservedObject private var profile = ProfileStore.shared
    @StateObject private var input = HomeControllerInput()
    @AppStorage("homeMenuSounds") private var soundsEnabled = true

    @State private var focusArea: FocusArea = .content
    @State private var contentIndex = 0
    @State private var functionIndex = 0
    @State private var sheet: HomeSheet?
    @State private var infoGame: Game?
    @State private var isImporterPresented = false
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    // Bumped after a launch so the row re-sorts by the new last-played date.
    @State private var lastPlayedRevision = 0

    private enum FocusArea {
        case content
        case functions
    }

    var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()

            GeometryReader { geo in
                let m = HomeMetrics(size: geo.size)
                VStack(alignment: .leading, spacing: 0) {
                    topBar(m)
                    functionRow(m)
                        .padding(.top, m.unit * 0.05)
                    Spacer(minLength: m.unit * 0.04)
                    contentRow(m)
                        .offset(y: focusArea == .functions ? m.unit * 0.08 : 0)
                        .opacity(focusArea == .functions ? 0.45 : 1)
                    infoPanel(m)
                        .padding(.horizontal, m.margin)
                        .padding(.top, m.unit * 0.04)
                        .opacity(focusArea == .functions ? 0 : 1)
                    Spacer(minLength: 0)
                    buttonHints(m)
                }
                .padding(.vertical, 12)
                .animation(.easeOut(duration: 0.22), value: focusArea)
            }

            notifications
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            input.onCommand = handle
            input.start()
        }
        .onDisappear { input.stop() }
        .onChange(of: library.games.count) { _, _ in
            contentIndex = min(contentIndex, max(items.count - 1, 0))
        }
        .onChange(of: library.lastImportError) { _, error in
            if let error {
                showToast("Couldn't add game: \(error)")
                library.lastImportError = nil
            }
        }
        .sheet(item: $sheet) { sheet in
            NavigationStack {
                sheet.content
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { self.sheet = nil }
                        }
                    }
            }
            .environment(library)
            .environment(emulator)
        }
        .sheet(item: $infoGame) { game in
            NavigationStack {
                GameDetailView(game: game)
                    .navigationTitle("Information")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { infoGame = nil }
                        }
                    }
            }
            .environment(library)
            .environment(emulator)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pkgPackage],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await library.importPkg(from: url) }
        }
    }

    // MARK: - Items

    private var orderedGames: [Game] {
        _ = lastPlayedRevision
        return library.games.sorted { a, b in
            let la = LastPlayedStore.date(for: a) ?? .distantPast
            let lb = LastPlayedStore.date(for: b) ?? .distantPast
            if la != lb { return la > lb }
            return a.dateAdded > b.dateAdded
        }
    }

    private var items: [HomeItem] {
        orderedGames.map(HomeItem.game) + [.library]
    }

    private var focusedItem: HomeItem? {
        let all = items
        return all.indices.contains(contentIndex) ? all[contentIndex] : all.last
    }

    // MARK: - Backdrop

    @ViewBuilder
    private var backdrop: some View {
        ZStack {
            PS4WaveBackground(paused: emulator.isRunning)

            if case .game(let game) = focusedItem, focusArea == .content,
               let banner = HomeImageCache.image(atPath: game.bannerPath) {
                Image(uiImage: banner)
                    .resizable()
                    .scaledToFill()
                    .overlay(
                        LinearGradient(
                            colors: [.black.opacity(0.55), .black.opacity(0.15), .black.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom)
                    )
                    .id(game.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: focusedItem?.id)
        .animation(.easeInOut(duration: 0.35), value: focusArea)
        .clipped()
    }

    // MARK: - Top bar

    private func topBar(_ m: HomeMetrics) -> some View {
        HStack(spacing: 10) {
            avatar(size: m.unit * 0.075)
            Text(profile.username)
                .font(.system(size: m.unit * 0.042, weight: .regular))
                .lineLimit(1)
            Spacer()
            if input.isConnected {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: m.unit * 0.038))
                    .foregroundStyle(.white.opacity(0.8))
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: m.unit * 0.045, weight: .light))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, m.margin)
    }

    private func avatar(size: CGFloat) -> some View {
        Group {
            if let image = profile.profileImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
                    .foregroundStyle(.white.opacity(0.85))
                    .background(Color(red: 0.16, green: 0.36, blue: 0.72))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
    }

    // MARK: - Function area

    private func functionRow(_ m: HomeMetrics) -> some View {
        HStack(alignment: .top, spacing: m.unit * 0.075) {
            ForEach(Array(FunctionItem.allCases.enumerated()), id: \.element) { index, item in
                let focused = focusArea == .functions && index == functionIndex
                VStack(spacing: m.unit * 0.02) {
                    Image(systemName: item.symbol)
                        .font(.system(size: m.unit * 0.06, weight: .light))
                        .frame(width: m.unit * 0.11, height: m.unit * 0.11)
                        .background(
                            RoundedRectangle(cornerRadius: m.unit * 0.02)
                                .fill(.white.opacity(focused ? 0.22 : 0))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: m.unit * 0.02)
                                .strokeBorder(.white.opacity(focused ? 0.9 : 0), lineWidth: 1.5)
                        )
                        .shadow(color: .white.opacity(focused ? 0.5 : 0), radius: 8)
                        .scaleEffect(focused ? 1.18 : 1)
                    Text(item.title)
                        .font(.system(size: m.unit * 0.032))
                        .fixedSize()
                        .opacity(focused ? 1 : 0)
                }
                .foregroundStyle(.white.opacity(focusArea == .functions ? 1 : 0.7))
                .contentShape(Rectangle())
                .onTapGesture {
                    focusArea = .functions
                    functionIndex = index
                    activateFunction()
                }
            }
        }
        .padding(.horizontal, m.margin)
        .animation(.easeOut(duration: 0.18), value: functionIndex)
    }

    // MARK: - Content row

    private func contentRow(_ m: HomeMetrics) -> some View {
        let all = items
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: m.spacing) {
                    ForEach(Array(all.enumerated()), id: \.element.id) { index, item in
                        let focused = index == contentIndex
                        HomeTile(
                            item: item,
                            size: focused ? m.focusedTile : m.tile,
                            isFocused: focused && focusArea == .content
                        )
                        .id(item.id)
                        .onTapGesture { tapTile(index) }
                        .contextMenu {
                            if case .game(let game) = item {
                                Button {
                                    infoGame = game
                                } label: {
                                    Label("Information", systemImage: "info.circle")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, m.margin)
                .frame(height: m.focusedTile, alignment: .top)
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: contentIndex)
            }
            .scrollClipDisabled()
            .onChange(of: contentIndex) { _, new in
                guard all.indices.contains(new) else { return }
                // Keep the focused tile pinned at the left margin, like the PS4 does.
                let anchorX = m.margin / max(m.width - m.focusedTile, 1)
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(all[new].id, anchor: UnitPoint(x: anchorX, y: 0))
                }
            }
        }
        .frame(height: m.focusedTile)
    }

    // MARK: - Info under the focused tile

    @ViewBuilder
    private func infoPanel(_ m: HomeMetrics) -> some View {
        switch focusedItem {
        case .game(let game):
            VStack(alignment: .leading, spacing: m.unit * 0.025) {
                Text(game.name)
                    .font(.system(size: m.unit * 0.062, weight: .light))
                    .lineLimit(1)
                HStack(spacing: m.unit * 0.04) {
                    HomeActionButton(title: startTitle(for: game), size: m.unit) {
                        start(game)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let playTime = PlayTimeStore.formatted(forTitleId: game.titleId) {
                            Label(playTime, systemImage: "clock")
                        }
                        if !game.isAvailable {
                            Label("Game data not found", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else if let titleId = game.titleId {
                            Text([titleId, game.appVersion.map { "v\($0)" }].compactMap { $0 }.joined(separator: "  ·  "))
                        }
                    }
                    .font(.system(size: m.unit * 0.032))
                    .foregroundStyle(.white.opacity(0.75))
                }
            }
            .foregroundStyle(.white)
        case .library, .none:
            VStack(alignment: .leading, spacing: m.unit * 0.025) {
                Text("Library")
                    .font(.system(size: m.unit * 0.062, weight: .light))
                HStack(spacing: m.unit * 0.04) {
                    HomeActionButton(title: "Open", size: m.unit) { sheet = .library }
                    Text(library.games.isEmpty
                         ? "Add a .pkg to get started"
                         : "\(library.games.count) installed")
                        .font(.system(size: m.unit * 0.032))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .foregroundStyle(.white)
        }
    }

    private func startTitle(for game: Game) -> String {
        if emulator.isBusy && emulator.runningGameName == game.name {
            return "Close Application"
        }
        return "Start"
    }

    // MARK: - Button hints

    private func buttonHints(_ m: HomeMetrics) -> some View {
        HStack(spacing: m.unit * 0.045) {
            Spacer()
            if focusArea == .content {
                hint("xmark.circle", focusedItem == .library ? "Open" : "Start", m)
                if case .game = focusedItem {
                    hint("line.3.horizontal.circle", "Information", m)
                }
            } else {
                hint("xmark.circle", "Select", m)
                hint("circle.circle", "Back", m)
            }
        }
        .padding(.horizontal, m.margin)
        .opacity(input.isConnected ? 1 : 0)
    }

    private func hint(_ symbol: String, _ text: String, _ m: HomeMetrics) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.system(size: m.unit * 0.032))
        .foregroundStyle(.white.opacity(0.8))
    }

    // MARK: - Notifications (top-left, like the PS4's)

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 8) {
            if library.isImporting {
                HomeNotification(text: "Installing game…", showsProgress: true)
            }
            if let toast {
                HomeNotification(text: toast, showsProgress: false)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.top, 52)
        .animation(.easeOut(duration: 0.25), value: toast)
        .animation(.easeOut(duration: 0.25), value: library.isImporting)
        .allowsHitTesting(false)
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Actions

    private func tapTile(_ index: Int) {
        if focusArea == .content && index == contentIndex {
            activateContent()
        } else {
            focusArea = .content
            contentIndex = index
            playSound(.move)
        }
    }

    private func activateContent() {
        switch focusedItem {
        case .game(let game):
            start(game)
        case .library, .none:
            playSound(.confirm)
            sheet = .library
        }
    }

    private func activateFunction() {
        playSound(.confirm)
        switch FunctionItem.allCases[functionIndex] {
        case .library: sheet = .library
        case .addGame: isImporterPresented = true
        case .gameStatus: sheet = .gameStatus
        case .profile: sheet = .profile
        case .settings: sheet = .settings
        }
    }

    private func start(_ game: Game) {
        if emulator.isBusy {
            if emulator.runningGameName == game.name {
                emulator.stop()
            } else {
                showToast("Close \(emulator.runningGameName ?? "the running game") first.")
            }
            return
        }
        guard game.isAvailable else {
            showToast("\(game.name) can't be started because its data is missing.")
            return
        }
        playSound(.confirm)
        let linesBefore = emulator.consoleLines.count
        emulator.launch(pkgPath: game.absolutePkgPath, gameName: game.name)
        if emulator.isBusy {
            LastPlayedStore.markPlayed(game)
            lastPlayedRevision += 1
            contentIndex = 0
        } else if emulator.consoleLines.count > linesBefore, let line = emulator.consoleLines.last?.text {
            // launch() bailed out early (usually: StikDebug hasn't attached yet).
            showToast(line.replacingOccurrences(of: "[AetherPS4] ", with: ""))
        }
    }

    // MARK: - Controller

    private func handle(_ command: HomeControllerInput.Command) {
        guard !emulator.isRunning else { return }
        if sheet != nil || infoGame != nil {
            if command == .back {
                sheet = nil
                infoGame = nil
                playSound(.back)
            }
            return
        }
        guard !isImporterPresented else { return }

        switch (focusArea, command) {
        case (.content, .left):
            move(&contentIndex, by: -1, count: items.count)
        case (.content, .right):
            move(&contentIndex, by: 1, count: items.count)
        case (.content, .up):
            focusArea = .functions
            playSound(.move)
        case (.content, .confirm):
            activateContent()
        case (.content, .options):
            if case .game(let game) = focusedItem {
                playSound(.confirm)
                infoGame = game
            }
        case (.functions, .left):
            move(&functionIndex, by: -1, count: FunctionItem.allCases.count)
        case (.functions, .right):
            move(&functionIndex, by: 1, count: FunctionItem.allCases.count)
        case (.functions, .down), (.functions, .back):
            focusArea = .content
            playSound(.back)
        case (.functions, .confirm):
            activateFunction()
        default:
            break
        }
    }

    private func move(_ index: inout Int, by delta: Int, count: Int) {
        let new = min(max(index + delta, 0), max(count - 1, 0))
        guard new != index else { return }
        index = new
        playSound(.move)
    }

    private enum Sound {
        case move, confirm, back
    }

    private func playSound(_ sound: Sound) {
        guard soundsEnabled else { return }
        switch sound {
        case .move: AudioServicesPlaySystemSound(1104)
        case .confirm: AudioServicesPlaySystemSound(1103)
        case .back: AudioServicesPlaySystemSound(1104)
        }
    }
}

// MARK: - Model

private enum HomeItem: Identifiable, Equatable {
    case game(Game)
    case library

    var id: String {
        switch self {
        case .game(let game): game.id.uuidString
        case .library: "library"
        }
    }
}

private enum FunctionItem: CaseIterable, Hashable {
    case library, addGame, gameStatus, profile, settings

    var title: String {
        switch self {
        case .library: "Library"
        case .addGame: "Add Game"
        case .gameStatus: "Game Status"
        case .profile: "Profile"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .library: "square.grid.2x2"
        case .addGame: "plus.square"
        case .gameStatus: "checklist"
        case .profile: "person.crop.circle"
        case .settings: "gearshape"
        }
    }
}

private enum HomeSheet: String, Identifiable {
    case library, gameStatus, profile, settings

    var id: String { rawValue }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .library: LibraryView()
        case .gameStatus: GameStatusView()
        case .profile: SettingsPersonalizationView().navigationTitle("Profile")
        case .settings: SettingsView().navigationTitle("Settings")
        }
    }
}

/// When each game was last started from the home screen, so the row opens on the most
/// recently played one (as the PS4 does).
private enum LastPlayedStore {
    private static let key = "homeLastPlayed"

    static func date(for game: Game) -> Date? {
        guard let stamps = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
              let stamp = stamps[game.id.uuidString] else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    static func markPlayed(_ game: Game) {
        var stamps = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        stamps[game.id.uuidString] = Date().timeIntervalSince1970
        UserDefaults.standard.set(stamps, forKey: key)
    }
}

private enum HomeImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(atPath path: String?) -> UIImage? {
        guard let path else { return nil }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

private struct HomeMetrics {
    let width: CGFloat
    let height: CGFloat
    /// Base length everything scales from: the short side, capped so iPads don't get huge tiles.
    let unit: CGFloat
    let tile: CGFloat
    let focusedTile: CGFloat
    let spacing: CGFloat
    let margin: CGFloat

    init(size: CGSize) {
        width = size.width
        height = size.height
        unit = min(min(size.width, size.height), 700)
        tile = min(max(unit * 0.25, 76), 180)
        focusedTile = tile * 1.34
        spacing = unit * 0.022
        margin = max(size.width * 0.07, 20)
    }
}

// MARK: - Pieces

private struct HomeTile: View {
    let item: HomeItem
    let size: CGFloat
    let isFocused: Bool

    var body: some View {
        ZStack {
            switch item {
            case .game(let game):
                if let icon = HomeImageCache.image(atPath: game.iconPath) {
                    Image(uiImage: icon).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)],
                                   startPoint: .top, endPoint: .bottom)
                    Text(game.name)
                        .font(.system(size: size * 0.11, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(size * 0.08)
                        .foregroundStyle(.white.opacity(0.85))
                }
            case .library:
                LinearGradient(colors: [Color(red: 0.13, green: 0.38, blue: 0.82),
                                        Color(red: 0.05, green: 0.18, blue: 0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: size * 0.32, weight: .light))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(.white.opacity(isFocused ? 0.95 : 0.12), lineWidth: isFocused ? 2 : 0.5)
        )
        .shadow(color: isFocused ? .white.opacity(0.35) : .black.opacity(0.4),
                radius: isFocused ? 10 : 4, y: isFocused ? 0 : 2)
        .contentShape(Rectangle())
    }
}

private struct HomeActionButton: View {
    let title: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size * 0.036, weight: .medium))
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, size * 0.06)
                .padding(.vertical, size * 0.018)
                .frame(minWidth: size * 0.26)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.92)))
        }
        .buttonStyle(.plain)
    }
}

private struct HomeNotification: View {
    let text: String
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "bell.fill")
            }
            Text(text)
                .font(.subheadline)
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
        .transition(.move(edge: .leading).combined(with: .opacity))
    }
}

/// The default PS4 theme: deep blue gradient with slow, translucent waves drifting across it.
struct PS4WaveBackground: View {
    var paused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let w = size.width
                let h = size.height
                g.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.02, green: 0.06, blue: 0.18),
                        Color(red: 0.04, green: 0.20, blue: 0.50),
                        Color(red: 0.02, green: 0.08, blue: 0.24),
                    ]),
                    startPoint: .zero, endPoint: CGPoint(x: w, y: h)))

                g.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                    Gradient(colors: [Color(red: 0.3, green: 0.6, blue: 1).opacity(0.28), .clear]),
                    center: CGPoint(x: w * 0.68, y: h * 0.58), startRadius: 0, endRadius: max(w, h) * 0.55))

                func wave(_ i: Double, _ x: CGFloat) -> CGFloat {
                    let u = Double(x / max(w, 1))
                    let base = 0.52 + 0.07 * i
                    let amp = 0.045 + 0.018 * i
                    let speed = 0.10 + 0.04 * i
                    let y = base
                        + amp * sin(u * .pi * 2 * (0.9 + 0.3 * i) + t * speed + i * 1.7)
                        + amp * 0.6 * sin(u * .pi * (0.7 + 0.2 * i) - t * speed * 0.7)
                    return CGFloat(y) * h
                }

                for i in 0..<5 {
                    let fi = Double(i)
                    var line = Path()
                    var ribbon = Path()
                    line.move(to: CGPoint(x: 0, y: wave(fi, 0)))
                    ribbon.move(to: CGPoint(x: 0, y: wave(fi, 0)))
                    for x in stride(from: CGFloat(0), through: w + 8, by: 8) {
                        line.addLine(to: CGPoint(x: x, y: wave(fi, x)))
                        ribbon.addLine(to: CGPoint(x: x, y: wave(fi, x)))
                    }
                    for x in stride(from: w + 8, through: CGFloat(0), by: -8) {
                        ribbon.addLine(to: CGPoint(x: x, y: wave(fi + 0.35, x) + h * 0.02))
                    }
                    ribbon.closeSubpath()
                    g.fill(ribbon, with: .color(.white.opacity(0.035)))
                    g.stroke(line, with: .color(.white.opacity(0.16 - 0.022 * fi)), lineWidth: 1.2)
                }
            }
        }
    }
}

/// Polls the current controller instead of installing element handlers, so it never replaces
/// handlers SDL relies on in-game. Edge-detects presses and auto-repeats held directions.
@MainActor
final class HomeControllerInput: ObservableObject {
    enum Command: Hashable {
        case left, right, up, down, confirm, back, options
    }

    @Published private(set) var isConnected = !GCController.controllers().isEmpty
    var onCommand: ((Command) -> Void)?

    private var timer: Timer?
    private var previous: Set<Command> = []
    private var held: Command?
    private var heldSince: CFTimeInterval = 0
    private var lastRepeat: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isConnected = !GCController.controllers().isEmpty
                }
            })
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func poll() {
        guard let pad = GCController.current?.extendedGamepad else {
            previous = []
            held = nil
            return
        }
        var pressed: Set<Command> = []
        let x = pad.leftThumbstick.xAxis.value
        let y = pad.leftThumbstick.yAxis.value
        if pad.dpad.left.isPressed || x < -0.6 { pressed.insert(.left) }
        if pad.dpad.right.isPressed || x > 0.6 { pressed.insert(.right) }
        if pad.dpad.up.isPressed || y > 0.6 { pressed.insert(.up) }
        if pad.dpad.down.isPressed || y < -0.6 { pressed.insert(.down) }
        if pad.buttonA.isPressed { pressed.insert(.confirm) }
        if pad.buttonB.isPressed { pressed.insert(.back) }
        if pad.buttonMenu.isPressed { pressed.insert(.options) }

        let now = CACurrentMediaTime()
        let directions: Set<Command> = [.left, .right, .up, .down]
        for command in pressed.subtracting(previous) {
            onCommand?(command)
            if directions.contains(command) {
                held = command
                heldSince = now
                lastRepeat = now
            }
        }
        if let held {
            if !pressed.contains(held) {
                self.held = nil
            } else if now - heldSince > 0.4 && now - lastRepeat > 0.1 {
                lastRepeat = now
                onCommand?(held)
            }
        }
        previous = pressed
    }
}
