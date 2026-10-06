import Darwin
import GameController
import SwiftUI
import UIKit

// Full PS4 touch controller overlay, in SwiftUI, using the same proven pattern as
// LoadingOverlayWindow: a second UIWindow instead of a subview inside SDL's own window (see
// LoadingOverlayWindow's own header comment for why that alternative crashed on-device).
// Replaces touch_controls_layer.cpp's ImGui-based version (disabled, see vk_presenter.cpp) --
// the whole point of this session's threading work was getting real UI off ImGui and onto
// SwiftUI wherever the main thread being free actually makes that possible, and unlike the
// loading card, on-screen controls have no reason to ever need ImGui's render-thread access
// in the first place: touches are just forwarded to shadps4_apply_touch_input(), which
// works from any thread.
//
// Multi-touch (holding a stick with one thumb while pressing a face button with another)
// works for free here: each control below is its own SwiftUI view with its own gesture
// recognizer, and UIKit dispatches simultaneous touches across different views natively --
// no raw finger-event interception needed the way ImGui's single-emulated-pointer backend
// required.
//
// windowLevel is .normal + 1 -- above SDL's window, but below LoadingOverlayWindow's
// .alert + 1, so the loading card still sits on top of the controls while it's open rather
// than the two fighting over top position.
@MainActor
enum TouchControlsOverlayWindow {
    private static var window: UIWindow?

    static func show() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            print("[AetherPS4] TouchControlsOverlayWindow: no active window scene, cannot show")
            return
        }

        // Checked once per game session (this is only ever called at the start of one), so a
        // Settings change takes effect on the next game launch, not the next full app launch --
        // consistent with how the C++-side engine settings in ConfigStore behave. Only the
        // control widgets themselves are conditional on this -- the window itself always gets
        // created, since the boot-progress badge and performance overlay live in it too and
        // have nothing to do with whether the touch controls are wanted.
        let controlsEnabled = !UserDefaults.standard.bool(forKey: "touchControlsDisabled")

        let overlayWindow = UIWindow(windowScene: scene)
        overlayWindow.windowLevel = .normal + 1
        overlayWindow.backgroundColor = .clear
        overlayWindow.rootViewController = UIHostingController(
            rootView: TouchControlsView(controlsEnabled: controlsEnabled))
        overlayWindow.rootViewController?.view.backgroundColor = .clear
        overlayWindow.isHidden = false
        window = overlayWindow
        print("[AetherPS4] TouchControlsOverlayWindow: shown (controlsEnabled=\(controlsEnabled))")
    }

    static func teardown() {
        window?.isHidden = true
        window = nil
        print("[AetherPS4] TouchControlsOverlayWindow: torn down")
    }
}

// Tracks every control's live state and is the single source of truth for what gets sent
// to shadps4_apply_touch_input() -- that call takes a full snapshot every time (not
// incremental deltas), so every control writes its own piece here and the combined state
// is resent on every change, from whichever control changed.
@MainActor
private final class TouchPadState: ObservableObject {
    var buttons: UInt32 = 0
    var leftX = 128
    var leftY = 128
    var rightX = 128
    var rightY = 128
    var l2 = 0
    var r2 = 0
    /// Fingers on the touchpad, normalized 0...1 across the pad (at most two).
    var touches: [CGPoint] = []

    private let haptics = UIImpactFeedbackGenerator(style: .light)

    func setButton(_ bit: UInt32, pressed: Bool) {
        if pressed {
            if buttons & bit == 0 {
                haptics.impactOccurred(intensity: 0.7)
            }
            buttons |= bit
        } else {
            buttons &= ~bit
        }
        send()
    }

    /// A short press of `bit` (a click on the touchpad, or a stick click from a tap).
    func pulse(_ bit: UInt32) {
        setButton(bit, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            self?.setButton(bit, pressed: false)
        }
    }

    func send() {
        let t1 = touches.first
        let t2 = touches.count > 1 ? touches[1] : nil
        shadps4_apply_pad_state(buttons, Int32(leftX), Int32(leftY), Int32(rightX), Int32(rightY),
                                Int32(l2), Int32(r2),
                                t1 == nil ? 0 : 1, Float(t1?.x ?? 0), Float(t1?.y ?? 0),
                                t2 == nil ? 0 : 1, Float(t2?.x ?? 0), Float(t2?.y ?? 0))
    }
}

