#!/usr/bin/env bash
# Build the lol-on-linux payload from a pinned darling-lol checkout: the base
# runtime, the prebuilt per-user overlays and the launcher glue, as a single
# payload.tar.zst.
#
# The pipeline mirrors the upstream build/install flow but never compiles for
# the build host: host-CPU flags are normalized to x86-64, the overlays are
# staged into a throwaway prefix, and the X11 shim is rebuilt with final
# install paths, so nothing from the build machine leaks into the payload.
#
# CI usage (inside ubuntu:22.04, as root):
#   ci/build-payload.sh --out /work/out
# Local dry run against this machine's checkout:
#   ci/build-payload.sh --reuse ~/darling-lol --skip-build --out /tmp/out --version 0.local
set -euo pipefail

unset CDPATH
here=$(cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)

usage() {
  cat <<'EOF'
Usage: build-payload.sh --out DIR [options]

  --out DIR             output directory for payload.tar.zst (required)
  --work DIR            scratch directory (default: mktemp -d)
  --reuse DIR           use an existing darling-lol checkout instead of cloning
  --skip-build          skip scripts/build.sh (dry runs on an existing build tree only)
  --version VER         payload version (default: today as YYYY.MM.DD)
  --guest-user NAME     guest account name used during staging (default: loluser)
  --jobs N              parallel build jobs (default: nproc)
  --upstream-repo URL   darling-lol repository (default: upstream.lock)
  --upstream-commit SHA pin to build (default: upstream.lock)
EOF
}

out_dir=
work_dir=
reuse_dir=
skip_build=0
version=${LOL_VERSION:-$(date -u +%Y.%m.%d)}
guest_user=${LOL_GUEST_USER:-loluser}
jobs=${JOBS:-$(nproc)}
upstream_repo=
upstream_commit=

while [ $# -gt 0 ]; do
  case "$1" in
    --out) out_dir=${2:?--out needs a value}; shift 2 ;;
    --work) work_dir=${2:?--work needs a value}; shift 2 ;;
    --reuse) reuse_dir=${2:?--reuse needs a value}; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    --version) version=${2:?--version needs a value}; shift 2 ;;
    --guest-user) guest_user=${2:?--guest-user needs a value}; shift 2 ;;
    --jobs) jobs=${2:?--jobs needs a value}; shift 2 ;;
    --upstream-repo) upstream_repo=${2:?--upstream-repo needs a value}; shift 2 ;;
    --upstream-commit) upstream_commit=${2:?--upstream-commit needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "build-payload: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$out_dir" ] || { echo 'build-payload: --out is required' >&2; usage >&2; exit 2; }
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)
if [ -z "$work_dir" ]; then
  work_dir=$(mktemp -d)
fi
mkdir -p "$work_dir"
work_dir=$(cd "$work_dir" && pwd)

lock_file="$repo_root/upstream.lock"
lock_value() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$lock_file" "$1"
}
if [ -z "$upstream_repo" ]; then upstream_repo=$(lock_value repo); fi
if [ -z "$upstream_commit" ]; then upstream_commit=$(lock_value commit); fi
echo "build-payload: version $version, upstream $upstream_repo @ $upstream_commit"

stage="$work_dir/stage"
mkdir -p "$stage"

# ---- 1. darling-lol checkout -------------------------------------------------
if [ -n "$reuse_dir" ]; then
  src=$(cd "$reuse_dir" && pwd)
  echo "build-payload: reusing checkout $src"
else
  src="$work_dir/darling-lol"
  echo "build-payload: cloning $upstream_repo"
  git clone --quiet "$upstream_repo" "$src"
  git -C "$src" checkout --quiet "$upstream_commit"
  if command -v git-lfs >/dev/null 2>&1; then
    git lfs install --skip-repo >/dev/null 2>&1 || true
    ( cd "$src" && git lfs pull )
  else
    echo 'build-payload: warning: git-lfs is not installed' >&2
  fi
fi
[ -f "$src/scripts/build.sh" ] || { echo "build-payload: $src is not a darling-lol checkout" >&2; exit 1; }

# ---- 2. portable build flags -------------------------------------------------
if [ -n "$reuse_dir" ] && [ -z "${LOL_NORMALIZE_REUSE:-}" ]; then
  echo 'build-payload: reuse mode: skipping flag normalization (set LOL_NORMALIZE_REUSE=1 to force)'
else
  sh "$repo_root/ci/normalize-flags.sh" "$src"
fi

