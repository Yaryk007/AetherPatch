#!/usr/bin/env bash
# Builds the whole iOS app from a clean checkout and packages an IPA:
#   1. FEXCore (runtime/sources/fexcore-darwin) for arm64-apple-ios
#   2. libshadps4_ios.a and every static library the Xcode project links
#      (runtime/build/shadps4-ios, the layout AetherPS4-iOS.xcodeproj expects)
#   3. AetherPS4-iOS.app via xcodebuild, ad-hoc signed with its entitlements so
#      sideloading tools can carry them over when they re-sign
#
# Usage: scripts/ci/build-ios.sh [output-dir]   (default: build/ipa)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:-$ROOT/build/ipa}"
IOS_MIN="17.4" # matches IPHONEOS_DEPLOYMENT_TARGET in the Xcode project
FEX_SRC="$ROOT/runtime/sources/fexcore-darwin"
FEX_BUILD="$ROOT/runtime/build/fexcore-ios"
CORE_BUILD="$ROOT/runtime/build/shadps4-ios"
PROJECT="$ROOT/AetherPS4-iOS/AetherPS4-iOS.xcodeproj"
SCHEME="AetherPS4-iOS"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

IOS_CMAKE_ARGS=(
    -G Ninja
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_SYSROOT=iphoneos
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_SYSTEM_PROCESSOR=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER_LAUNCHER=ccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
)

# iOS fixes for submodules: scripts/ci/patches/<dir under externals>-<what>.patch
for patch in "$ROOT"/scripts/ci/patches/*.patch; do
    [[ -e "$patch" ]] || continue
    name="$(basename "$patch")"
    dir="$ROOT/externals/${name%%-*}"
    if git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
        continue # already applied
    fi
    echo "==> applying $name"
    git -C "$dir" apply "$patch"
done

echo "==> [1/3] FEXCore for iOS"
cmake -S "$FEX_SRC" -B "$FEX_BUILD" "${IOS_CMAKE_ARGS[@]}" \
    -DBUILD_FEXCORE_ONLY=ON \
    -DBUILD_FEXCORE_SMOKE=OFF \
    -DFEXCORE_PROJECT_SOURCE_DIR="$ROOT/src" \
    -DBUILD_TESTING=OFF \
    -DBUILD_FEX_LINUX_TESTS=OFF \
    -DBUILD_THUNKS=OFF \
    -DBUILD_FEXCONFIG=OFF \
    -DENABLE_CCACHE=OFF \
    -DENABLE_GDB_SYMBOLS=OFF \
    -DENABLE_LTO=OFF \
    -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
    -DENABLE_OFFLINE_TELEMETRY=OFF \
    -DENABLE_VIXL_DISASSEMBLER=OFF \
    -DENABLE_VIXL_SIMULATOR=OFF \
    -DENABLE_ZYDIS=OFF \
    -DENABLE_FEXCORE_PROFILER=OFF \
    -DTUNE_CPU=none
# BUILD_FEXCORE_ONLY marks FEXCore and its helpers EXCLUDE_FROM_ALL, so name them.
cmake --build "$FEX_BUILD" --parallel "$JOBS" --target \
    FEXCore FEXCore_Base Common CommonTools JemallocLibs cpp-optparse \
    tiny-json fmt xxhash cephes_128bit softfloat_3e rpmalloc

echo "==> [2/3] shadPS4 core (libshadps4_ios.a) for iOS"
# Native (macOS) helper the ImGui font embedding runs at build time.
HOST_TOOLS="$ROOT/runtime/build/host-tools"
mkdir -p "$HOST_TOOLS"
xcrun -sdk macosx clang++ -std=c++17 -O2 \
    "$ROOT/externals/dear_imgui/misc/fonts/binary_to_compressed_c.cpp" \
    -o "$HOST_TOOLS/binary_to_compressed_c"
cmake -S "$ROOT" -B "$CORE_BUILD" "${IOS_CMAKE_ARGS[@]}" \
    -DENABLE_SHADPS4_IOS_LIB=ON \
    -DENABLE_FEX_GUEST_CPU=ON \
    -DFEXCORE_GUEST_CPU_SOURCE_DIR="$FEX_SRC" \
    -DFEXCORE_GUEST_CPU_BUILD_DIR="$FEX_BUILD" \
    -DENABLE_DISCORD_RPC=OFF \
    -DENABLE_UPDATER=OFF \
    -DENABLE_TESTS=OFF \
    -DIMGUI_FONT_EMBED_EXECUTABLE="$HOST_TOOLS/binary_to_compressed_c" \
    -DALLOWS_ONESHOT_TIMERS_WITH_TIMEOUT_ZERO_EXITCODE=1
cmake --build "$CORE_BUILD" --target shadps4_ios --parallel "$JOBS" -- -k 0

# The Xcode project links each static library by its path inside runtime/build/shadps4-ios.
# FEXCore's go into fexcore-ios-libs/; everything else is built by its ninja output path.
mkdir -p "$CORE_BUILD/fexcore-ios-libs"
find "$FEX_BUILD" -name '*.a' -not -path '*/CMakeFiles/*' -exec cp {} "$CORE_BUILD/fexcore-ios-libs/" \;

missing=()
while IFS= read -r lib; do
    rel="${lib#../runtime/build/shadps4-ios/}"
    [[ -f "$CORE_BUILD/$rel" ]] && continue
    case "$rel" in
        fexcore-ios-libs/*) missing+=("$rel") ;;
        *) ninja -C "$CORE_BUILD" "$rel" || missing+=("$rel") ;;
    esac
done < <(grep -o 'path = "\.\./runtime/build/shadps4-ios/[^"]*\.a"' "$PROJECT/project.pbxproj" \
            | sed 's/^path = "//; s/"$//' | sort -u)
if (( ${#missing[@]} )); then
    echo "error: libraries the Xcode project links could not be built:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

echo "==> [3/3] AetherPS4-iOS.app"
DERIVED="$ROOT/build/DerivedData"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

APP="$DERIVED/Build/Products/Release-iphoneos/$SCHEME.app"
[[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 1; }

# Ad-hoc sign (inside out) so the entitlements -- increased-memory-limit, get-task-allow --
# are embedded for the sideloading tool to pick up.
for item in "$APP"/Frameworks/*; do
    codesign --force --sign - --timestamp=none "$item"
done
codesign --force --sign - --timestamp=none \
    --entitlements "$ROOT/AetherPS4-iOS/AetherPS4-iOS.entitlements" "$APP"

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
IPA="$OUT_DIR/AetherPatch.ipa"
rm -f "$IPA"
(cd "$STAGE" && zip -qry "$IPA" Payload)
echo "==> Done: $IPA ($(du -h "$IPA" | cut -f1))"