// Small always-on-top HUD showing live FPS and this process's CPU usage, toggled by the
// "Performance Overlay" setting. GPU usage isn't included -- there's no timestamp-query
// instrumentation in the Vulkan renderer to source a real number from yet, and a fake one
// would be actively misleading. FPS comes from shadps4_get_presented_frame_count() (a
// monotonic counter incremented once per successful swapchain present, sampled here once a
// second); CPU comes from summing per-thread cpu_usage via the Mach task_threads/thread_info
// APIs, the standard way to read a process's own CPU load on Darwin -- this is the app's own
// process total (engine + UI threads combined), reported like `top` does, so 150% means 1.5
// CPU cores busy, not a 0-100 clamped percentage.
@MainActor
private final class PerformanceOverlayState: ObservableObject {
    @Published var isEnabled = false
    @Published var fps: Double = 0
    @Published var cpuPercent: Double = 0

    private var timer: Timer?
    private var lastFrameCount: UInt64 = 0
    private var lastSampleTime = Date()

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "performanceOverlayEnabled")
        guard isEnabled else { return }
        lastFrameCount = shadps4_get_presented_frame_count()
        lastSampleTime = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    private func sample() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleTime)
        guard elapsed > 0 else { return }
        let currentCount = shadps4_get_presented_frame_count()
        fps = Double(currentCount &- lastFrameCount) / elapsed
        lastFrameCount = currentCount
        lastSampleTime = now
        cpuPercent = Self.processCPUUsage()
    }

    private static func processCPUUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList),
                         vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }

        var totalUsage: Double = 0
        for i in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                }
            }
            guard infoResult == KERN_SUCCESS else { continue }
            if threadInfo.flags & TH_FLAGS_IDLE == 0 {
                totalUsage += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        // Raw thread_info usage sums to >100% on a busy multi-threaded process (e.g. 200%
        // means 2 full cores saturated) -- correct for reading it like `top` does, but not
        // what a "CPU %" badge means to a player. Normalizing by core count instead gives
        // "how loaded is the device overall", 0-100%, matching what a game performance
        // overlay is actually expected to show.
        let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return min(100, totalUsage / Double(coreCount))
    }
}

private struct PerformanceOverlayBadge: View {
    @ObservedObject var perf: PerformanceOverlayState

    var body: some View {
        HStack(spacing: 18) {
            metric(icon: "gauge.with.dots.needle.67percent", value: "\(Int(perf.fps.rounded()))",
                  unit: "FPS")
            Divider()
                .frame(height: 30)
                .overlay(Color.white.opacity(0.25))
            metric(icon: "cpu", value: "\(Int(perf.cpuPercent.rounded()))", unit: "% CPU")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private func metric(icon: String, value: String, unit: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
        }
    }
}

// MARK: - Layout

/// Where each touch control sits by default (before the player's own offsets from the layout
/// editor). Shared by the in-game overlay and TouchControlsLayoutEditorView so the two can
/// never disagree. All lengths scale with the landscape screen height.
struct TouchControlLayoutSpec: Identifiable {
    let key: String
    let label: String
    let width: CGFloat
    let height: CGFloat
    let x: CGFloat
    let y: CGFloat

    var id: String { key }

