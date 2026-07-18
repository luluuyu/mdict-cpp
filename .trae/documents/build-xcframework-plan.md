# Plan: Build XCFramework Script for mdict-cpp

## Summary

Create a build script `scripts/build_xcframework.sh` that compiles the `mdict-cpp` project into an `.xcframework` usable on **iOS**, **macOS**, and **macCatalyst**.

## Current State Analysis

- The project is a **CMake-based C++17 static library** (`mdict`) with vendored deps (`miniz`, `minilzo`, `turbobase64`)
- External dependencies are built via `ExternalProject_Add` in `cmake/Project*.cmake` files
- The `cmake/Project*.cmake` files do **not** forward `CMAKE_OSX_*` flags to the ExternalProject sub-builds — a problem for cross-compilation
- No `.xcframework`, `.framework`, or `.xcodeproj` exists
- Source is pure C/C++ with no Objective-C or platform-specific code except one `#ifdef _WIN32` check
- Public C API is declared in `mdict_extern.h`, C++ API in `mdict.h`

## Proposed Changes

### 1. New file: `scripts/build_xcframework.sh`

A standalone bash script that:

#### Step A — Build each platform slice
For each of the 4 platform configurations below, the script will:

| Slice name | SDK | System Name | Archs | Deploy Target | Notes |
|---|---|---|---|---|---|
| `ios-arm64` | `iphoneos` | `iOS` | `arm64` | 12.0 | Physical iOS devices |
| `ios-arm64_x86_64-simulator` | `iphonesimulator` | `iOS` | `arm64;x86_64` | 12.0 | iOS Simulator (fat binary) |
| `macos-arm64_x86_64` | `macosx` | `Darwin` | `arm64;x86_64` | 10.15 | macOS (fat binary) |
| `maccatalyst-arm64_x86_64` | `macosx` | `Darwin` | `arm64;x86_64` | 13.0 | macCatalyst (fat binary with `-target` flag) |

For each slice, the script will:
1. Create a temporary copy of the `cmake/Project*.cmake` files with `CMAKE_OSX_SYSROOT`, `CMAKE_OSX_ARCHITECTURES`, and `CMAKE_OSX_DEPLOYMENT_TARGET` forwarded via `CMAKE_ARGS` in each `ExternalProject_Add` call — this is essential to make cross-compilation work for the vendored dependencies
2. Run `cmake -G "Unix Makefiles"` with:
   - `-DCMAKE_OSX_SYSROOT=<sdk_path>`
   - `-DCMAKE_OSX_ARCHITECTURES=<archs>`
   - `-DCMAKE_OSX_DEPLOYMENT_TARGET=<target>`
   - `-DCMAKE_BUILD_TYPE=Release`
   - `-DCMAKE_C_COMPILER=$(xcrun --find clang)`
   - `-DCMAKE_CXX_COMPILER=$(xcrun --find clang++)`
3. Restore original `cmake/Project*.cmake` files
4. Run `cmake --build . -- -j$(sysctl -n hw.ncpu)`
5. Collect `build/lib/libmdict.a` for that slice

For the **macCatalyst** slice: add `-DCMAKE_CXX_FLAGS="-target $(arch)-apple-ios13.0-macabi"` and `-DCMAKE_C_FLAGS="-target $(arch)-apple-ios13.0-macabi"` to the cmake command. Since `CMAKE_OSX_ARCHITECTURES` can't mix `-target` triples, build `arm64` and `x86_64` separately, then `lipo` them together.

#### Step B — Create framework bundles
For each platform slice, create a `.framework` bundle:
```
mdict.framework/
  ├── mdict              # Static library (or fat binary)
  ├── Info.plist          # Minimal plist with CFBundleIdentifier, etc.
  └── Headers/
      ├── mdict.h
      ├── mdict_extern.h
      └── mdict_simple_key.h
```

#### Step C — Create XCFramework
Use `xcodebuild -create-xcframework` to combine all 4 slices into:
```
mdict.xcframework/
  ├── ios-arm64/
  │   └── mdict.framework
  ├── ios-arm64_x86_64-simulator/
  │   └── mdict.framework
  ├── ios-arm64_x86_64-maccatalyst/
  │   └── mdict.framework
  ├── macos-arm64_x86_64/
  │   └── mdict.framework
  └── Info.plist
```

### 2. Modified files (temporarily patched by the script)
- `cmake/ProjectMiniz.cmake` — temporarily adds `-DCMAKE_OSX_SYSROOT=<val> -DCMAKE_OSX_ARCHITECTURES=<val> -DCMAKE_OSX_DEPLOYMENT_TARGET=<val>` to `ExternalProject_Add`'s `CMAKE_ARGS`
- `cmake/ProjectMinilzo.cmake` — same
- `cmake/ProjectTurbobase64.cmake` — same

These are restored to originals after each build.

### 3. No changes to existing source code
The script works entirely externally — no `.cc`, `.h`, or root `CMakeLists.txt` modifications needed.

## Assumptions & Decisions

1. **Deployment targets**: iOS 12.0, macOS 10.15, macCatalyst 13.0 — based on miniz/minilzo already setting `CMAKE_OSX_DEPLOYMENT_TARGET "11.0"` for macOS
2. **Static framework**: The library is static (`.a` inside a `.framework`). Apple supports this for app distribution. If a dynamic framework is needed later, we can switch but it requires linking the deps into a single `.dylib`.
3. **Public headers**: Only `mdict.h`, `mdict_extern.h`, and `mdict_simple_key.h` are exposed. Internal headers (`binutils.h`, `adler32.h`, `ripemd128.h`, `zlib_wrapper.h`, `xmlutils.h`, `fileutils.h`, and `encode/*.h`) are not needed by consumers of the C/C++ API.
4. **Skip tests**: The test target and Google Test dependency are not built (controlled by not adding `tests` subdirectory or passing `-DSKIP_TESTS=ON`)
5. **Only Release builds**: The XCFramework is built in Release mode. Debug builds can be added later if needed.

## Verification

1. Run the script: `bash scripts/build_xcframework.sh`
2. Verify output exists: `ls -la build/mdict.xcframework/`
3. Verify the 4 slices are present: `xcodebuild -show-build-settings -create-xcframework -help` or inspect the generated Info.plist
4. (Optional) Create a test iOS/macOS project that links against the XCFramework and calls `mdict_init()` / `mdict_lookup()`
