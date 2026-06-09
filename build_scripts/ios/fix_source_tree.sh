#!/bin/bash
# fix_source_tree.sh — applies iOS-specific fixes directly to the jdk25u source tree
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
JDK_DIR="$REPO_ROOT/src_jdk25u"

echo "=== Fixing JDK source tree for iOS build ==="
cd "$JDK_DIR"

MISSING_INCLUDE="$REPO_ROOT/ios-missing-include"

# -----------------------------------------------------------
# 1. Create ios-override/include with missing iOS SDK headers
# -----------------------------------------------------------
echo ">>> Creating ios-override/include with missing headers..."
mkdir -p ios-override/include/sys
mkdir -p ios-override/include/Cocoa
mkdir -p ios-override/include/JavaNativeFoundation
mkdir -p ios-override/include/Security
mkdir -p ios-override/include/SystemConfiguration
mkdir -p ios-override/include/objc
mkdir -p ios-override/include/net
mkdir -p ios-override/include/netinet
mkdir -p ios-override/include/netinet6

if [ -d "$MISSING_INCLUDE" ]; then
  cp -r "$MISSING_INCLUDE/"* ios-override/include/ 2>/dev/null || true
fi

# Create a compat sys/mman.h — iOS SDK provides a minimal version that lacks
# MAP_NORESERVE, MAP_JIT, and some other macOS-specific constants used by HotSpot.
# We shadow the SDK's version (via -I override) and add the missing ones.
cat > ios-override/include/sys/mman.h << 'MMANEOF'
#ifndef _IOS_OVERRIDE_SYS_MMAN_H
#define _IOS_OVERRIDE_SYS_MMAN_H
/* Self-contained sys/mman.h stub for iOS cross-compilation.
   iOS SDK may have a minimal mman.h or none at all — provide all
   POSIX/BSD constants needed by HotSpot.  Do NOT include any
   macOS-specific internal Darwin headers (not available in iOS SDK). */
#include <sys/types.h>

/* POSIX basic protection flags */
#ifndef PROT_READ
#define PROT_READ       0x01
#endif
#ifndef PROT_WRITE
#define PROT_WRITE      0x02
#endif
#ifndef PROT_EXEC
#define PROT_EXEC       0x04
#endif
#ifndef PROT_NONE
#define PROT_NONE       0x00
#endif
/* MAP_* flags (macOS/BSD values) */
#ifndef MAP_FILE
#define MAP_FILE        0x0000
#endif
#ifndef MAP_SHARED
#define MAP_SHARED      0x0001
#endif
#ifndef MAP_PRIVATE
#define MAP_PRIVATE     0x0002
#endif
#ifndef MAP_FIXED
#define MAP_FIXED       0x0010
#endif
#ifndef MAP_NORESERVE
#define MAP_NORESERVE   0x40
#endif
#ifndef MAP_JIT
#define MAP_JIT         0x0800
#endif
#ifndef MAP_ANON
#define MAP_ANON        0x1000
#endif
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS   MAP_ANON
#endif
#ifndef MAP_FAILED
#define MAP_FAILED      ((void *)-1)
#endif
/* madvise() advice flags (BSD values) */
#ifndef MADV_NORMAL
#define MADV_NORMAL     0
#endif
#ifndef MADV_RANDOM
#define MADV_RANDOM     1
#endif
#ifndef MADV_SEQUENTIAL
#define MADV_SEQUENTIAL 2
#endif
#ifndef MADV_WILLNEED
#define MADV_WILLNEED   3
#endif
#ifndef MADV_DONTNEED
#define MADV_DONTNEED   4
#endif
#ifndef MADV_FREE
#define MADV_FREE       5
#endif
/* mincore — not available on iOS, provide stub */
static inline int mincore(void *addr, size_t len, unsigned char *vec) {
    (void)addr; (void)len; (void)vec;
    return -1;
}
#endif /* _IOS_OVERRIDE_SYS_MMAN_H */
MMANEOF

echo "  -> Created ios-override with missing headers"

# -----------------------------------------------------------
# 1d. Create mach/mach_vm.h stub (iOS SDK says unsupported, but types
#     are already defined in <mach/arm/vm_types.h> — just provide a
#     header guard bypass so the iOS SDK header can be included safely)
# -----------------------------------------------------------
mkdir -p ios-override/include/mach
cat > ios-override/include/mach/mach_vm.h << 'MACHVMEOF'
#ifndef _IOS_OVERRIDE_MACH_MACH_VM_H
#define _IOS_OVERRIDE_MACH_MACH_VM_H
/* Stub: mach_vm.h declares "unsupported" on iOS via #error.
   The actual types (mach_vm_offset_t etc) are defined in
   <mach/arm/vm_types.h> which comes from including <mach/kern_return.h>.
   We just include the necessary headers without triggering the #error. */
