#!/bin/sh
# lol-on-linux first-run: render the runtime tool templates for this user,
# install the prebuilt per-user runtime overlays into the Darling prefix, and
# create the desktop entry. Idempotent; re-runs when the payload version
# changes. Everything runs as the user; no compilation happens here.
# Usage: first-run.sh [--force]
set -eu

LIB=/usr/local/lib/lol-on-linux
MINI="${XDG_DATA_HOME:-$HOME/.local/share}/lol-on-linux"
DPREFIX="${DPREFIX:-$HOME/.darling}"
export DPREFIX
user=$(id -un)
guest_home="$DPREFIX/Users/$user"

[ -f "$LIB/payload-info.json" ] || {
  echo "first-run: $LIB does not look like a lol-on-linux payload (is the package installed?)" >&2
  exit 1
}
version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$LIB/payload-info.json" | head -n 1)
[ -n "$version" ] || version=unknown

force=${1:-}
render_marker="$MINI/.render-version"
payload_marker="$MINI/.payload-version"

# copy_entry: atomic copy with a one-time migration backup. Handles symlinks.
copy_entry() {
  src=$1
  dst=$2
  mkdir -p "$(dirname "$dst")"
  if [ -L "$src" ]; then
    rm -f "$dst"
    ln -s "$(readlink "$src")" "$dst"
    return 0
  fi
  if [ -e "$dst" ] && [ ! -e "$dst.before-lol-on-linux" ]; then
    cp -p "$dst" "$dst.before-lol-on-linux" 2>/dev/null || true
  fi
  rm -f "$dst.next-lol-on-linux"
  cp -p "$src" "$dst.next-lol-on-linux"
  mv -f "$dst.next-lol-on-linux" "$dst"
}

copy_tree() {
  # copy_tree <src-dir> <dst-dir> — recursive, symlink-aware, atomic per file.
  srcdir=$1
  dstdir=$2
  [ -d "$srcdir" ] || return 0
  find "$srcdir" \( -type f -o -type l \) -print | while IFS= read -r entry; do
    rel=${entry#"$srcdir"/}
    copy_entry "$entry" "$dstdir/$rel"
  done
}

# 1. render the tool templates for this user (plain text substitution)
current_render=''
[ -f "$render_marker" ] && current_render=$(cat "$render_marker")
if [ "$force" = --force ] || [ "$current_render" != "$version" ]; then
  echo "lol-on-linux: preparing runtime tools in $MINI"
  command -v python3 >/dev/null 2>&1 || { echo 'first-run: python3 is required' >&2; exit 1; }
  mkdir -p "$MINI/scripts" "$MINI/build"
  rm -rf "$MINI/tools.new" "$MINI/scripts.new"
  cp -a "$LIB/tools" "$MINI/tools.new"
  mkdir -p "$MINI/scripts.new"
  cp -a "$LIB/scripts/." "$MINI/scripts.new/"
  rm -rf "$MINI/tools" "$MINI/scripts"
  mv "$MINI/tools.new" "$MINI/tools"
  mv "$MINI/scripts.new" "$MINI/scripts"
  rm -f "$MINI/build/config.json"
  ( cd "$MINI/scripts" && python3 configure.py >/dev/null )
  printf '%s\n' "$version" > "$render_marker"
fi

# 2. install the prebuilt overlays into the prefix (no compilation)
current_payload=''
[ -f "$payload_marker" ] && current_payload=$(cat "$payload_marker")
if [ "$force" = --force ] || [ "$current_payload" != "$version" ]; then
  command -v darling >/dev/null 2>&1 || {
    echo 'first-run: the darling runtime is not in PATH; is the lol-on-linux package installed?' >&2
    exit 1
  }
  if [ ! -d "$guest_home" ]; then
    echo 'lol-on-linux: initializing the Darling prefix (first time, this can take a minute)'
    darling shell /usr/bin/true
  fi
  mkdir -p "$DPREFIX/private/tmp"
  chmod 1777 "$DPREFIX/private/tmp" 2>/dev/null || true
  echo "lol-on-linux: installing runtime overlays into $DPREFIX"
  copy_tree "$LIB/overlay/prefix" "$DPREFIX"
  copy_tree "$LIB/overlay/home" "$guest_home"
  printf '%s\n' "$version" > "$payload_marker"
fi

# 3. desktop entry and icon (reuses the upstream tool; non-fatal)
desktop_tool="$MINI/build/runtime/tools/riot-desktop-entry.py"
current_desktop=''
[ -f "$MINI/.desktop-version" ] && current_desktop=$(cat "$MINI/.desktop-version")
if [ -f "$desktop_tool" ] && { [ "$force" = --force ] || [ "$current_desktop" != "$version" ]; }; then
  if python3 "$desktop_tool" >/dev/null 2>&1; then
    printf '%s\n' "$version" > "$MINI/.desktop-version"
  else
    echo 'lol-on-linux: desktop entry creation failed (non-fatal)' >&2
  fi
fi

echo "lol-on-linux: ready ($version)"
