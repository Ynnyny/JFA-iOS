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

# Create a compat sys/mman.h that ensures PROT_READ/PROT_WRITE/PROT_EXEC are defined
# This is needed because the iOS SDK's <sys/mman.h> may not define them in the
# same way as macOS, and some JDK code (even BUILDJDK) relies on them.
cat > ios-override/include/sys/mman.h << 'MMANEOF'
#ifndef _IOS_OVERRIDE_SYS_MMAN_H
#define _IOS_OVERRIDE_SYS_MMAN_H
/* Full stub: iOS SDK has no sys/mman.h, provide POSIX constants */
#include <sys/types.h>
#include <TargetConditionals.h>
#define PROT_READ       0x01
#define PROT_WRITE      0x02
#define PROT_EXEC       0x04
#define PROT_NONE       0x00
#define MAP_FILE        0x0000
#define MAP_SHARED      0x0001
#define MAP_PRIVATE     0x0002
#define MAP_FIXED       0x0010
#define MAP_ANON        0x1000
#define MAP_ANONYMOUS   MAP_ANON
#define MAP_FAILED      ((void *)-1)
#include <stdint.h>
static inline void *mmap(void *addr, size_t len, int prot, int flags, int fd, size_t off) {
    return MAP_FAILED;
}
static inline int munmap(void *addr, size_t len) { return -1; }
static inline int mprotect(void *addr, size_t len, int prot) { return -1; }
static inline int msync(void *addr, size_t len, int flags) { return -1; }
static inline int mlock(const void *addr, size_t len) { return -1; }
static inline int munlock(const void *addr, size_t len) { return -1; }
static inline int madvise(void *addr, size_t len, int advice) { return -1; }
static inline int shm_open(const char *name, int oflag, mode_t mode) { return -1; }
static inline int shm_unlink(const char *name) { return -1; }
#endif
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
#    Apple clang masquerading as GCC (TOOLCHAIN_TYPE=gcc) gets
#    -Wl,-soname which macOS ld doesn't support. Add a check for
#    BUILD_OS=macosx to use -install_name instead.
# -----------------------------------------------------------
echo ">>> Fixing BUILDJDK linker flags for macOS host..."
CFLAGS_M4="make/autoconf/flags-cflags.m4"
if [ -f "$CFLAGS_M4" ]; then
  # Replace SET_SHARED_LIBRARY_NAME in the gcc section to handle macOS
  python3 << 'PYEOF'
import sys
with open('make/autoconf/flags-cflags.m4', 'r') as f:
    content = f.read()

# Replace the gcc branch's soname line with a macOS-aware version
# Looking for: SET_SHARED_LIBRARY_NAME='-Wl,-soname=[$]1'
# in the gcc section (first occurrence)
old_line = "SET_SHARED_LIBRARY_NAME='-Wl,-soname=[$]1'"
new_block = '''if test "x$OPENJDK_BUILD_OS" = xmacosx; then
    SET_SHARED_LIBRARY_NAME='-Wl,-install_name,@rpath/[$]1'
  else
    SET_SHARED_LIBRARY_NAME='-Wl,-soname=[$]1'
  fi'''

# Only replace the first occurrence (gcc section, not clang else)
count = content.count(old_line)
if count > 0:
    # Replace only first occurrence
    content = content.replace(old_line, new_block, 1)
    with open('make/autoconf/flags-cflags.m4', 'w') as f:
        f.write(content)
    print(f'  -> Fixed gcc branch ({count} total, 1 replaced)')
else:
    print('  -> -soname line not found, trying simpler pattern')
    # Try with different escaping
    old_line2 = "SET_SHARED_LIBRARY_NAME='-Wl,-soname=[\$]1'"
    if old_line2 in content:
        content = content.replace(old_line2, new_block, 1)
        with open('make/autoconf/flags-cflags.m4', 'w') as f:
            f.write(content)
        print('  -> Fixed gcc branch (alt pattern)')
    else:
        print('  -> No -soname found')
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