    static func all(size: CGSize) -> [TouchControlLayoutSpec] {
        let w = size.width
        let h = size.height
        let u = h / 100
        // Keep clear of the notch / Dynamic Island on either side in landscape.
        let edge = max(u * 9, 34)
        let stick = u * 31
        let dpad = u * 28
        let face = u * 38
        let padWidth = min(w * 0.36, u * 82)
        let padHeight = u * 20
        let shoulderWidth = u * 18
        let shoulderHeight = u * 9
        var specs: [TouchControlLayoutSpec] = []
        specs.append(TouchControlLayoutSpec(key: "touchpad", label: "Touchpad", width: padWidth, height: padHeight, x: w / 2, y: u * 14))
        specs.append(TouchControlLayoutSpec(key: "share", label: "Share", width: u * 11, height: u * 7, x: w / 2 - padWidth / 2 - u * 9, y: u * 9))
        specs.append(TouchControlLayoutSpec(key: "options", label: "Options", width: u * 11, height: u * 7, x: w / 2 + padWidth / 2 + u * 9, y: u * 9))
        specs.append(TouchControlLayoutSpec(key: "L2", label: "L2", width: shoulderWidth, height: shoulderHeight, x: edge + shoulderWidth / 2, y: u * 8))
        specs.append(TouchControlLayoutSpec(key: "L1", label: "L1", width: shoulderWidth, height: shoulderHeight, x: edge + shoulderWidth / 2, y: u * 20))
        specs.append(TouchControlLayoutSpec(key: "R2", label: "R2", width: shoulderWidth, height: shoulderHeight, x: w - edge - shoulderWidth / 2, y: u * 8))
        specs.append(TouchControlLayoutSpec(key: "R1", label: "R1", width: shoulderWidth, height: shoulderHeight, x: w - edge - shoulderWidth / 2, y: u * 20))
        specs.append(TouchControlLayoutSpec(key: "leftStick", label: "L Stick", width: stick, height: stick, x: edge + stick / 2, y: u * 53))
        specs.append(TouchControlLayoutSpec(key: "dpad", label: "D-Pad", width: dpad, height: dpad, x: edge + stick + dpad * 0.3, y: u * 81))
        specs.append(TouchControlLayoutSpec(key: "faceButtons", label: "Buttons", width: face, height: face, x: w - edge - face / 2, y: u * 52))
        specs.append(TouchControlLayoutSpec(key: "rightStick", label: "R Stick", width: stick, height: stick, x: w - edge - stick - dpad * 0.3, y: u * 81))
        return specs
    }
}

// MARK: - Overlay

private struct TouchControlsView: View {
    let controlsEnabled: Bool

    @StateObject private var state = TouchPadState()
    @StateObject private var perf = PerformanceOverlayState()
    @StateObject private var layout = TouchLayoutStore.shared
    @StateObject private var controllers = ConnectedControllerMonitor()
    @AppStorage("touchControlsShowWithController") private var showWithController = false
    @AppStorage("touchpadExpanded") private var touchpadExpanded = true
    @AppStorage("touchControlsOpacity") private var controlsOpacity = 0.85

    /// Touch controls drive the same pad slot a physical controller does, so they get out of
    /// the way (live) while one is connected, unless the player asked to keep them.
    private var showsControls: Bool {
        controlsEnabled && (showWithController || !controllers.isConnected)
    }

    var body: some View {
        GeometryReader { geo in
            let specs = Dictionary(uniqueKeysWithValues:
                TouchControlLayoutSpec.all(size: geo.size).map { ($0.key, $0) })
            let u = geo.size.height / 100

            ZStack {
                if showsControls {
                    Group {
                        if let spec = specs["touchpad"] {
                            Group {
                                if touchpadExpanded {
                                    TouchpadView(state: state, collapse: { touchpadExpanded = false })
                                        .frame(width: spec.width, height: spec.height)
                                } else {
                                    CollapsedTouchpadButton(state: state, expand: { touchpadExpanded = true })
                                        .frame(width: spec.width * 0.5, height: u * 7)
                                }
                            }
                            .position(place(spec))
                        }
                        if let spec = specs["share"] {
                            MenuButton(state: state, bit: UInt32(SHADPS4_PAD_SHARE), title: "SHARE")
                                .frame(width: spec.width, height: spec.height)
                                .position(place(spec))
                        }
                        if let spec = specs["options"] {
                            MenuButton(state: state, bit: UInt32(SHADPS4_PAD_OPTIONS), title: "OPTIONS")
                                .frame(width: spec.width, height: spec.height)
                                .position(place(spec))
                        }
                        ForEach(["L1", "L2", "R1", "R2"], id: \.self) { key in
                            if let spec = specs[key] {
                                ShoulderButton(state: state, key: key)
                                    .frame(width: spec.width, height: spec.height)
                                    .position(place(spec))
                            }
                        }
                        if let spec = specs["leftStick"] {
                            StickView(state: state, axisX: \.leftX, axisY: \.leftY,
                                      clickBit: UInt32(SHADPS4_PAD_L3), label: "L")
                                .frame(width: spec.width, height: spec.height)
                                .position(place(spec))
                        }
                        if let spec = specs["rightStick"] {
                            StickView(state: state, axisX: \.rightX, axisY: \.rightY,
                                      clickBit: UInt32(SHADPS4_PAD_R3), label: "R")
                                .frame(width: spec.width, height: spec.height)
                                .position(place(spec))
                        }
                        if let spec = specs["dpad"] {
                            DPadView(state: state)
                                .frame(width: spec.width, height: spec.height)
                                .position(place(spec))
                        }
                        if let spec = specs["faceButtons"] {
                            FaceButtonsView(state: state, size: spec.width)
                                .frame(width: spec.width, height: spec.height)
                                .position(place(spec))
                        }
                    }
                    .opacity(controlsOpacity)
                    .transition(.opacity)
                }

                if perf.isEnabled {
                    PerformanceOverlayBadge(perf: perf)
                        .position(x: geo.size.width * 0.5, y: u * 36)
                }
            }
            .animation(.easeOut(duration: 0.2), value: showsControls)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: touchpadExpanded)
        }
        .ignoresSafeArea()
    }

