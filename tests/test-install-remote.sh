#!/bin/sh
# tests/test-install-remote.sh — stdlib-only POSIX sh tests for install-remote.sh.
# Everything is driven by the LOL_TEST_* hooks; nothing touches the real system.
# Run:  sh tests/test-install-remote.sh

# shellcheck disable=SC2034  # LOL_TEST_* vars are read by the sourced installer's hooks
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/install-remote.sh"
if [ ! -f "$SRC" ]; then
  echo "FATAL: cannot find install-remote.sh at $SRC" >&2
  exit 1
fi

PASSED=0
FAILED=0

pass() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED + 1)); }

assert_eq() { # NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected '$2', got '$3')"
  fi
}

assert_rc() { # NAME EXPECTED_RC ACTUAL_RC
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected rc=$2, got rc=$3)"
  fi
}

assert_contains() { # NAME NEEDLE HAYSTACK
  case $3 in
    *"$2"*) pass "$1" ;;
    *) fail "$1 (missing '$2' in: $3)" ;;
  esac
}

# ---------------------------------------------------------------- fixtures
TD=$(mktemp -d "${TMPDIR:-/tmp}/lol-on-linux-test.XXXXXX")
trap 'rm -rf "$TD"' EXIT INT TERM

# Write os-release fixtures explicitly (clearer than clever loops).
{
  echo 'NAME="Ubuntu 22.04 LTS"'
  echo 'ID=ubuntu'
  echo 'ID_LIKE=debian'
  echo 'VERSION_ID="22.04"'
} >"$TD/os-ubuntu22"

{
  echo 'NAME="Linux Mint 21.x"'
  echo 'ID=linuxmint'
  echo 'ID_LIKE="debian ubuntu"'
} >"$TD/os-linuxmint"

{
  echo 'NAME="Artix Linux"'
  echo 'ID=artix'
  echo 'ID_LIKE=arch'
} >"$TD/os-artix"

{
  echo 'NAME="CachyOS Linux"'
  echo 'ID=cachyos'
  echo 'ID_LIKE=arch'
} >"$TD/os-cachyos"

{
  echo 'NAME="Void Linux (glibc)"'
  echo 'ID=void'
  echo 'ID_LIKE='
} >"$TD/os-void"

{
  echo 'NAME="Void Linux (musl)"'
  echo 'ID=void-musl'
  echo 'ID_LIKE=void'
} >"$TD/os-voidmusl"

{
  echo 'NAME="Fedora Linux 42"'
  echo 'ID=fedora'
  echo 'ID_LIKE="fedora rhel"'
  echo 'VERSION_ID=42'
} >"$TD/os-fedora42"

{
  echo 'NAME="Nobara Linux 42"'
  echo 'ID=nobara'
  echo 'ID_LIKE="fedora"'
} >"$TD/os-nobara"

{
  echo 'NAME="Alpine Linux"'
  echo 'ID=alpine'
  echo 'ID_LIKE='
} >"$TD/os-alpine"

{
  echo 'NAME="Rocky Linux 9"'
  echo 'ID=rocky'
  echo 'ID_LIKE="rhel centos fedora"'
} >"$TD/os-rocky"

{
  echo 'NAME="slartibartfast OS"'
  echo 'ID=slartibartfast'
} >"$TD/os-unknown"

cat >"$TD/manifest.json" <<'EOF'
{
  "schema": 1,
  "version": "2026.10.18",
  "released": "2026-10-18T12:00:00Z",
  "upstream": { "repo": "https://github.com/lucannez64/darling-lol", "commit": "abc123" },
  "url_base": "https://example.invalid/releases/download/v2026.10.18/",
  "mirror_url": null,
  "assets": [
    { "id": "deb", "file": "lol-on-linux_2026.10.18_amd64.deb", "sha256": "a1b2c3d4", "size": 0, "glibc_required": "2.35", "families": ["debian", "ubuntu"], "manager": "apt" },
    { "id": "rpm", "file": "lol-on-linux-2026.10.18-1.x86_64.rpm", "sha256": "deadbeef", "size": 1234, "glibc_required": "2.36", "families": ["fedora"], "manager": "dnf" },
    { "id": "arch", "file": "lol-on-linux-2026.10.18-1-x86_64.pkg.tar.zst", "sha256": "0fedcba9", "size": 0, "glibc_required": "2.28", "families": ["arch"], "manager": "pacman" },
    { "id": "void", "file": "lol-on-linux_2026.10.18_1.x86_64.xbps", "sha256": "87654321", "size": 0, "glibc_required": "2.28", "families": ["void"], "manager": "xbps" }
  ]
}
EOF

