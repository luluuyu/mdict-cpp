#!/bin/bash
#
# build_xcframework.sh
# Build mdict-cpp as an XCFramework for iOS, iOS Simulator, macOS, and macCatalyst.
#
# Usage: bash scripts/build_xcframework.sh
# Output: build/mdict.xcframework/
#
# Requires: Xcode Command Line Tools, CMake 3.14+

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$PROJECT_DIR/build/xcframework"
OUTPUT_DIR="$PROJECT_DIR/build"
FRAMEWORK_NAME="mdict"

IOS_DEPLOYMENT_TARGET=14.0
MACOS_DEPLOYMENT_TARGET=11
CATALYST_DEPLOYMENT_TARGET=13.0

# List of cmake files that need CMAKE_OSX_* forwarding
CMAKE_PROJECT_FILES=(
    "cmake/ProjectMiniz.cmake"
    "cmake/ProjectMinilzo.cmake"
    "cmake/ProjectTurbobase64.cmake"
)

# Public headers to include in the framework
PUBLIC_HEADERS=(
    "src/include/mdict.h"
    "src/include/mdict_extern.h"
    "src/include/mdict_simple_key.h"
)

# ─── Helper Functions ────────────────────────────────────────────────────────

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    if ! command -v cmake &>/dev/null; then
        error "cmake is not installed. Install it via 'brew install cmake'."
        exit 1
    fi
    if ! command -v xcrun &>/dev/null; then
        error "Xcode Command Line Tools not found. Run 'xcode-select --install'."
        exit 1
    fi
    if ! command -v xcodebuild &>/dev/null; then
        error "xcodebuild not found. Make sure Xcode is installed."
        exit 1
    fi

    local cmake_ver
    cmake_ver=$(cmake --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    info "CMake version: $(cmake --version | head -1)"
    info "Xcode: $(xcodebuild -version | head -1)"
}

# Create a backup of a file
backup_file() {
    local file="$1"
    if [[ ! -f "${file}.bak" ]]; then
        cp "$file" "${file}.bak"
    fi
}

# Restore a file from backup
restore_file() {
    local file="$1"
    if [[ -f "${file}.bak" ]]; then
        cp "${file}.bak" "$file"
        rm "${file}.bak"
    fi
}

# Patch cmake Project files to forward CMAKE_OSX_* flags to ExternalProject sub-builds.
# This is essential for cross-compilation (iOS, simulator, catalyst).
#
# Usage: patch_cmake_files <system_name> <sdk> <arch> [deploy_target] [extra_cmake_args]
#   extra_cmake_args: additional -D flags to forward (e.g. "-DCMAKE_C_FLAGS=... -DCMAKE_CXX_FLAGS=...")
patch_cmake_files() {
    local system_name="$1"
    local sdk="$2"
    local arch="$3"
    local deploy_target="$4"
    local extra_cmake_args="${5:-}"

    # Forward OSX SDK/arch flags to ExternalProject sub-builds so their output
    # is compatible with the target platform. Do NOT forward CMAKE_SYSTEM_NAME
    # (it would trigger cross-compilation mode and fail compiler detection).
    local forwarding_args="-DCMAKE_OSX_SYSROOT=${sdk} -DCMAKE_OSX_ARCHITECTURES=${arch}"
    if [[ -n "$deploy_target" ]]; then
        forwarding_args+=" -DCMAKE_OSX_DEPLOYMENT_TARGET=${deploy_target}"
    fi
    if [[ -n "$extra_cmake_args" ]]; then
        forwarding_args+=" ${extra_cmake_args}"
    fi

    for cmake_file in "${CMAKE_PROJECT_FILES[@]}"; do
        local full_path="$PROJECT_DIR/$cmake_file"
        backup_file "$full_path"

        # Insert forwarding flags after -DCMAKE_DEBUG_POSTFIX="" (remove "" to
        # avoid CMake 3.22 generating an extra empty-string subprocess arg)
        sed -i '' 's/CMAKE_ARGS -DCMAKE_DEBUG_POSTFIX=""/CMAKE_ARGS -DCMAKE_DEBUG_POSTFIX= '"${forwarding_args}"'/' "$full_path"

        info "  Patched $cmake_file for $sdk/$arch"
    done
}

