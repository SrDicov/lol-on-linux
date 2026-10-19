#!/usr/bin/env bash
# Smoke test: install the built package inside a clean container image and
# verify the runtime comes up headless. Run inside the matching distro image
# as root (the CI matrix does exactly that):
#
#   ci/smoke-test.sh --format deb  --package /work/dist/lol-on-linux_..._amd64.deb
#   ci/smoke-test.sh --format rpm  --package /work/dist/lol-on-linux-...rpm
#   ci/smoke-test.sh --format arch --package /work/dist/....pkg.tar.zst
#   ci/smoke-test.sh --format void --package /work/dist/....xbps
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: smoke-test.sh --format <deb|rpm|arch|void> --package <file>
EOF
}

format=
package=
while [ $# -gt 0 ]; do
  case "$1" in
    --format) format=${2:?--format needs a value}; shift 2 ;;
    --package) package=${2:?--package needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "smoke-test: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [ -z "$format" ] || [ -z "$package" ]; then
  usage >&2
  exit 2
fi
[ -f "$package" ] || { echo "smoke-test: package not found: $package" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "smoke-test: installing $format package: $package"
case "$format" in
  deb)
    apt-get update -qq
    apt-get install -y -qq "$package"
    ;;
  rpm)
    dnf install -y "$package"
    ;;
  arch)
    pacman -Syu --noconfirm
    pacman -U --noconfirm "$package"
    ;;
  void)
    xbps-install -S -y
    repo=$(mktemp -d)
    cp "$package" "$repo/"
    ( cd "$repo" && xbps-rindex -a ./*.xbps )
    xbps-install -y --repository="$repo" lol-on-linux
    rm -rf "$repo"
    ;;
  *)
    echo "smoke-test: unknown format: $format" >&2
    exit 2
    ;;
esac

echo 'smoke-test: package installed; checking the system ties'
[ -x /usr/local/bin/lol-on-linux ] || { echo 'smoke-test: CLI missing' >&2; exit 1; }
[ -f /usr/local/share/applications/lol-on-linux.desktop ] || { echo 'smoke-test: desktop entry missing' >&2; exit 1; }
[ -d /usr/local/libexec/darling ] || { echo 'smoke-test: base runtime missing' >&2; exit 1; }
[ -u /usr/local/bin/darling ] || { echo 'smoke-test: darling is not setuid root (packages must preserve it)' >&2; exit 1; }
/usr/local/bin/lol-on-linux --version

# iridium dlopen()s the bundled libLLVM by name; the packages run ldconfig so
# the loader cache has it, and every library it links against must exist here.
llvm_lib=$(sed -n 's/.*"library"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  /usr/local/lib/lol-on-linux/payload-info.json | head -n 1)
[ -n "$llvm_lib" ] || { echo 'smoke-test: payload-info.json has no LLVM library' >&2; exit 1; }
llvm_path="/usr/local/lib/lol-on-linux/llvm/$llvm_lib"
[ -f "$llvm_path" ] || { echo "smoke-test: bundled libLLVM is missing: $llvm_path" >&2; exit 1; }
if ldd "$llvm_path" 2>&1 | grep -q 'not found'; then
  echo "smoke-test: the bundled libLLVM has unresolved libraries:" >&2
  ldd "$llvm_path" | grep 'not found' >&2
  exit 1
fi
ldconfig -p | grep -q "/lol-on-linux/llvm/$llvm_lib" || {
  echo "smoke-test: ldconfig does not know the bundled libLLVM ($llvm_lib); the post-install hook did not run" >&2
  exit 1
}
python3 -c "import ctypes, sys; ctypes.CDLL('$llvm_lib')" || {
  echo "smoke-test: dlopen() of the bundled $llvm_lib failed" >&2
  exit 1
}
echo "smoke-test: bundled libLLVM loads by name ($llvm_lib)"

echo 'smoke-test: verifying the runtime as a normal user (fresh HOME)'
id -u loluser >/dev/null 2>&1 || useradd -m -s /bin/bash loluser
if [ -e /.dockerenv ] || [ -e /run/.containerenv ]; then
  # Containers put the root filesystem on overlayfs, which cannot host the
  # overlay mount Darling creates at the prefix: give the test user a tmpfs
  # home instead (needs the container to run with --privileged).
  mount -t tmpfs -o size=6g,mode=0755 tmpfs /home/loluser
  chown loluser:loluser /home/loluser
fi
if command -v runuser >/dev/null 2>&1; then
  runuser -l loluser -c '/usr/local/bin/lol-on-linux --verify'
else
  su -l loluser -c '/usr/local/bin/lol-on-linux --verify'
fi

echo 'smoke-test: PASS'
