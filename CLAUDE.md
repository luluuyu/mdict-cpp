# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**mdict-cpp** is a C++17 library for parsing MDX/MDD dictionary files. MDX files contain dictionary content (HTML definitions), MDD files contain resources (images, audio). It is a library within the larger **MysicAudio** project (at `Libs/mdict-cpp`).

## Build & Test

```bash
# Build everything (debug)
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Debug ..
make -j$(sysctl -n hw.ncpu)

# Build specific targets
cmake --build . --target mdict          # Static library only
cmake --build . --target mydict          # CLI tool at build/bin/mydict

# Run all tests
cd build && ctest --output-on-failure

# Run a single test binary directly
./build/bin/test_lookup
./build/bin/test_wordlist
./build/bin/test_xmlutils
./build/bin/test_base64
./build/bin/test_binutils
./build/bin/test_ripemd128
./build/bin/test_adler32
```

## Apple XCFramework

Build a multi-platform XCFramework for iOS/macOS/Catalyst:

```bash
bash scripts/build_xcframework.sh
# Output: build/mdict.xcframework/
```

The script builds 6 slices (iOS arm64, iOS Simulator arm64, macOS arm64/x86_64, Catalyst arm64/x86_64), merges dependency archives into `libmdict.a`, wraps each in a `.framework`, then combines into an XCFramework.

## Code Formatting

```bash
bash scripts/fmt.sh
# Runs: clang-format -style=Google -i src/*.cc src/include/*.h tests/*.cc
```

Uses Google C++ style via clang-format.

## Architecture

### File Format (MDX/MDD)

A dictionary file has three major sections after the header:
1. **Header** — XML metadata (title, version, encoding, encryption flags)
2. **Key Blocks** — compressed index mapping headwords → record offsets
3. **Record Blocks** — compressed dictionary content (HTML or binary resources)

### Core Modules

| Module | Files | Purpose |
|--------|-------|---------|
| **Mdict** | `src/mdict.cc`, `src/include/mdict.h` | Core parser: reads header, decompresses key/record blocks, binary search lookup |
| **C API** | `src/mdict_extern.cc`, `src/include/mdict_extern.h` | FFI bindings: `mdict_init`, `mdict_lookup`, `mdict_locate`, `mdict_keylist`, etc. |
| **CLI** | `src/mydict.cc` | `bin/mydict` tool for querying/searching dictionaries |
| **Binary utils** | `src/binutils.cc`, `src/include/binutils.h` | Big-endian integer conversion, UTF-16/UTF-8 encoding |
| **Hash** | `src/adler32.cc`, `src/ripemd128.c` | Checksum and encryption support (RIPEMD-128 for encrypted key info) |
| **Encoding** | `src/encode/` | Base64 encode/decode, hex-to-bytes, UTF-16LE-to-UTF-8 |
| **XML parser** | `src/include/xmlutils.h` | Simple inline XML header attribute extractor |
| **Zlib wrapper** | `src/include/zlib_wrapper.h` | Inline zlib decompression (uses vendored miniz) |

### Key Data Flow

```
MDX/MDD file → Mdict::init()
  → read_header()                — Parse header XML
  → read_key_block_header()      — Read block count, entry count, sizes
  → read_key_block_info()        — Decompress + parse key block info
  → decode_key_block()           — Decompress + split key blocks into key_list

Mdict::lookup(word)
  → Binary search key_block_info_list
  → decode_key_block_by_block_id()
  → Binary search within block (reduce_key_info_block_items_vector)
  → resolve record block (reduce_record_block_offset)
  → decode_record_block_by_rid() — Decompress + parse record block
  → extract definition (reduce_particial_keys_vector)
```

### External Dependencies

All vendored in `deps/`:
- **miniz** — zlib-compatible decompression (used)
- **minilzo** — LZO decompression (vendored but NOT wired into the parser)
- **turbobase64** — SIMD-accelerated base64 (used)
- **googletest** — git submodule for unit tests
- **hunspell** — spell checker (vendored but unused; `suggest()` and `stem()` are stubs)

Dependencies are built via CMake `ExternalProject_Add` (see `cmake/*.cmake`). The `mdict` static library links `mdictminiz` and `mdictbase64` — the XCFramework build merges these into a single `libmdict.a` via `libtool -static`.

### Notable Unimplemented Areas

- LZO decompression (minilzo dep exists, code not wired)
- Record block encryption
- Version < 2.0 uncompressed key block info path
- `suggest()` / `stem()` stubs
- Key block info Adler32 checksums are skipped during read

### Test Dictionaries

Test data lives in `tests/testdict/` with `testdict.mdx` (the test fixture) and `wordlist.txt` (expected key list for verification). Test binaries copy these to the build directory at configure time.
