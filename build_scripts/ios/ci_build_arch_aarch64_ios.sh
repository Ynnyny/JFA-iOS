#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export DEVKIT_NAME="ios-arm64"
export CLANG_VERSION=$(clang --version | head -1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "16.0.0")

export IOS_TOOLCHAIN_DIR="$SCRIPT_DIR/../../toolchain"
chmod +x "$IOS_TOOLCHAIN_DIR/bin/"* 2>/dev/null || true
export PATH="$IOS_TOOLCHAIN_DIR/bin:$PATH"

source "$SCRIPT_DIR/set_devkit_path_ios.sh"

# Verify cross compilers work
if ! echo "int x = 0;" | ios-arm64-clang -x c - -o /dev/null -c 2>/dev/null; then
    echo "=== iOS C compiler failed, diagnostics ==="
    echo "int x = 0;" | ios-arm64-clang -x c - -o /tmp/test_ios.o -c -v 2>&1 || true
    echo "iOS C compiler: FAILED"
    exit 1
fi
echo "iOS C compiler: OK"

if ! echo "int main(){}" | ios-arm64-clang++ -x c++ - -o /dev/null 2>/dev/null; then
    echo "iOS C++ compiler: FAILED"
    exit 1
fi
echo "iOS C++ compiler: OK"

cd "$SCRIPT_DIR/../../src_jdk25u"

export CC=ios-arm64-clang
export CXX=ios-arm64-clang++

bash "$SCRIPT_DIR/build_jdk_ios.sh"