# ---- 3. build ----------------------------------------------------------------
if [ ! -d "$src/build/venv" ]; then
  echo 'build-payload: creating the python venv required by some upstream tools'
  ( cd "$src" && python3 -m venv build/venv && build/venv/bin/pip install -q -r requirements.txt ) ||
    echo 'build-payload: warning: venv setup failed; continuing' >&2
fi
if [ "$skip_build" = 1 ]; then
  echo 'build-payload: --skip-build given; using the existing build tree'
else
  echo "build-payload: building darling-lol (JOBS=$jobs); this is the long step"
  ( cd "$src" && JOBS="$jobs" ./scripts/build.sh )
fi

# ---- 4. base runtime: staged copy (payload) + real copy (needed to run darling)
echo 'build-payload: staging the base runtime (cmake --install DESTDIR)'
( cd "$src" && DESTDIR="$stage/base" cmake --install build/darling-src/build )
echo 'build-payload: installing the base runtime to /usr/local for staging runs'
if [ "$(id -u)" = 0 ]; then
  ( cd "$src" && cmake --install build/darling-src/build )
elif sudo -n true 2>/dev/null; then
  ( cd "$src" && sudo -n env PATH="$PATH" cmake --install build/darling-src/build )
else
  echo 'build-payload: warning: no passwordless sudo; assuming /usr/local already carries the runtime' >&2
fi

# ---- 5. render tools for the staging prefix ----------------------------------
echo "build-payload: rendering tools (prefix=$stage/prefix, guest=$guest_user)"
( cd "$src" && python3 scripts/configure.py --guest-user "$guest_user" --prefix "$stage/prefix" )
export DPREFIX="$stage/prefix"
export RIOT_GUEST_HOME="$DPREFIX/Users/$guest_user"

# ---- 6. initialize the staging prefix ----------------------------------------
# The prefix must NOT be pre-created: darling only bootstraps a prefix that does
# not exist yet, and a half-empty one breaks the shellspawn socket setup.
if [ ! -e "$DPREFIX" ]; then
  echo 'build-payload: initializing the staging prefix (bootstrap)'
  ( cd "$src" && darling shell /usr/bin/true )
fi
# The overlay installers create their own target directories, including the
# guest home for $guest_user, which is not the bootstrap home.
mkdir -p "$DPREFIX/private/tmp"
chmod 1777 "$DPREFIX/private/tmp"

snapshot() { ( cd "$DPREFIX" && find . \( -type f -o -type l \) | LC_ALL=C sort ); }
snapshot > "$stage/files.before"

# ---- 7. overlay installers (order mirrors upstream scripts/install-runtime.sh)
echo 'build-payload: building+installing the presentation runtime'
( cd "$src" && sh build/runtime/tools/install-riot-presentation-runtime.sh )
echo 'build-payload: building+installing the GPU runtime'
( cd "$src" && sh build/runtime/tools/install-riot-gpu-runtime.sh )
echo 'build-payload: building+installing the optimized libs runtime'
( cd "$src" && sh build/runtime/tools/build-riot-libs-runtime.sh )
( cd "$src" && python3 build/runtime/tools/install-riot-libs-runtime.py )
( cd "$src" && python3 build/runtime/tools/install-darling-system-profiler.py )
echo 'build-payload: validating the overlay set'
( cd "$src" && python3 build/runtime/tools/validate-riot-runtime.py ) ||
  echo 'build-payload: warning: validate-riot-runtime reported problems' >&2
( cd "$src" && python3 build/runtime/tools/stop-darling-runtime.py ) || true

# ---- 8. collect overlays by before/after diff --------------------------------
snapshot > "$stage/files.after"
LC_ALL=C comm -13 "$stage/files.before" "$stage/files.after" > "$stage/overlay.files"
echo "build-payload: $(wc -l < "$stage/overlay.files") overlay entries"

payload="$stage/payload"
rm -rf "$payload"
mkdir -p "$payload/usr/local/lib/lol-on-linux/overlay/prefix"
mkdir -p "$payload/usr/local/lib/lol-on-linux/overlay/home"

echo 'build-payload: assembling the payload base'
cp -a "$stage/base/usr/local/." "$payload/usr/local/"

