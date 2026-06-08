#!/bin/bash
# patch_platform_m4.sh — adds iOS support to JDK 25's platform.m4
# This makes configure recognize aarch64-apple-ios as a valid target.

M4_FILE="$1"
if [ ! -f "$M4_FILE" ]; then
  echo "Usage: $0 <path_to_platform.m4>"
  exit 1
fi

# Check if already patched
if grep -q "\\*ios\\*)" "$M4_FILE" 2>/dev/null; then
  echo "platform.m4 already patched for iOS"
  exit 0
fi

# Add iOS case before the error case
sed -i '' 's/    \*)/    \*ios\*)\
      VAR_OS=macosx\
      VAR_OS_TYPE=unix\
      ;;\
    &/' "$M4_FILE"

echo "Patched $M4_FILE with iOS support"