#include <mach/kern_return.h>
#include <mach/vm_types.h>
/* The memMapPrinter code includes mach_vm.h for these declarations.
   On iOS they're in vm_types.h already. */
#endif
MACHVMEOF

# -----------------------------------------------------------
# 1e. Remove X11-specific java.desktop sources for iOS
#     (these reference xlib/Motif native code not available on iOS)
#     macOS uses its own font manager, so these are not needed.
# -----------------------------------------------------------
echo ">>> Removing X11-specific java.desktop sources..."
for f in \
  src/java.desktop/unix/classes/sun/awt/X11FontManager.java \
  src/java.desktop/unix/classes/sun/font/NativeGlyphMapper.java \
  src/java.desktop/unix/classes/sun/font/MFontConfiguration.java
do
  if [ -f "$f" ]; then
    rm -f "$f"
    echo "  -> Removed: $f"
  fi
done

# -----------------------------------------------------------
# 1b. Clean up partial patch application (reject files from git apply --reject)
# -----------------------------------------------------------
echo ">>> Cleaning up partial patches..."
find "$JDK_DIR" -name "*.rej" -delete 2>/dev/null || true
# Restore files that were partially patched by re-cloning them
# We do this for the key files we know are problematic
for f in \
  src/hotspot/os/posix/signals_posix.cpp \
  src/hotspot/os_cpu/bsd_aarch64/icache_bsd_aarch64.hpp
do
  if [ -f "$JDK_DIR/$f" ]; then
    git checkout -- "$f" 2>/dev/null || true
  fi
done
echo "  -> Cleaned up partial patches"

# -----------------------------------------------------------
# 1c. Add #include <sys/mman.h> to signals_posix.cpp
#     (needed for PROT_READ etc when iOS SDK lacks sys/mman.h)
# -----------------------------------------------------------
echo ">>> Patching signals_posix.cpp..."
SIGNALS_FILE="src/hotspot/os/posix/signals_posix.cpp"
if [ -f "$SIGNALS_FILE" ] && ! grep -q '#include <sys/mman.h>' "$SIGNALS_FILE" 2>/dev/null; then
  python3 -c "
with open('$SIGNALS_FILE', 'r') as f:
    lines = f.readlines()
# Find the line with #include <signal.h> and insert after it
for i, line in enumerate(lines):
    if '#include <signal.h>' in line:
        lines.insert(i + 1, '#include <sys/mman.h>\n')
        break
with open('$SIGNALS_FILE', 'w') as f:
    f.writelines(lines)
print('  -> Added #include <sys/mman.h>')
" 2>&1 || echo "  -> Warning: could not patch signals_posix.cpp"
fi

# -----------------------------------------------------------
# 2. Fix BUILDJDK linker flags for macOS host
#    Apple clang masquerading as GCC gets -Wl,-soname which macOS
#    ld doesn't support. Replace -soname with -install_name in the
#    gcc toolchain section when built on macOS (first occurrence).
# -----------------------------------------------------------
echo ">>> Fixing BUILDJDK linker flags for macOS host..."
CFLAGS_M4="make/autoconf/flags-cflags.m4"
if [ -f "$CFLAGS_M4" ]; then
  python3 << 'PYEOF'
# In the GCC section of flags-cflags.m4, replace -soname with a
# macOS-aware version that checks if it's building on macOS
import re

with open('make/autoconf/flags-cflags.m4', 'r') as f:
    content = f.read()

# The m4 file uses [$]1 to quote the $ in m4 macro arguments
# The literal text in the file is: SET_SHARED_LIBRARY_NAME='-Wl,-soname=[$]1'
# We need to replace the first occurrence (GCC branch) with a macOS check
old = "SET_SHARED_LIBRARY_NAME='-Wl,-soname=[$]1'"
new = '''if test "x$OPENJDK_BUILD_OS" = xmacosx; then
    SET_SHARED_LIBRARY_NAME='-Wl,-install_name,@rpath/[$]1'
  else
    SET_SHARED_LIBRARY_NAME='-Wl,-soname=[$]1'
  fi'''

count = content.count(old)
if count > 0:
    content = content.replace(old, new, 1)
    with open('make/autoconf/flags-cflags.m4', 'w') as f:
        f.write(content)
    print(f'  -> Patched gcc branch for macOS -soname (found {count})')
else:
    print('  -> -soname pattern not found in flags-cflags.m4')
PYEOF
fi

# -----------------------------------------------------------
# 3. Patch flags-cflags.m4: only add -mmacosx-version-min for BUILDJDK
# -----------------------------------------------------------
echo ">>> Patching flags-cflags.m4..."
CFLAGS_M4="make/autoconf/flags-cflags.m4"
if [ -f "$CFLAGS_M4" ]; then
  # Using python3 for cross-platform sed compatibility
  python3 -c "
import re
with open('$CFLAGS_M4', 'r') as f:
    content = f.read()