    private func place(_ spec: TouchControlLayoutSpec) -> CGPoint {
        let offset = layout.offset(for: spec.key)
        return CGPoint(x: spec.x + offset.width, y: spec.y + offset.height)
    }
}

// MARK: - Shared look

/// Dark glass used by every control: translucent fill, a light rim, and a glow while pressed.
private struct GlassBackground<S: Shape>: View {
    let shape: S
    var isPressed = false
    var tint: Color = .white

    var body: some View {
        shape
            .fill(Color.black.opacity(isPressed ? 0.45 : 0.3))
            .overlay(shape.fill(tint.opacity(isPressed ? 0.28 : 0)))
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(isPressed ? 0.9 : 0.5), .white.opacity(0.1)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.5)
            )
            .shadow(color: tint.opacity(isPressed ? 0.6 : 0), radius: 10)
            .scaleEffect(isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}

/// A press that starts the instant a finger lands on the control. simultaneousGesture keeps
/// neighboring controls' recognizers from negotiating over (and eating) the first touch.
private struct PressGesture: ViewModifier {
    @Binding var isPressed: Bool
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    onChange(true)
                }
                .onEnded { _ in
                    isPressed = false
                    onChange(false)
                }
        )
    }
}

// MARK: - Touchpad

private struct TouchpadView: View {
    @ObservedObject var state: TouchPadState
    let collapse: () -> Void

    @State private var fingers: [CGPoint] = []
    @State private var clicking = false

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: geo.size.height * 0.22, style: .continuous)
            ZStack {
                GlassBackground(shape: shape, isPressed: clicking, tint: .cyan)
                // Subtle dot grid, like the pad's texture.
                Canvas { context, size in
                    let step = size.height / 5
                    var y = step / 2
                    while y < size.height {
                        var x = step / 2
                        while x < size.width {
                            context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)),
                                         with: .color(.white.opacity(0.12)))
                            x += step
                        }
                        y += step
                    }
                }
                .clipShape(shape)
                .allowsHitTesting(false)

                if fingers.isEmpty {
                    Text("TOUCHPAD")
                        .font(.system(size: geo.size.height * 0.16, weight: .semibold, design: .rounded))
                        .tracking(3)
                        .foregroundStyle(.white.opacity(0.35))
                        .allowsHitTesting(false)
                }

                ForEach(Array(fingers.enumerated()), id: \.offset) { _, point in
                    Circle()
                        .fill(RadialGradient(colors: [.cyan.opacity(0.8), .cyan.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: geo.size.height * 0.22))
                        .frame(width: geo.size.height * 0.44, height: geo.size.height * 0.44)
                        .position(x: point.x * geo.size.width, y: point.y * geo.size.height)
                        .allowsHitTesting(false)
                }

                TouchpadSurface(
                    onFingers: { points in
                        fingers = points
                        state.touches = points
                        state.send()
                    },
                    onTap: { point in
                        flashClick()
                        state.touches = [point]
                        state.pulse(UInt32(SHADPS4_PAD_TOUCHPAD))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if fingers.isEmpty {
                                state.touches = []
                                state.send()
                            }
                        }
                    },
                    onHold: { holding in
                        clicking = holding
                        state.setButton(UInt32(SHADPS4_PAD_TOUCHPAD), pressed: holding)
                    }
                )
                .clipShape(shape)

                Button(action: collapse) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 16)
                        .background(Capsule().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .position(x: geo.size.width / 2, y: geo.size.height + 11)
            }
        }
    }

    private func flashClick() {
        clicking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { clicking = false }
    }
}

/// The touchpad tucked away: a slim bar that still clicks the pad, and expands it on a swipe down.
private struct CollapsedTouchpadButton: View {
    @ObservedObject var state: TouchPadState
    let expand: () -> Void
    @State private var isPressed = false