# Minimal manifest WITHOUT valid spacing for the fallback parser being strict —
# same fixture works: the fallback normalizes whitespace away.

# ------------------------------------------------------------------ source
# Load installer functions only; nothing must run.
# shellcheck disable=SC1090
LOL_TEST_SOURCE_ONLY=1 . "$SRC"

family_of() { # OS-RELEASE-FIXTURE
  LOL_TEST_OS_RELEASE="$1" detect_family
}

asset_id_of() { # FAMILY GLIBC
  pick_asset "$TD/manifest.json" "$1" "$2" | cut -d'|' -f2
}

echo "---- family detection (positive) ----"
assert_eq "ubuntu 22.04 -> deb" "deb" "$(family_of "$TD/os-ubuntu22")"
assert_eq "linuxmint -> deb (via ID_LIKE)" "deb" "$(family_of "$TD/os-linuxmint")"
assert_eq "artix -> arch (via ID_LIKE)" "arch" "$(family_of "$TD/os-artix")"
assert_eq "cachyos -> arch" "arch" "$(family_of "$TD/os-cachyos")"
assert_eq "void -> void" "void" "$(family_of "$TD/os-void")"
assert_eq "fedora 42 -> rpm" "rpm" "$(family_of "$TD/os-fedora42")"
assert_eq "nobara -> rpm (via ID_LIKE)" "rpm" "$(family_of "$TD/os-nobara")"

echo "---- family rejection ----"
assert_eq "alpine -> unknown" "unknown" "$(family_of "$TD/os-alpine")"
assert_eq "unknown distro -> unknown" "unknown" "$(family_of "$TD/os-unknown")"
assert_eq "rocky -> rhel refusal label" "rhel" "$(family_of "$TD/os-rocky")"

LOL_TEST_OS_RELEASE="$TD/os-alpine"
check_supported_family "unknown" "alpine" >/dev/null 2>&1
assert_rc "alpine refuses with non-zero exit" "1" "$?"
unset LOL_TEST_OS_RELEASE

check_supported_family "unknown" "slartibartfast" >/dev/null 2>&1
assert_rc "unmapped distro refuses with non-zero exit" "1" "$?"

LOL_TEST_OS_RELEASE="$TD/os-rocky"
check_supported_family "rhel" "rocky" 2>"$TD/err.txt"
assert_rc "rocky refuses with non-zero exit" "1" "$?"
unset LOL_TEST_OS_RELEASE
assert_contains "rocky message mentions not supported" "not supported yet" "$(cat "$TD/err.txt")"

for _fl in deb rpm arch void; do
  check_supported_family "$_fl" "fixture" >/dev/null 2>&1
  assert_rc "family $_fl is accepted" "0" "$?"
done

echo "---- libc / kernel / arch ----"
LOL_TEST_GLIBC="2.35"
check_libc >/dev/null 2>&1
assert_rc "glibc 2.35 accepted" "0" "$?"
assert_eq "GLIBC_VER set to 2.35" "2.35" "$GLIBC_VER"
unset LOL_TEST_GLIBC

LOL_TEST_GLIBC="2.39"
check_libc >/dev/null 2>&1
assert_rc "glibc 2.39 accepted" "0" "$?"
unset LOL_TEST_GLIBC

LOL_TEST_MUSL=1
check_libc >/dev/null 2>&1
assert_rc "musl flag refuses" "1" "$?"
unset LOL_TEST_MUSL

LOL_TEST_MUSL=1 LOL_TEST_GLIBC="2.39"
check_libc >/dev/null 2>&1
assert_rc "musl flag refuses even with glibc hook set" "1" "$?"
unset LOL_TEST_MUSL LOL_TEST_GLIBC

