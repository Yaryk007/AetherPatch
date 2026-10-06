<p align="center">
  <img src="AetherPS4-iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="140" alt="AetherPS4 logo">
</p>

# AetherPatch

A fork of [AetherPS4](https://github.com/Leviidev/AetherPS4) that fixes JIT on **iOS 26**.

AetherPS4 is experimental PlayStation 4 emulation for iOS, built on [shadPS4](https://github.com/shadps4-emu/shadPS4)
with an ARM64-ported [FEXCore](https://github.com/FEX-Emu/FEX) x86-64 → ARM64 JIT and a native
SwiftUI front end.

## What this fork changes

- **JIT script fixed.** The StikDebug script bundled with the app never handled the "allocate a
  fresh region" request (`x0 == 0`) that every JIT allocation in the emulator actually sends,
  so every request came back as a null pointer. The new script allocates the region (`_M…,rx`)
  before preparing it, and supports the detach command.
- **No more freezes after StikDebug goes to the background.** On iOS 26, StikDebug gets suspended
  (and eventually killed) as soon as you switch back to the emulator. Upstream kept the debugger
  attached for the whole session, so the next signal or JIT request froze the game. AetherPatch
  claims one JIT pool (128 MB by default) right after StikDebug attaches, detaches the debugger,
  and serves every later JIT allocation (FEXCore code buffers, HLE veneers, shader SRT walkers)
  from that pool.
- **Reproducible builds.** The top-level `CMakeLists.txt` was accidentally overwritten upstream,
  and the Xcode project pointed at the original author's machine. Both are fixed, and GitHub
  Actions now builds the IPA from a clean checkout.

### Getting the IPA

Open the [Actions tab](../../actions/workflows/build-ipa.yml), pick the latest green run and
download the `AetherPatch-ipa` artifact. Sideload it with SideStore, AltStore or similar, then
enable JIT with [StikDebug](https://github.com/StikDebug/StikDebug).

### Tuning (optional)

Both settings are user defaults in the app's domain:

| Key | Default | Meaning |
| --- | --- | --- |
| `jitPoolSizeMB` | `128` | Size of the JIT pool claimed at launch (32–1024). |
| `jitKeepDebuggerAttached` | `false` | Keep StikDebug attached instead of detaching after the pool is claimed (the old behaviour). |

## File structure

```
.
├── AetherPS4-iOS/          Native iOS app (SwiftUI front end, Xcode project)
│   ├── Sources/
│   │   ├── App/            App entry point, AppDelegate, crash logging
│   │   ├── Models/         Game library, emulator process control, save data
│   │   └── Views/          SwiftUI screens (library, game detail, settings, console)
│   ├── Resources/
│   ├── Frameworks/
│   └── AetherPS4-iOS.xcodeproj
│
├── android/BachataS4/      Android app (Kotlin/Compose front end)
│
├── launcher/AetherPS4/     Standalone macOS launcher (Swift package)
│
├── src/                    shadPS4 emulator core (shared across all platforms)
│   ├── core/                Kernel/HLE emulation, memory management, signal handling
│   │   ├── fex/                FEXCore guest-engine integration (signal handling, unaligned access)
│   │   ├── guest_cpu/           Guest CPU abstraction / HLE call bridging
│   │   ├── ios/                 iOS-specific JIT allocator (dual-mapped RW/RX memory)
│   │   └── libraries/            PS4 system library (libkernel, libSceGnmDriver, etc.) implementations
│   ├── video_core/          Vulkan renderer (MoltenVK on Apple platforms)
│   ├── shader_recompiler/   GCN/RDNA shader → SPIR-V recompiler
│   ├── input/                Controller/keyboard/mouse input handling
│   ├── imgui/                ImGui-based debug UI and mobile overlay
│   └── platform/             Per-platform integration glue (ios/, bachata/, ...)
│
├── runtime/
│   ├── sources/
│   │   ├── fexcore-darwin/     FEXCore fork, ported to run on Apple ARM64 hosts (used by iOS/macOS)
│   │   ├── fex/                 Upstream FEXCore source (used by other platform targets)
│   │   └── box64/                Box64 (used for Android/Linux x86 support)
│   ├── probes/               Standalone build smoke-test programs
│   └── scripts/               Build/packaging scripts (e.g. build-ipa.sh)
│
├── externals/               Third-party dependencies (git submodules: SDL3, Vulkan headers,
│                             glslang, spdlog, FFmpeg, etc.)
│
├── tools/                    Auxiliary tools (PKG extraction, etc.)
├── docs/, documents/         Documentation
├── cmake/                     CMake helper modules
├── CMakeLists.txt             Top-level build configuration (desktop, Android, iOS targets)
└── PORTING.md                  Notes on porting shadPS4 to new platforms
```

## Building

On a Mac with Xcode 26, `brew install ninja ccache`, fetch the submodules, then run
`scripts/ci/build-ios.sh`. It builds FEXCore, the shadPS4 core and the app, and writes
`build/ipa/AetherPatch.ipa`. The CI workflow (`.github/workflows/build-ipa.yml`) runs the
same script. See `PORTING.md` for platform-porting notes. The iOS app requires an external JIT-granting mechanism
(StikDebug or similar) since sideloaded iOS apps cannot request the `MAP_JIT` entitlement.

## License

See `LICENSE` and `LICENSES/` (shadPS4 core is GPL-2.0-or-later; see `REUSE.toml` for
per-component licensing).

## Notice

Because Leviidev stopped updating aetherps4 focusing on hus, I will make my own updates and i do them diffrently