    var body: some View {
        GeometryReader { geo in
            let shape = Capsule()
            ZStack {
                GlassBackground(shape: shape, isPressed: isPressed, tint: .cyan)
                HStack(spacing: 6) {
                    Text("TOUCHPAD")
                        .font(.system(size: geo.size.height * 0.36, weight: .semibold, design: .rounded))
                        .tracking(2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: geo.size.height * 0.32, weight: .bold))
                        .onTapGesture(perform: expand)
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            .modifier(PressGesture(isPressed: $isPressed) { pressed in
                state.setButton(UInt32(SHADPS4_PAD_TOUCHPAD), pressed: pressed)
            })
            .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height > 15 { expand() }
            })
        }
    }
}

/// UIKit surface for the touchpad: SwiftUI gestures can't follow two individual fingers.
private struct TouchpadSurface: UIViewRepresentable {
    let onFingers: ([CGPoint]) -> Void
    let onTap: (CGPoint) -> Void
    let onHold: (Bool) -> Void

    func makeUIView(context: Context) -> TouchpadUIView {
        let view = TouchpadUIView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: TouchpadUIView, context: Context) {
        view.onFingers = onFingers
        view.onTap = onTap
        view.onHold = onHold
    }
}

private final class TouchpadUIView: UIView {
    var onFingers: (([CGPoint]) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var onHold: ((Bool) -> Void)?

    private var active: [UITouch] = []
    private var firstTouchStart: CFTimeInterval = 0
    private var firstTouchOrigin: CGPoint = .zero
    private var moved = false
    private var holding = false
    private var maxFingers = 0
    private var holdTimer: Timer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where active.count < 2 {
            active.append(touch)
        }
        maxFingers = max(maxFingers, active.count)
        if active.count == 1, let first = active.first {
            firstTouchStart = CACurrentMediaTime()
            firstTouchOrigin = first.location(in: self)
            moved = false
            holdTimer?.invalidate()
            // Resting a finger without moving presses the pad down, like pushing on a real one.
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.moved, self.active.count == 1 else { return }
                    self.holding = true
                    self.onHold?(true)
                }
            }
        } else {
            holdTimer?.invalidate()
        }
        report()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let first = active.first {
            let p = first.location(in: self)
            if hypot(p.x - firstTouchOrigin.x, p.y - firstTouchOrigin.y) > 8 {
                moved = true
                if !holding { holdTimer?.invalidate() }
            }
        }
        report()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        let lastPoint = active.first.map { normalized($0.location(in: self)) }
        active.removeAll { touches.contains($0) }
        guard active.isEmpty else {
            report()
            return
        }
        holdTimer?.invalidate()
        let quick = CACurrentMediaTime() - firstTouchStart < 0.25
        if holding {
            holding = false
            onHold?(false)
            report()
        } else if !cancelled && !moved && quick && maxFingers == 1, let lastPoint {
            onFingers?([])
            onTap?(lastPoint)
        } else {
            report()
        }
        maxFingers = 0
    }

    private func report() {
        onFingers?(active.map { normalized($0.location(in: self)) })
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x / max(bounds.width, 1), 0), 1),
                y: min(max(p.y / max(bounds.height, 1), 0), 1))
    }
}

// MARK: - Sticks

private struct StickView: View {
    @ObservedObject var state: TouchPadState
    let axisX: ReferenceWritableKeyPath<TouchPadState, Int>
    let axisY: ReferenceWritableKeyPath<TouchPadState, Int>
    let clickBit: UInt32
    let label: String