# Restore all cmake Project files from backup
restore_cmake_files() {
    for cmake_file in "${CMAKE_PROJECT_FILES[@]}"; do
        restore_file "$PROJECT_DIR/$cmake_file"
    done
}

# Patch CMakeLists.txt to skip tests subdirectory (not needed for cross-compilation builds)
patch_cmakelists_tests() {
    local file="$PROJECT_DIR/CMakeLists.txt"
    backup_file "$file"
    sed -i '' 's/ADD_SUBDIRECTORY(tests)/# ADD_SUBDIRECTORY(tests) -- disabled for xcframework build/' "$file"
    info "  Patched CMakeLists.txt to skip tests"
}

# Restore CMakeLists.txt
restore_cmakelists_tests() {
    restore_file "$PROJECT_DIR/CMakeLists.txt"
}

# Ensure that a clean build directory is used
prepare_build_dir() {
    local build_dir="$1"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
}

# Build the mdict static library for one (sdk, arch, system) combo.
build_for_platform() {
    local sdk="$1"             # e.g. iphoneos, iphonesimulator, macosx
    local arch="$2"            # e.g. arm64, x86_64
    local deploy_target="$3"   # e.g. 12.0, 10.15
    local system_name="$4"     # e.g. iOS, Darwin
    local extra_cflags="$5"    # extra compiler flags (e.g. -target for catalyst)
    local build_dir="$6"       # output build directory

    info "Building for $sdk / $arch (system=$system_name, deploy=$deploy_target)..."

    prepare_build_dir "$build_dir"

    pushd "$build_dir" > /dev/null || exit 1

    # Configure cmake
    local cmake_cmd=(
        cmake -G "Unix Makefiles"
        -DCMAKE_SYSTEM_NAME="$system_name"
        -DCMAKE_OSX_SYSROOT="$sdk"
        -DCMAKE_OSX_ARCHITECTURES="$arch"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_C_COMPILER="$(xcrun --find clang)"
        -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)"
    )

    # Only set deployment target when non-empty (macOS/catalyst uses different min-os flags)
    if [[ -n "$deploy_target" ]]; then
        cmake_cmd+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy_target")
    fi

    # Add extra flags if provided (used for macCatalyst)
    if [[ -n "$extra_cflags" ]]; then
        cmake_cmd+=(-DCMAKE_C_FLAGS="$extra_cflags")
        cmake_cmd+=(-DCMAKE_CXX_FLAGS="$extra_cflags")
    fi

    cmake_cmd+=("$PROJECT_DIR")

    info "  Configuring..."
    "${cmake_cmd[@]}"

    # Build ExternalProject deps first (miniz, turbobase64 must be built
    # before mdict, but --target mdict alone won't trigger them since the
    # dependency is via library name (-lmdictminiz) not CMake target dependency).
    info "  Building ExternalProject dependencies..."
    local nproc
    nproc=$(sysctl -n hw.ncpu)
    cmake --build . -- miniz turbobase64 -j"$nproc" 2>&1 || true

    # Build the mdict library target
    info "  Building mdict library..."
    cmake --build . --target mdict -- -j"$nproc"

    # Merge dependency libs into mdict.a so the final .a is self-contained
    local lib_dir="lib"

    # For catalyst builds, ExternalProject deps are built as plain macOS
    # (without -target arm64-apple-ios-macabi). Discard them and recompile
    # from source in the fallback path so all objects share the same macabi target.
    if [[ "$extra_cflags" == *"-ios-macabi"* ]]; then
        if [[ -f "$lib_dir/libmdictminiz.a" ]]; then
            warn "  Discarding macOS-native miniz dep (forcing catalyst rebuild)..."
            rm -f "$lib_dir/libmdictminiz.a" "$lib_dir/libminiz.a" 2>/dev/null || true
        fi
        if [[ -f "$lib_dir/libmdictbase64.a" ]]; then
            warn "  Discarding macOS-native base64 dep (forcing catalyst rebuild)..."
            rm -f "$lib_dir/libmdictbase64.a" "$lib_dir/libbase64.a" 2>/dev/null || true
        fi
    fi

    if [[ -f "$lib_dir/libmdictminiz.a" && -f "$lib_dir/libmdictbase64.a" ]]; then
        info "  Merging deps into libmdict.a..."
        libtool -static -o "$lib_dir/libmdict_merged.a" \
            "$lib_dir/libmdict.a" \
            "$lib_dir/libmdictminiz.a" \
            "$lib_dir/libmdictbase64.a"
        mv "$lib_dir/libmdict_merged.a" "$lib_dir/libmdict.a"
        info "  Merge complete: libmdict.a now contains mdict + miniz + base64"
    else
        # Fallback: some deps failed to build (e.g. turbobase64 x86_64 with
        # -march=* flags that Apple Clang doesn't support).
        # Strategy: miniz can be copied from macOS arm64 (pure C), base64
        # gets compiled from scalar sources.
        warn "  Dep libs missing, trying fallback..."

        local macos_lib_dir="$BUILD_ROOT/build-macos-${arch}/lib"
        local arm64_lib_dir="$BUILD_ROOT/build-macos-arm64/lib"
        local fallback_ok=true

        # Build the correct cc command with target arch and SDK sysroot
        # so scalar compilation produces code for the right architecture
        # (e.g. x86_64 when building on Apple Silicon).
        local sdk_path
        sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null || echo "")
        local cc_base="cc -arch ${arch}"
        if [[ -n "$sdk_path" ]]; then
            cc_base="$cc_base -isysroot $sdk_path"
        fi
        if [[ -n "$deploy_target" ]]; then
            if [[ "$sdk" == macosx ]]; then
                cc_base="$cc_base -mmacosx-version-min=$deploy_target"
            elif [[ "$sdk" == iphoneos ]]; then
                cc_base="$cc_base -miphoneos-version-min=$deploy_target"
            elif [[ "$sdk" == iphonesimulator ]]; then
                cc_base="$cc_base -mios-simulator-version-min=$deploy_target"
            fi
        fi
        if [[ -n "$extra_cflags" ]]; then
            cc_base="$cc_base $extra_cflags"
        fi

        # When building for catalyst (-target *-ios-macabi), ExternalProject
        # deps are built as plain macOS objects (lacking the -target flag).
        # Forcibly recompile from source to ensure all objects share the same
        # macabi target, preventing "binaries with multiple platforms" errors
        # in xcodebuild -create-xcframework.
        local needs_catalyst_rebuild=false
        if [[ "$extra_cflags" == *"-ios-macabi"* ]]; then
            needs_catalyst_rebuild=true
        fi

        # miniz — try same-arch macOS first, then arm64, then compile from source
        if [[ ! -f "$lib_dir/libmdictminiz.a" ]]; then
            if [[ -f "$macos_lib_dir/libmdictminiz.a" ]] && ! $needs_catalyst_rebuild; then
                cp "$macos_lib_dir/libmdictminiz.a" "$lib_dir/"
                info "  Copied libmdictminiz.a from same-arch macOS build"
            elif [[ -f "$arm64_lib_dir/libmdictminiz.a" ]] && ! $needs_catalyst_rebuild; then
                cp "$arm64_lib_dir/libmdictminiz.a" "$lib_dir/"
                info "  Copied libmdictminiz.a from macOS arm64 build"
            else
                info "  Compiling miniz from source..."
                local mz_dir="$PROJECT_DIR/deps/miniz"
                local cc_cmd="$cc_base"
                local mz_objs=()
                for mz_src in miniz.c miniz_zip.c miniz_tinfl.c miniz_tdef.c; do
                    local obj_name="${mz_src%.c}.o"
                    $cc_cmd -c -o "$lib_dir/$obj_name" "$mz_dir/$mz_src" 2>/dev/null && {
                        mz_objs+=("$lib_dir/$obj_name")
                    } || {
                        warn "  Failed to compile $mz_src"
                        fallback_ok=false
                        break
                    }
                done
                if $fallback_ok; then
                    ar -rcs "$lib_dir/libmdictminiz.a" "${mz_objs[@]}"
                    # Clean up individual .o files
                    for obj in "${mz_objs[@]}"; do rm -f "$obj"; done
                    info "  Built miniz library (4 source files)"
                fi
            fi
        fi

        # base64 — compile scalar sources AND dispatch/SIMD sources.
        # _tb64dec is in turbob64v128.c (the NEON/SIMD dispatch layer),
        # not in the scalar files (turbob64c.c, turbob64d.c) — it was
        # missing from the fallback, causing linker errors.
        if [[ ! -f "$lib_dir/libmdictbase64.a" ]]; then
            info "  Compiling turbobase64 scalar + SIMD library..."
            local tb64_dir="$PROJECT_DIR/deps/turbobase64"
            local cc_cmd="$cc_base"
            # turbob64v128.c contains NEON (arm64) / SSE (x86_64) dispatch.
            # On arm64 NEON is always available; on x86_64 pass -mssse3 for SSE.
            local v128_flags=""
            if [[ "$arch" == "x86_64" ]]; then
                v128_flags="-mssse3"
            fi
            $cc_cmd -c -o "$lib_dir/tb64c.o" "$tb64_dir/turbob64c.c" && \
            $cc_cmd -c -o "$lib_dir/tb64d.o" "$tb64_dir/turbob64d.c" && \
            $cc_cmd $v128_flags -c -o "$lib_dir/tb64v128.o" "$tb64_dir/turbob64v128.c" && \
            ar -rcs "$lib_dir/libmdictbase64.a" \
                "$lib_dir/tb64c.o" "$lib_dir/tb64d.o" "$lib_dir/tb64v128.o" && \
            rm -f "$lib_dir/tb64c.o" "$lib_dir/tb64d.o" "$lib_dir/tb64v128.o" && \
            info "  Scalar base64 library built" || {
                warn "  Failed to compile scalar base64"
                fallback_ok=false
            }
        fi

        if $fallback_ok; then
            info "  Merging deps into libmdict.a..."
            libtool -static -o "$lib_dir/libmdict_merged.a" \
                "$lib_dir/libmdict.a" \
                "$lib_dir/libmdictminiz.a" \
                "$lib_dir/libmdictbase64.a"
            mv "$lib_dir/libmdict_merged.a" "$lib_dir/libmdict.a"
            info "  Merge complete"
        else
            warn "  Skipping merge — no dependency libs available"
        fi
    fi

    popd > /dev/null || exit 1

    info "  Build complete: $build_dir/lib/libmdict.a"
}

