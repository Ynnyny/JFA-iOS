#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build_jdk_ios.sh — main JDK build script for iOS cross-compilation
# Adapted from AngelAuraMC/angelauramc-openjdk-build eva/buildjre-17-21-25
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/set_devkit_path_ios.sh"

cd "$SCRIPT_DIR/../../src_jdk25u"

echo "=== Starting JDK 25 iOS build ==="

# -----------------------------------------------------------
# Patch platform.m4 to recognize iOS as a target OS
# -----------------------------------------------------------
echo ">>> Patching platform.m4 for iOS support…"
bash "$SCRIPT_DIR/patch_platform_m4.sh" "make/autoconf/platform.m4"

# Also patch generated-configure if it exists (pre-generated)
for gen_conf in configure build/ios-arm64/configure-support/generated-configure.sh; do
    if [ -f "$gen_conf" ]; then
        if grep -q "unsupported operating system" "$gen_conf" 2>/dev/null; then
            sed -i '' 's/\*)/\*ios\*)\
      VAR_OS=macosx\
      VAR_OS_TYPE=unix\
      ;;\
    &/' "$gen_conf" 2>/dev/null || true
        fi
    fi
done

# -----------------------------------------------------------
# Generate configure
# -----------------------------------------------------------
echo ">>> Running configure (autogen)…"
if [ -f "common/autoconf/autogen.sh" ]; then
    bash common/autoconf/autogen.sh
fi

# Create build directory
mkdir -p build/ios-arm64

# -----------------------------------------------------------
# Run configure
# -----------------------------------------------------------
echo ">>> Running configure…"
cd build/ios-arm64

export CC CXX NUM_JOBS BOOT_JDK
export CFLAGS="-target arm64-apple-ios14.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-target arm64-apple-ios14.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)"

# Evaluate configure args (expand variables)
CONFIGURE_ARGS_EVAL=$(eval echo $CONFIGURE_ARGS)

# shellcheck disable=SC2086
bash ../../configure $CONFIGURE_ARGS_EVAL 2>&1 | tee "$BUILD_OUTPUT_DIR/configure.log"

echo ">>> Configure exit code: ${PIPESTATUS[0]}"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "::error::Configure failed — check $BUILD_OUTPUT_DIR/configure.log"
    exit 1
fi

# -----------------------------------------------------------
# Build (make images)
# -----------------------------------------------------------
echo ">>> Building JDK images (make images)…"
# shellcheck disable=SC2086
make images JOBS=$NUM_JOBS 2>&1 | tee "$BUILD_OUTPUT_DIR/build.log"

echo ">>> Build exit code: ${PIPESTATUS[0]}"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "::error::Build failed — check $BUILD_OUTPUT_DIR/build.log"
    exit 1
fi

# -----------------------------------------------------------
# Strip debug symbols from binaries
# -----------------------------------------------------------
echo ">>> Stripping debug symbols…"
find "$PWD/images/jdk" -name "*.dylib" -o -name "jexec" -o -name "javac" -o -name "java" 2>/dev/null | \
    while IFS= read -r f; do
        if [ -f "$f" ] && file "$f" | grep -q "Mach-O"; then
            strip -S "$f" 2>/dev/null || true
        fi
    done

echo "=== JDK 25 iOS build completed successfully ==="
echo "Output: $PWD/images/jdk"