    @State private var thumbOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var touchStart: Date?
    @State private var maxTravel: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            let travel = radius * 0.62
            let direction = atan2(thumbOffset.height, thumbOffset.width)
            let strength = min(hypot(thumbOffset.width, thumbOffset.height) / travel, 1)
            ZStack {
                GlassBackground(shape: Circle(), isPressed: false)
                // Direction highlight along the rim.
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(Color.cyan.opacity(0.8 * strength), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.radians(Double(direction) - .pi * 32 / 180))
                    .padding(2)
                Circle()
                    .fill(
                        RadialGradient(colors: [.white.opacity(isDragging ? 0.7 : 0.45), .white.opacity(isDragging ? 0.35 : 0.18)],
                                       center: .topLeading, startRadius: 0, endRadius: radius * 0.6)
                    )
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                    .overlay(
                        Text(label)
                            .font(.system(size: radius * 0.22, weight: .bold, design: .rounded))
                            .foregroundStyle(.black.opacity(0.35))
                    )
                    .frame(width: radius * 0.86, height: radius * 0.86)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    .offset(thumbOffset)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if touchStart == nil {
                            touchStart = Date()
                            maxTravel = 0
                        }
                        isDragging = true
                        // Measured from the stick's center, so the thumb jumps under the finger.
                        let dx = value.location.x - radius
                        let dy = value.location.y - radius
                        maxTravel = max(maxTravel, hypot(value.translation.width, value.translation.height))
                        let dist = hypot(dx, dy)
                        let scale = dist > travel ? travel / dist : 1
                        thumbOffset = CGSize(width: dx * scale, height: dy * scale)
                        state[keyPath: axisX] = axisValue(thumbOffset.width, travel: travel)
                        state[keyPath: axisY] = axisValue(thumbOffset.height, travel: travel)
                        state.send()
                    }
                    .onEnded { _ in
                        // A quick tap without dragging clicks the stick (L3/R3).
                        if let touchStart, Date().timeIntervalSince(touchStart) < 0.2, maxTravel < 6 {
                            state.pulse(clickBit)
                        }
                        touchStart = nil
                        isDragging = false
                        withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) {
                            thumbOffset = .zero
                        }
                        state[keyPath: axisX] = 128
                        state[keyPath: axisY] = 128
                        state.send()
                    }
            )
        }
    }

    /// Maps an offset in [-travel, travel] to a 0-255 axis value, 128 = center.
    private func axisValue(_ offset: CGFloat, travel: CGFloat) -> Int {
        guard travel > 0 else { return 128 }
        let normalized = max(-1.0, min(1.0, offset / travel))
        return Int((normalized * 127.0).rounded()) + 128
    }
}

// MARK: - D-Pad

private struct DPadView: View {
    @ObservedObject var state: TouchPadState
    @State private var pressedBits: UInt32 = 0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let arm = size * 0.36
            ZStack {
                arrow(UInt32(SHADPS4_PAD_UP), rotation: 0, size: size, arm: arm)
                arrow(UInt32(SHADPS4_PAD_RIGHT), rotation: 90, size: size, arm: arm)
                arrow(UInt32(SHADPS4_PAD_DOWN), rotation: 180, size: size, arm: arm)
                arrow(UInt32(SHADPS4_PAD_LEFT), rotation: 270, size: size, arm: arm)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        update(point: value.location, center: CGPoint(x: size / 2, y: size / 2))
                    }
                    .onEnded { _ in
                        apply(0)
                    }
            )
        }
    }

    private func arrow(_ bit: UInt32, rotation: Double, size: CGFloat, arm: CGFloat) -> some View {
        let active = pressedBits & bit != 0
        let shape = DPadArmShape()
        return ZStack {
            GlassBackground(shape: shape, isPressed: active)
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: arm * 0.3))
                .foregroundStyle(.white.opacity(active ? 0.95 : 0.6))
                .offset(y: -arm * 0.12)
        }
        .frame(width: arm * 0.95, height: arm)
        .offset(y: -(size / 2 - arm / 2))
        .rotationEffect(.degrees(rotation))
    }

    // 8-way, by angle, so a touch near a corner presses both neighbors like a real d-pad.
    private func update(point: CGPoint, center: CGPoint) {
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard hypot(dx, dy) > 6 else { return }
        let degrees = atan2(-dy, dx) * 180 / .pi
        let normalized = (degrees + 360).truncatingRemainder(dividingBy: 360)
        let up = UInt32(SHADPS4_PAD_UP), down = UInt32(SHADPS4_PAD_DOWN)
        let left = UInt32(SHADPS4_PAD_LEFT), right = UInt32(SHADPS4_PAD_RIGHT)
        let bits: UInt32
        switch normalized {
        case 337.5..., ..<22.5: bits = right
        case 22.5..<67.5: bits = up | right
        case 67.5..<112.5: bits = up
        case 112.5..<157.5: bits = up | left
        case 157.5..<202.5: bits = left
        case 202.5..<247.5: bits = down | left
        case 247.5..<292.5: bits = down
        default: bits = down | right
        }
        apply(bits)
    }

    private func apply(_ bits: UInt32) {
        guard bits != pressedBits else { return }
        let mask = UInt32(SHADPS4_PAD_UP) | UInt32(SHADPS4_PAD_DOWN) | UInt32(SHADPS4_PAD_LEFT)
            | UInt32(SHADPS4_PAD_RIGHT)
        if bits & ~pressedBits != 0 {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        }
        state.buttons = (state.buttons & ~mask) | bits
        pressedBits = bits
        state.send()
    }
}

