#!/bin/sh
# Give the darling-lol darlingserver build the PROCMAP_QUERY uapi when the
# build host's kernel headers are older than Linux 6.11 (Ubuntu 22.04 ships
# 5.15 and the payload job runs there). The patch uses the ioctl for O(log n)
# VMA lookups and falls back to parsing /proc/<pid>/maps text when the running
# kernel rejects it (ENOTTY/EINVAL), so old kernels still work; only the
# headers are the problem.
#
# The block goes in at the top of process.cpp, above the first hunk of
# patches/darlingserver.patch, because prepare.py re-checks each patch with
# `git apply --reverse --check` on every run: an edit inside a hunk's context
# would make it look like someone hand-edited the checkout and abort the build.
# The block includes what it needs and is guarded by #ifndef PROCMAP_QUERY, so
# it is a no-op on hosts whose headers already have the ioctl.
# Usage: patch-old-kernel-headers.sh <darling-lol-checkout>
set -eu
dir=${1:?usage: patch-old-kernel-headers.sh <darling-lol-checkout>}
src="$dir/src/external/darlingserver/src/process.cpp"
[ -f "$src" ] || { echo "patch-old-kernel-headers: no such file: $src" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/block" <<'EOF'
#include <sys/ioctl.h>
#include <linux/fs.h>
#ifndef PROCMAP_QUERY
/* Linux < 6.11 headers lack the /proc/<pid>/maps ioctl; same uapi as linux/fs.h. */
struct procmap_query {
	__u64 size;
	__u64 query_flags;
	__u64 query_addr;
	__u64 vma_start;
	__u64 vma_end;
	__u64 vma_flags;
	__u64 vma_page_size;
	__u64 vma_offset;
	__u64 inode;
	__u32 dev_major;
	__u32 dev_minor;
	__u32 vma_name_size;
	__u32 build_id_size;
	__u64 vma_name_addr;
	__u64 build_id_addr;
};
#define PROCMAP_QUERY _IOWR('f', 17, struct procmap_query)
#define PROCMAP_QUERY_VMA_READABLE 0x01
#define PROCMAP_QUERY_VMA_WRITABLE 0x02
#define PROCMAP_QUERY_VMA_EXECUTABLE 0x04
#define PROCMAP_QUERY_VMA_SHARED 0x08
#define PROCMAP_QUERY_COVERING_OR_NEXT_VMA 0x10
#define PROCMAP_QUERY_FILE_BACKED_VMA 0x20
#endif
EOF

# Self-check: the struct size and ioctl number must be the ones the patch
# itself assumes (see the 104-byte comment in libsystem_kernel mach_traps.c).
{
  cat "$work/block"
  printf '%s\n' \
    '_Static_assert(sizeof(struct procmap_query) == 104, "procmap_query size");' \
    '_Static_assert(PROCMAP_QUERY == 0xC0686611ul, "PROCMAP_QUERY ioctl number");' \
    '_Static_assert(PROCMAP_QUERY_VMA_SHARED == 0x08, "VMA flag values");'
} > "$work/abi.c"
if ! ${CC:-cc} -fsyntax-only "$work/abi.c" 2>"$work/abi.err"; then
  echo 'patch-old-kernel-headers: vendored uapi does not match the ABI the patch expects' >&2
  cat "$work/abi.err" >&2
  exit 1
fi

if grep -q '^ *#ifndef PROCMAP_QUERY' "$src"; then
  echo 'patch-old-kernel-headers: already present, nothing to do'
  exit 0
fi

anchor='#include <darlingserver/process.hpp>'
anchor_line=$(grep -n "^#include <darlingserver/process\.hpp>$" "$src" | head -n 1 | cut -d: -f 1)
if [ -z "$anchor_line" ]; then
  echo "patch-old-kernel-headers: cannot find '$anchor' in $src" >&2
  echo 'patch-old-kernel-headers: upstream changed the code; re-check the PROCMAP_QUERY fallback' >&2
  exit 1
fi

# The insertion must stay above the patch's first process.cpp hunk (see header).
patch_file=$dir/build/applied-patches/darlingserver.patch
[ -f "$patch_file" ] || patch_file=$dir/patches/darlingserver.patch
if [ -f "$patch_file" ]; then
  first_hunk=$(awk '/^diff --git/ { mine = ($0 ~ /process\.cpp$/) } mine && /^@@ -/ { sub(/^@@ -/, ""); split($0, a, /[, ]/); print a[1]; exit }' "$patch_file")
  if [ -n "$first_hunk" ] && [ "$anchor_line" -ge "$first_hunk" ]; then
    echo "patch-old-kernel-headers: would insert into the darlingserver patch's hunks" >&2
    echo "patch-old-kernel-headers: anchor is at line $anchor_line, first hunk at line $first_hunk; prepare.py would reject the checkout" >&2
    exit 1
  fi
fi

awk -v block="$work/block" -v anchor="$anchor" '
  !done && $0 == anchor {
    while ((getline line < block) > 0) print line
    done = 1
  }
  { print }
' "$src" > "$work/patched"
grep -q 'PROCMAP_QUERY_VMA_READABLE' "$work/patched" ||
  { echo "patch-old-kernel-headers: insertion into $src failed" >&2; exit 1; }
cat "$work/patched" > "$src"
echo "patch-old-kernel-headers: PROCMAP_QUERY compat definitions added at line $anchor_line"
