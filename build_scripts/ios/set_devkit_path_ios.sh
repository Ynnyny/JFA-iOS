#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# set_devkit_path_ios.sh — environment variables & devkit paths for iOS build
# Adapted from AngelAuraMC/angelauramc-openjdk-build eva/buildjre-17-21-25
# ---------------------------------------------------------------------------

export CONFIGURE_ARGS=""

# Number of parallel jobs
export NUM_JOBS=${NUM_JOBS:-$(sysctl -n hw.ncpu || echo 4)}
export BUILD_LOG="${BUILD_LOG:-${BUILD_OUTPUT_DIR:-$PWD/build}/build.log}"

# -----------------------------------------------------------
# Determine paths
# -----------------------------------------------------------
BUILD_DIR_ABS="${BUILD_OUTPUT_DIR:-$PWD/build_output}"
mkdir -p "$BUILD_DIR_ABS"
export BUILD_DIR_ABS
export BUILD_OUTPUT_DIR="$BUILD_DIR_ABS"

# -----------------------------------------------------------
# Base configure arguments for iOS cross-compilation
# -----------------------------------------------------------
CONFIGURE_ARGS="
--openjdk-target=aarch64-apple-ios
--with-sysroot=$(xcrun --sdk iphoneos --show-sdk-path)
--with-extra-ldflags=-L$(xcrun --sdk iphoneos --show-sdk-path)/usr/lib
--with-boot-jdk=$BOOT_JDK
--with-jobs=$NUM_JOBS
--with-toolchain-type=clang
--with-toolchain-path=$(xcrun --sdk iphoneos --show-sdk-path)/usr/bin
--disable-warnings-as-errors
--with-native-debug-symbols=none
--with-debug-level=release
--with-zlib=bundled
--with-libjpeg=built-in
--with-giflib=bundled
--with-libpng=bundled
--with-lcms=bundled
--with-harfbuzz=bundled
--with-freetype=bundled
--enable-headless-only
--disable-ccache
"

# Static build (required for iOS) + JRE-only build
CONFIGURE_ARGS="$CONFIGURE_ARGS
--with-jvm-features=static-build
--without-jtreg
--with-source-date=updated
"

# -----------------------------------------------------------
# Set devkit paths
# -----------------------------------------------------------
export DEVKIT_HOME="$(xcrun --sdk iphoneos --show-sdk-path)"
export DEVKIT_ROOT="$DEVKIT_HOME"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export IOS_TOOLCHAIN_DIR="${IOS_TOOLCHAIN_DIR:-$(cd "$SCRIPT_DIR/../../toolchain" && pwd)}"
export CC="${IOS_TOOLCHAIN_DIR}/bin/ios-arm64-clang"
export CXX="${IOS_TOOLCHAIN_DIR}/bin/ios-arm64-clang++"

# Ensure toolchain is on PATH
export PATH="$IOS_TOOLCHAIN_DIR/bin:$PATH"

echo "=== iOS Build Configuration ==="
echo "BOOT_JDK:       $BOOT_JDK"
echo "IOS_SDK:        $DEVKIT_HOME"
echo "CC:             $CC"
echo "CXX:            $CXX"
echo "NUM_JOBS:       $NUM_JOBS"
echo "BUILD_OUTPUT:   $BUILD_OUTPUT_DIR"
echo "==============================="