echo 'build-payload: assembling the overlays'
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  rel=${entry#./}
  case "$rel" in
    *.before-*) continue ;;
  esac
  case "$rel" in
    "Users/$guest_user"/*) dest="overlay/home/${rel#"Users/$guest_user"/}" ;;
    *) dest="overlay/prefix/$rel" ;;
  esac
  mkdir -p "$payload/usr/local/lib/lol-on-linux/$(dirname "$dest")"
  cp -a "$DPREFIX/$rel" "$payload/usr/local/lib/lol-on-linux/$dest"
done < "$stage/overlay.files"

# ---- 9. rebuild the X11 shim with final install paths ------------------------
echo 'build-payload: rebuilding the X11 shim with final install paths'
shim_dir="$payload/usr/local/lib/lol-on-linux"
elfcalls="$src/build/darling-src/src/startup/mldr/elfcalls"
[ -d "$elfcalls" ] || { echo "build-payload: missing $elfcalls" >&2; exit 1; }
read -r -a x11_flags <<< "$(pkg-config --cflags --libs x11 x11-xcb xcb-shm xext)"
cc -shared -fPIC -O2 -Wall -Wextra \
  -Wl,-soname,libdarling-xshm.so \
  "$src/tools/m58f299-xshm.c" -o "$shim_dir/libdarling-xshm.so" \
  -pthread "${x11_flags[@]}"
clang -target x86_64-apple-macosx11.0 -fuse-ld=lld -dynamiclib -nostdlib -O2 \
  -isysroot /usr/local/libexec/darling \
  -I"$elfcalls" \
  '-DDARLING_XSHM_HOST_LIBRARY="/usr/local/lib/lol-on-linux/libdarling-xshm.so"' \
  -Wl,-undefined,dynamic_lookup -Wl,-install_name,libDarlingXShm.dylib \
  "$src/tools/m58f299-native-wrapper.c" -o "$shim_dir/libDarlingXShm.dylib"

# The presentation overlay bakes the staging guest home and the staging checkout
# path into its copy of the guest-side shim, and run-riot-client.sh loads that
# exact file from the guest home. Ship the rebuilt copy in its place.
overlay_shim="$payload/usr/local/lib/lol-on-linux/overlay/home/libDarlingXShm.dylib"
if [ -f "$overlay_shim" ]; then
  cp -f "$shim_dir/libDarlingXShm.dylib" "$overlay_shim"
fi

# ---- 10. launcher glue -------------------------------------------------------
echo 'build-payload: adding the launcher glue'
mkdir -p "$payload/usr/local/bin" \
  "$payload/usr/local/lib/lol-on-linux/scripts" \
  "$payload/usr/local/share/applications" \
  "$payload/usr/local/share/icons/hicolor/scalable/apps" \
  "$payload/usr/local/share/doc/lol-on-linux"
install -m 755 "$repo_root/runtime/lol-on-linux" "$payload/usr/local/bin/lol-on-linux"
install -m 755 "$repo_root/runtime/first-run.sh" "$payload/usr/local/lib/lol-on-linux/first-run.sh"
if [ -f "$repo_root/install-remote.sh" ]; then
  install -m 755 "$repo_root/install-remote.sh" "$payload/usr/local/lib/lol-on-linux/install-remote.sh"
fi
install -m 644 "$repo_root/share/lol-on-linux.desktop" "$payload/usr/local/share/applications/lol-on-linux.desktop"
install -m 644 "$repo_root/share/lol-on-linux.svg" "$payload/usr/local/share/icons/hicolor/scalable/apps/lol-on-linux.svg"
install -m 644 "$repo_root/README.md" "$payload/usr/local/share/doc/lol-on-linux/README.md"
install -m 644 "$repo_root/LICENSE" "$payload/usr/local/share/doc/lol-on-linux/LICENSE"
cp -a "$src/tools" "$payload/usr/local/lib/lol-on-linux/tools"
for f in common.py configure.py run.sh; do
  install -m 644 "$src/scripts/$f" "$payload/usr/local/lib/lol-on-linux/scripts/$f"
done

cat > "$payload/usr/local/lib/lol-on-linux/payload-info.json" <<EOF
{
  "version": "$version",
  "upstream": { "repo": "$upstream_repo", "commit": "$upstream_commit" },
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "arch": "x86_64"
}
EOF

# ---- 11. pack ----------------------------------------------------------------
echo 'build-payload: packing payload.tar.zst'
tar --zstd -C "$stage" -cf "$out_dir/payload.tar.zst" payload
( cd "$out_dir" && sha256sum payload.tar.zst > payload.tar.zst.sha256 )
echo "build-payload: done: $out_dir/payload.tar.zst ($(du -h "$out_dir/payload.tar.zst" | cut -f1))"
