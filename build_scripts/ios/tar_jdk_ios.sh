#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# tar_jdk_ios.sh — package built JDK as .tar.xz
# Adapted from AngelAuraMC/angelauramc-openjdk-build
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/set_devkit_path_ios.sh"

# Locate build output
BUILD_DIR="${BUILD_DIR_ABS:-$PWD/build_output}"
JDK_IMAGE="$SCRIPT_DIR/../../src_jdk25u/build/ios-arm64/images/jdk"

if [ ! -d "$JDK_IMAGE" ]; then
    echo "::error::JDK image not found at $JDK_IMAGE"
    echo "Build may have failed or path differs."
    exit 1
fi

# Remove unnecessary files to minimize JRE size
echo ">>> Stripping unnecessary files from JRE…"
rm -rf "$JDK_IMAGE/demo" 2>/dev/null || true
rm -rf "$JDK_IMAGE/sample" 2>/dev/null || true
rm -rf "$JDK_IMAGE/man" 2>/dev/null || true
rm -f "$JDK_IMAGE/src.zip" 2>/dev/null || true

# Ensure release file exists (it always does in a normal build)
if [ ! -f "$JDK_IMAGE/release" ]; then
    echo "WARNING: release file not found — creating one"
    cat > "$JDK_IMAGE/release" << RELEOF
JAVA_VERSION="25"
MODULES="java.base java.datatransfer java.logging java.scripting java.naming java.security.jgss java.transaction.xa java.xml java.rmi java.sql java.desktop"
OS_NAME="Darwin"
OS_ARCH="aarch64"
SOURCE="git:jdk-25-ga"
RELEOF
fi

# Verify release file
echo "=== release file ==="
cat "$JDK_IMAGE/release"

# Package
OUTPUT_NAME="jdk25-ios-aarch64-jre"
OUTPUT_DIR="$SCRIPT_DIR/../../"
cd "$(dirname "$JDK_IMAGE")"

echo ">>> Creating tar.xz…"
# Use high compression (xz -9 is slow but worth it for iOS deployment)
XZ_OPT="-9 -T0" tar -cJf "$OUTPUT_DIR/$OUTPUT_NAME.tar.xz" \
    --owner=0 --group=0 \
    "$(basename "$JDK_IMAGE")"

cd "$OUTPUT_DIR"
sha256sum "$OUTPUT_NAME.tar.xz" > "$OUTPUT_NAME.tar.xz.sha256"

echo "=== Packaging complete ==="
echo "File:  $OUTPUT_DIR/$OUTPUT_NAME.tar.xz"
echo "Size:  $(ls -lh "$OUTPUT_NAME.tar.xz" | awk '{print $5}')"
echo "SHA256:$(cat "$OUTPUT_NAME.tar.xz.sha256")"
