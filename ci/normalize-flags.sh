#!/bin/sh
# Replace host-CPU-specific build flags in a darling-lol checkout with the
# portable x86-64-v2 baseline used by lol-on-linux release builds. The upstream
# scripts hardcode -march=native, which would produce runner-CPU-only binaries.
# The baseline must not be plain x86-64: without cmpxchg16b (x86-64-v2, i.e.
# anything newer than 2009) clang turns 16-byte atomics into calls to
# ___atomic_*_16, which no library in the build provides and the link fails.
# Usage: normalize-flags.sh <darling-lol-checkout>
set -eu
dir=${1:?usage: normalize-flags.sh <darling-lol-checkout>}
if [ ! -d "$dir/scripts" ] || [ ! -d "$dir/tools" ]; then
  echo "normalize-flags: not a darling-lol checkout: $dir" >&2
  exit 1
fi
[ -n "${LOL_SKIP_NORMALIZE:-}" ] && { echo 'normalize-flags: skipped (LOL_SKIP_NORMALIZE)'; exit 0; }

files=$(grep -rIl -- '-march=native' "$dir/scripts" "$dir/tools" || true)
if [ -z "$files" ]; then
  echo 'normalize-flags: nothing to do'
  exit 0
fi
count=$(printf '%s\n' "$files" | wc -l)
printf '%s\n' "$files" | while IFS= read -r f; do
  sed -i 's/-march=native/-march=x86-64-v2/g' "$f"
done
left=$(grep -rIl -- '-march=native' "$dir/scripts" "$dir/tools" | wc -l)
if [ "$left" != 0 ]; then
  echo "normalize-flags: $left files still contain -march=native" >&2
  exit 1
fi
echo "normalize-flags: $count files normalized to -march=x86-64-v2"