LOL_TEST_KERNEL="5.10.2-arch1-1"
check_kernel >/dev/null 2>&1
assert_rc "kernel 5.10 refuses" "1" "$?"
unset LOL_TEST_KERNEL

LOL_TEST_KERNEL="5.14.0-1"
check_kernel >/dev/null 2>&1
assert_rc "kernel 5.14.0 accepted (edge)" "0" "$?"
unset LOL_TEST_KERNEL

LOL_TEST_KERNEL="5.13.9-1"
check_kernel >/dev/null 2>&1
assert_rc "kernel 5.13.9 refuses (edge)" "1" "$?"
unset LOL_TEST_KERNEL

LOL_TEST_ARCH="aarch64"
check_arch >/dev/null 2>&1
assert_rc "aarch64 refuses" "1" "$?"
unset LOL_TEST_ARCH

LOL_TEST_ARCH="x86_64"
check_arch >/dev/null 2>&1
assert_rc "x86_64 accepted" "0" "$?"
unset LOL_TEST_ARCH

echo "---- ver_ge sanity ----"
assert_rc "ver_ge 2.35 2.35" "0" "$(ver_ge 2.35 2.35 && printf 0 || printf 1)"
assert_rc "ver_ge 2.39 2.41" "1" "$(ver_ge 2.39 2.41 && printf 0 || printf 1)"
assert_rc "ver_ge 7.2.9 5.14" "0" "$(ver_ge 7.2.9 5.14 && printf 0 || printf 1)"
assert_rc "ver_ge 5.9 5.10" "1" "$(ver_ge 5.9 5.10 && printf 0 || printf 1)"
assert_rc "ver_ge 2 2.35" "1" "$(ver_ge 2 2.35 && printf 0 || printf 1)"
assert_rc "ver_ge 2.35 2" "0" "$(ver_ge 2.35 2 && printf 0 || printf 1)"

echo "---- pick_asset (python3 path) ----"
assert_eq "pick deb for glibc 2.35" "deb" "$(asset_id_of deb 2.35)"
assert_eq "pick deb for glibc 2.39" "deb" "$(asset_id_of deb 2.39)"
assert_eq "pick rpm for glibc 2.39" "rpm" "$(asset_id_of rpm 2.39)"
assert_eq "pick arch for glibc 2.28" "arch" "$(asset_id_of arch 2.28)"
assert_eq "pick void for glibc 2.28" "void" "$(asset_id_of void 2.28)"

pick_asset "$TD/manifest.json" deb 2.31 >/dev/null 2>&1
assert_rc "pick_asset refuses glibc 2.31 vs 2.35 asset" "1" "$?"

pick_asset "$TD/manifest.json" rpm 2.35 >/dev/null 2>&1
assert_rc "pick_asset refuses rpm (needs 2.36) on glibc 2.35" "1" "$?"

_pa_line=$(pick_asset "$TD/manifest.json" deb 2.39)
assert_contains "asset line carries the file name" "lol-on-linux_2026.10.18_amd64.deb" "$_pa_line"
assert_contains "asset line carries the manager" "apt" "$_pa_line"
assert_contains "asset line carries url_base+file" "https://example.invalid/releases/download/v2026.10.18/lol-on-linux_2026.10.18_amd64.deb" "$_pa_line"

echo "---- pick_asset (grep fallback path) ----"
assert_eq "fallback: deb for 2.39" "deb" "$(LOL_TEST_NO_PYTHON=1 pick_asset "$TD/manifest.json" deb 2.39 | cut -d'|' -f2)"
assert_eq "fallback: arch for 2.28" "arch" "$(LOL_TEST_NO_PYTHON=1 pick_asset "$TD/manifest.json" arch 2.28 | cut -d'|' -f2)"
LOL_TEST_NO_PYTHON=1 pick_asset "$TD/manifest.json" deb 2.31 >/dev/null 2>&1
assert_rc "fallback: refuses glibc 2.31 vs 2.35 asset" "1" "$?"

echo "---- summary ----"
printf 'Tests: %d passed, %d failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
