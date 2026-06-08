#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# ci_build_arch_aarch64_ios.sh — kick-off build for a single arch (iOS arm64)
# Adapted from AngelAuraMC/angelauramc-openjdk-build eva/buildjre-17-21-25
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/set_devkit_path_ios.sh"

export DEVKIT_NAME="ios-arm64"
export CLANG_VERSION=$(clang --version | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "16.0.0")

# -----------------------------------------------------------
# Determine real SDK path on Apple Silicon macOS
# -----------------------------------------------------------
IOS_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
if [ -z "$IOS_SDK_PATH" ]; then
    echo "::error::iOS SDK not found — need macOS with Xcode installed"
    exit 1
fi
export IOS_SDK_PATH
echo "iOS SDK: $IOS_SDK_PATH"

# -----------------------------------------------------------
# Set up toolchain wrappers (procursus-like)
# -----------------------------------------------------------
export IOS_TOOLCHAIN_DIR="$SCRIPT_DIR/../../toolchain"
chmod +x "$IOS_TOOLCHAIN_DIR/bin/"* 2>/dev/null || true
export PATH="$IOS_TOOLCHAIN_DIR/bin:$PATH"

# -----------------------------------------------------------
# Verify cross compilers work
# -----------------------------------------------------------
echo "0" | ios-arm64-clang -x c - -o /dev/null -c 2>/dev/null && \
    echo "iOS C compiler: OK" || { echo "iOS C compiler: FAILED"; exit 1; }

echo "int main(){}" | ios-arm64-clang++ -x c++ - -o /dev/null -c 2>/dev/null && \
    echo "iOS C++ compiler: OK" || { echo "iOS C++ compiler: FAILED"; exit 1; }

# -----------------------------------------------------------
# Configure and build JDK
# -----------------------------------------------------------
cd "$SCRIPT_DIR/../../src_jdk25u"

export CC=ios-arm64-clang
export CXX=ios-arm64-clang++

# Build
bash "$SCRIPT_DIR/build_jdk_ios.sh"