# Create a .framework bundle from a static library
create_framework() {
    local lib_path="$1"        # path to libmdict.a
    local framework_dir="$2"   # output framework path (e.g. build/mdict.framework)
    local identifier="$3"      # bundle identifier (e.g. com.mdict.ios)
    local sdk="${4:-macosx}"   # SDK name for syslibroot (e.g. iphoneos, macosx)

    info "Creating framework: $framework_dir"

    # Clean and create framework structure
    rm -rf "$framework_dir"
    mkdir -p "$framework_dir/Headers"

    # Instead of copying the .a archive directly (which can cause linker issues
    # with transitive symbol resolution across archive members), extract all
    # object files and re-link them into a single relocatable object file using
    # ld -r. This produces a Mach-O relocatable object that the final linker
    # loads as a single unit — all symbols (including those from miniz and
    # turbobase64) are available without needing -all_load or -force_load.
    local fw_sdk="$sdk"
    [[ -z "$fw_sdk" ]] && fw_sdk="macosx"
    local fw_sysroot
    fw_sysroot=$(xcrun --sdk "$fw_sdk" --show-sdk-path 2>/dev/null || echo "")
    local work_dir
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/mdict-fw.XXXXXX")
    local fw_bin="$work_dir/$FRAMEWORK_NAME"
    local ld_r_ok=true

    # Handle fat (multi-arch) archives: extract thin slices one at a time,
    # process each with ld -r, then lipo back together.
    if lipo -info "$lib_path" 2>/dev/null | grep -q 'Architectures in the fat file'; then
        local archs
        archs=$(lipo -info "$lib_path" 2>/dev/null | sed -n 's/.*are: //p')
        info "  Fat archive with architectures: $archs"
        local thin_objects=()
        for arch in $archs; do
            local thin_lib="$work_dir/libthin-$arch.a"
            lipo -thin "$arch" -output "$thin_lib" "$lib_path" 2>&1 || {
                ld_r_ok=false; break
            }
            local thin_obj_dir="$work_dir/obj-$arch"
            mkdir -p "$thin_obj_dir"
            pushd "$thin_obj_dir" > /dev/null || exit 1
            ar -x "$thin_lib" 2>&1 || { ld_r_ok=false; popd > /dev/null; break; }
            rm -f __.SYMDEF __.SYMDEF\ SORTED 2>/dev/null || true
            local this_obj="$work_dir/mdict-$arch.o"
            local ld_cmd=("xcrun" "--sdk" "$fw_sdk" "ld" "-r" "-keep_private_externs")
            if [[ -n "$fw_sysroot" ]]; then
                ld_cmd+=("-syslibroot" "$fw_sysroot")
            fi
            ld_cmd+=("-o" "$this_obj" *.o)
            "${ld_cmd[@]}" 2>&1 || { ld_r_ok=false; popd > /dev/null; break; }
            popd > /dev/null || exit 1
            thin_objects+=("$this_obj")
        done
        if $ld_r_ok && [[ ${#thin_objects[@]} -gt 0 ]]; then
            if [[ ${#thin_objects[@]} -eq 1 ]]; then
                cp "${thin_objects[0]}" "$fw_bin"
            else
                lipo -create "${thin_objects[@]}" -output "$fw_bin" 2>&1 || ld_r_ok=false
            fi
        fi
    else
        # Thin (single-arch) archive: extract directly
        pushd "$work_dir" > /dev/null || exit 1
        ar -x "$lib_path" 2>&1 || ld_r_ok=false
        rm -f __.SYMDEF __.SYMDEF\ SORTED 2>/dev/null || true
        if $ld_r_ok; then
            local ld_cmd=("xcrun" "--sdk" "$fw_sdk" "ld" "-r" "-keep_private_externs")
            if [[ -n "$fw_sysroot" ]]; then
                ld_cmd+=("-syslibroot" "$fw_sysroot")
            fi
            ld_cmd+=("-o" "$fw_bin" *.o)
            "${ld_cmd[@]}" 2>&1 || ld_r_ok=false
        fi
        popd > /dev/null || exit 1
    fi

    if $ld_r_ok && [[ -f "$fw_bin" ]]; then
        mv "$fw_bin" "$framework_dir/$FRAMEWORK_NAME"
        rm -rf "$work_dir"
        info "  Created relocatable object (ld -r): $framework_dir/$FRAMEWORK_NAME"
    else
        warn "  ld -r failed, falling back to .a archive..."
        rm -rf "$work_dir"
        cp "$lib_path" "$framework_dir/$FRAMEWORK_NAME"
        info "  (fallback) Copied static library"
    fi

    copy_headers_and_plist "$framework_dir" "$identifier"
}

# Shared helper: copy headers and generate Info.plist into a framework
copy_headers_and_plist() {
    local framework_dir="$1"
    local identifier="$2"

    # Copy public headers
    for header in "${PUBLIC_HEADERS[@]}"; do
        cp "$PROJECT_DIR/$header" "$framework_dir/Headers/"
    done

    # Generate Info.plist
    cat > "$framework_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$identifier</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>MinimumOSVersion</key>
    <string>${IOS_DEPLOYMENT_TARGET}</string>
</dict>
</plist>
EOF

    info "  Framework created at $framework_dir"
}

# ─── Main Build Process ──────────────────────────────────────────────────────

main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         mdict-cpp XCFramework Builder                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    check_prerequisites

    # -----------------------------------------------------------------------
    # Phase 1: Build static libraries for each (sdk, arch) combination
    # -----------------------------------------------------------------------
    info "Phase 1: Building static libraries..."

    # We patch cmake files to forward platform flags to ExternalProject deps.
    # Each build gets its own patching session (needs different flags).

    # ─── 1. iOS arm64 ────────────────────────────────────────────────────────
    info "[1/6] iOS arm64 (device)"
    patch_cmake_files "iOS" "iphoneos" "arm64" "$IOS_DEPLOYMENT_TARGET"
    patch_cmakelists_tests
    build_for_platform \
        "iphoneos" "arm64" "$IOS_DEPLOYMENT_TARGET" "iOS" "" \
        "$BUILD_ROOT/build-ios-arm64"
    restore_cmake_files
    restore_cmakelists_tests

    # ─── 2. iOS Simulator arm64 ──────────────────────────────────────────────
    info "[2/6] iOS Simulator arm64"
    patch_cmake_files "iOS" "iphonesimulator" "arm64" "$IOS_DEPLOYMENT_TARGET"
    patch_cmakelists_tests
    build_for_platform \
        "iphonesimulator" "arm64" "$IOS_DEPLOYMENT_TARGET" "iOS" "" \
        "$BUILD_ROOT/build-ios-simulator-arm64"
    restore_cmake_files
    restore_cmakelists_tests

    # ─── 3. macOS arm64 ─────────────────────────────────────────────────────
    info "[3/6] macOS arm64"
    patch_cmake_files "Darwin" "macosx" "arm64" "$MACOS_DEPLOYMENT_TARGET"
    patch_cmakelists_tests
    build_for_platform \
        "macosx" "arm64" "$MACOS_DEPLOYMENT_TARGET" "Darwin" "" \
        "$BUILD_ROOT/build-macos-arm64"
    restore_cmake_files
    restore_cmakelists_tests

    # ─── 4. macOS x86_64 ────────────────────────────────────────────────────
    info "[4/6] macOS x86_64"
    patch_cmake_files "Darwin" "macosx" "x86_64" "$MACOS_DEPLOYMENT_TARGET"
    patch_cmakelists_tests
    build_for_platform \
        "macosx" "x86_64" "$MACOS_DEPLOYMENT_TARGET" "Darwin" "" \
        "$BUILD_ROOT/build-macos-x86_64"
    restore_cmake_files
    restore_cmakelists_tests

    # ─── 5. macCatalyst arm64 ───────────────────────────────────────────────
    # For Catalyst: ExternalProject sub-builds get CMAKE_OSX_SYSROOT/ARCH
    # but NOT the -target flag (to avoid CMake quoting issues). Any dependency
    # that fails to build will be recompiled from source in the fallback path
    # with the correct -target flag.
    local catalyst_target_arm64="-target arm64-apple-ios-macabi"
    info "[5/6] macCatalyst arm64"
    patch_cmake_files "Darwin" "macosx" "arm64" "$MACOS_DEPLOYMENT_TARGET"
    patch_cmakelists_tests
    build_for_platform \
        "macosx" "arm64" "" "Darwin" \
        "${catalyst_target_arm64}" \
        "$BUILD_ROOT/build-catalyst-arm64"
    restore_cmake_files
    restore_cmakelists_tests

    # ─── 6. macCatalyst x86_64 ──────────────────────────────────────────────
    local catalyst_target_x86_64="-target x86_64-apple-ios-macabi"
    info "[6/6] macCatalyst x86_64"
    patch_cmake_files "Darwin" "macosx" "x86_64" "$MACOS_DEPLOYMENT_TARGET"
    patch_cmakelists_tests
    build_for_platform \
        "macosx" "x86_64" "" "Darwin" \
        "${catalyst_target_x86_64}" \
        "$BUILD_ROOT/build-catalyst-x86_64"
    restore_cmake_files
    restore_cmakelists_tests

    # -----------------------------------------------------------------------
    # Phase 2: Create fat (multi-arch) binaries with lipo
    # -----------------------------------------------------------------------
    info "Phase 2: Creating fat binaries with lipo..."

    mkdir -p "$BUILD_ROOT/fat-libs"

    # iOS Simulator: single arch (arm64), just copy
    cp "$BUILD_ROOT/build-ios-simulator-arm64/lib/libmdict.a" \
       "$BUILD_ROOT/fat-libs/libmdict-ios-simulator.a"
    info "  iOS Simulator lib copied (arm64 only)"

    # macOS: arm64 + x86_64 fat binary
    lipo -create \
        "$BUILD_ROOT/build-macos-arm64/lib/libmdict.a" \
        "$BUILD_ROOT/build-macos-x86_64/lib/libmdict.a" \
        -output "$BUILD_ROOT/fat-libs/libmdict-macos.a"
    info "  macOS fat lib created"

    # macCatalyst: arm64 + x86_64 fat binary (Xcode 26+ requires a single
    # framework per platform, not separate single-arch frameworks)
    lipo -create \
        "$BUILD_ROOT/build-catalyst-arm64/lib/libmdict.a" \
        "$BUILD_ROOT/build-catalyst-x86_64/lib/libmdict.a" \
        -output "$BUILD_ROOT/fat-libs/libmdict-catalyst.a"
    info "  macCatalyst fat lib created"

    # iOS device: single arch, just copy
    cp "$BUILD_ROOT/build-ios-arm64/lib/libmdict.a" \
       "$BUILD_ROOT/fat-libs/libmdict-ios.a"

    # -----------------------------------------------------------------------
    # Phase 3: Create .framework bundles
    # -----------------------------------------------------------------------
    info "Phase 3: Creating framework bundles..."

    mkdir -p "$BUILD_ROOT/frameworks"

    create_framework \
        "$BUILD_ROOT/fat-libs/libmdict-ios.a" \
        "$BUILD_ROOT/frameworks/ios-arm64/$FRAMEWORK_NAME.framework" \
        "com.mdict.ios" \
        "iphoneos"

    create_framework \
        "$BUILD_ROOT/fat-libs/libmdict-ios-simulator.a" \
        "$BUILD_ROOT/frameworks/ios-arm64-simulator/$FRAMEWORK_NAME.framework" \
        "com.mdict.ios-simulator" \
        "iphonesimulator"

    create_framework \
        "$BUILD_ROOT/fat-libs/libmdict-macos.a" \
        "$BUILD_ROOT/frameworks/macos-arm64_x86_64/$FRAMEWORK_NAME.framework" \
        "com.mdict.macos" \
        "macosx"

    # Catalyst: single fat framework (arm64 + x86_64)
    create_framework \
        "$BUILD_ROOT/fat-libs/libmdict-catalyst.a" \
        "$BUILD_ROOT/frameworks/maccatalyst/$FRAMEWORK_NAME.framework" \
        "com.mdict.maccatalyst" \
        "macosx"

    # -----------------------------------------------------------------------
    # Phase 4: Create .xcframework
    # -----------------------------------------------------------------------
    info "Phase 4: Creating XCFramework..."

    rm -rf "$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"

    local xcframework_args=(
        xcodebuild -create-xcframework
        -framework "$BUILD_ROOT/frameworks/ios-arm64/$FRAMEWORK_NAME.framework"
        -framework "$BUILD_ROOT/frameworks/ios-arm64-simulator/$FRAMEWORK_NAME.framework"
        -framework "$BUILD_ROOT/frameworks/macos-arm64_x86_64/$FRAMEWORK_NAME.framework"
        -framework "$BUILD_ROOT/frameworks/maccatalyst/$FRAMEWORK_NAME.framework"
        -output "$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"
    )

    info "  Running xcodebuild -create-xcframework..."
    "${xcframework_args[@]}"

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo -e "║  ${GREEN}Build complete!${NC}                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    info "XCFramework created at: $OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"
    echo ""
    info "XCFramework structure:"
    ls -R "$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework/" 2>/dev/null || true
    echo ""

    # Print library info for each slice
    info "Library architecture details:"
    for fw in "$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"/*/; do
        local slice_name
        slice_name=$(basename "$fw")
        local lib_path="$fw/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"
        if [[ -f "$lib_path" ]]; then
            local arch_info
            arch_info=$(lipo -info "$lib_path" 2>/dev/null || echo "unknown")
            echo "  $slice_name: $arch_info"
        fi
    done

    echo ""
    info "Done!"
}

# ─── Cleanup on exit ─────────────────────────────────────────────────────────

cleanup() {
    # Restore any backed-up files that might have been left modified
    restore_cmake_files 2>/dev/null || true
    restore_cmakelists_tests 2>/dev/null || true
}

trap cleanup EXIT

# ─── Run ─────────────────────────────────────────────────────────────────────

main "$@"