old = 'if test \"x\$OPENJDK_TARGET_OS\" = xmacosx; then'
new = 'if test \"x\$OPENJDK_TARGET_OS\" = xmacosx && test \"x\$JVM_BUILDJDK\" = xtrue; then'
if old in content:
    content = content.replace(old, new, 1)
    with open('$CFLAGS_M4', 'w') as f:
        f.write(content)
    print('  -> Patched')
else:
    print('  -> Already patched or pattern not found')
"
fi

# -----------------------------------------------------------
# 4. Patch flags-ldflags.m4: wrap macosx-specific LDFLAGS in BUILDJDK check
# -----------------------------------------------------------
echo ">>> Patching flags-ldflags.m4..."
LDFLAGS_M4="make/autoconf/flags-ldflags.m4"
if [ -f "$LDFLAGS_M4" ]; then
  python3 -c "
with open('$LDFLAGS_M4', 'r') as f:
    content = f.read()
old = 'if test \"x\$OPENJDK_TARGET_OS\" = xmacosx && test \"x\$TOOLCHAIN_TYPE\" = xclang; then'
new = 'if test \"x\$OPENJDK_TARGET_OS\" = xmacosx && test \"x\$TOOLCHAIN_TYPE\" = xclang && test \"x\$JVM_BUILDJDK\" = xtrue; then'
if old in content:
    content = content.replace(old, new, 1)
    # Also comment out the OS_LDFLAGS with -mmacosx-version-min
    content = content.replace('OS_LDFLAGS=\"-mmacosx-version-min=', '# OS_LDFLAGS=\"-mmacosx-version-min=')
    with open('$LDFLAGS_M4', 'w') as f:
        f.write(content)
    print('  -> Patched')
else:
    print('  -> Already patched or pattern not found')
"
fi

# -----------------------------------------------------------
# 5. Patch flags-other.m4: wrap macosx ASFLAGS in BUILDJDK check
# -----------------------------------------------------------
echo ">>> Patching flags-other.m4..."
OTHER_M4="make/autoconf/flags-other.m4"
if [ -f "$OTHER_M4" ]; then
  python3 -c "
with open('$OTHER_M4', 'r') as f:
    content = f.read()
# Find and wrap the macosx ASFLAGS section
old = '''    JVM_BASIC_ASFLAGS=\"\$JVM_BASIC_ASFLAGS \\\\
        -DMAC_OS_X_VERSION_MIN_REQUIRED=\$MACOSX_VERSION_MIN_NODOTS \\\\
        -mmacosx-version-min=\$MACOSX_VERSION_MIN\"'''
new = '''    if test \"x\$JVM_BUILDJDK\" = xtrue; then
    JVM_BASIC_ASFLAGS=\"\$JVM_BASIC_ASFLAGS \\\\
        -DMAC_OS_X_VERSION_MIN_REQUIRED=\$MACOSX_VERSION_MIN_NODOTS \\\\
        -mmacosx-version-min=\$MACOSX_VERSION_MIN\"
    fi'''
if old in content:
    content = content.replace(old, new, 1)
    with open('$OTHER_M4', 'w') as f:
        f.write(content)
    print('  -> Patched')
else:
    print('  -> Already patched or pattern not found')
" 2>&1 || echo "  -> Warning: patch may not have applied cleanly"
fi

# -----------------------------------------------------------
# 6. Disable jdk.hotspot.agent (needs mach_exc.defs from macOS SDK)
# -----------------------------------------------------------
echo ">>> Disabling jdk.hotspot.agent module..."
# Override Gensrc.gmk to be empty — this module is not needed on iOS
mkdir -p make/modules/jdk.hotspot.agent
cat > make/modules/jdk.hotspot.agent/Gensrc.gmk << 'GENEOF'
# Disabled for iOS — mach_exc.defs not available in iOS SDK
GENEOF

cat > make/modules/jdk.hotspot.agent/Lib.gmk << 'LIBEOF'
# Disabled for iOS
LIBEOF

echo "  -> Disabled jdk.hotspot.agent (SA not available on iOS)"

# -----------------------------------------------------------
# 7. Add BundleAppearance.m/.h stubs (used by JavaNativeFoundation)
# -----------------------------------------------------------
echo ">>> Creating JavaNativeFoundation stubs..."
JNF_DIR="src/java.base/macosx/native/libjava"
mkdir -p "$JNF_DIR"
# These are referenced by the JavaNativeFoundation framework code on macOS
# but we need to stub them for iOS since there's no JNF framework
cat > "$JNF_DIR/JNFInfo.h" << 'JNFEOF'
#ifndef _JNF_INFO_H_
#define _JNF_INFO_H_
// Stub for iOS cross-compilation
#endif
JNFEOF

echo "  -> Created JNF stubs"

echo "=== Source tree fixes complete ==="