/// One arm of the d-pad cross: square inner end, pointed outer end.
private struct DPadArmShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) * 0.18
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.28))
        path.closeSubpath()
        return path
    }
}

// MARK: - Face buttons

private struct FaceButtonsView: View {
    @ObservedObject var state: TouchPadState
    let size: CGFloat

    var body: some View {
        let radius = size * 0.185
        let spread = size * 0.32
        ZStack {
            FaceButton(state: state, bit: UInt32(SHADPS4_PAD_TRIANGLE), radius: radius,
                       symbol: "triangle", color: Color(red: 0.25, green: 0.85, blue: 0.68))
                .offset(y: -spread)
            FaceButton(state: state, bit: UInt32(SHADPS4_PAD_CROSS), radius: radius,
                       symbol: "xmark", color: Color(red: 0.48, green: 0.66, blue: 1.0))
                .offset(y: spread)
            FaceButton(state: state, bit: UInt32(SHADPS4_PAD_SQUARE), radius: radius,
                       symbol: "square", color: Color(red: 0.97, green: 0.56, blue: 0.85))
                .offset(x: -spread)
            FaceButton(state: state, bit: UInt32(SHADPS4_PAD_CIRCLE), radius: radius,
                       symbol: "circle", color: Color(red: 1.0, green: 0.42, blue: 0.42))
                .offset(x: spread)
        }
    }
}

private struct FaceButton: View {
    @ObservedObject var state: TouchPadState
    let bit: UInt32
    let radius: CGFloat
    let symbol: String
    let color: Color

    @State private var isPressed = false

    var body: some View {
        ZStack {
            GlassBackground(shape: Circle(), isPressed: isPressed, tint: color)
            Image(systemName: symbol)
                .font(.system(size: radius * 0.75, weight: .semibold))
                .foregroundStyle(color.opacity(isPressed ? 1 : 0.85))
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .modifier(PressGesture(isPressed: $isPressed) { state.setButton(bit, pressed: $0) })
    }
}

// MARK: - Shoulder buttons

private struct ShoulderButton: View {
    @ObservedObject var state: TouchPadState
    let key: String

    @State private var isPressed = false

    private var bit: UInt32 {
        switch key {
        case "L1": UInt32(SHADPS4_PAD_L1)
        case "L2": UInt32(SHADPS4_PAD_L2)
        case "R1": UInt32(SHADPS4_PAD_R1)
        default: UInt32(SHADPS4_PAD_R2)
        }
    }

    private var triggerAxis: ReferenceWritableKeyPath<TouchPadState, Int>? {
        switch key {
        case "L2": \.l2
        case "R2": \.r2
        default: nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                GlassBackground(shape: Capsule(), isPressed: isPressed)
                Text(key)
                    .font(.system(size: geo.size.height * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .contentShape(Capsule())
            .modifier(PressGesture(isPressed: $isPressed) { pressed in
                if let triggerAxis { state[keyPath: triggerAxis] = pressed ? 255 : 0 }
                state.setButton(bit, pressed: pressed)
            })
        }
    }
}

// MARK: - Share / Options

private struct MenuButton: View {
    @ObservedObject var state: TouchPadState
    let bit: UInt32
    let title: String

    @State private var isPressed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                GlassBackground(shape: Capsule(), isPressed: isPressed)
                Text(title)
                    .font(.system(size: geo.size.height * 0.32, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .contentShape(Capsule())
            .modifier(PressGesture(isPressed: $isPressed) { state.setButton(bit, pressed: $0) })
        }
    }
}

// Layout editing (dragging each control to a new position) now lives entirely in
// TouchControlsLayoutEditorView.swift, reachable from Settings, rather than in this overlay
// -- see that file for LayoutHandle and the shared position formulas.

/// Whether a gamepad (not just a keyboard or remote) is connected, kept up to date live.
@MainActor
final class ConnectedControllerMonitor: ObservableObject {
    @Published private(set) var isConnected = ConnectedControllerMonitor.hasGamepad()
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isConnected = ConnectedControllerMonitor.hasGamepad()
                }
            })
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    nonisolated static func hasGamepad() -> Bool {
        GCController.controllers().contains { $0.extendedGamepad != nil }
    }
}
