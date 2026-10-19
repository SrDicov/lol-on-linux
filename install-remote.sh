#!/bin/sh
# install-remote.sh — one-shot remote installer for lol-on-linux.
# Runs as:  curl -fsSL https://raw.githubusercontent.com/SrDicov/lol-on-linux/main/install-remote.sh | sh
# Plain POSIX sh (dash-compatible); never references repo-relative files.
#
# Test hooks (read at call time; used by tests/test-install-remote.sh):
#   LOL_TEST_SOURCE_ONLY=1   source mode: define functions only, run nothing
#   LOL_TEST_OS_RELEASE      path to a substitute /etc/os-release
#   LOL_TEST_KERNEL          pretend uname -r reports this (e.g. 5.10.0)
#   LOL_TEST_ARCH            pretend uname -m reports this
#   LOL_TEST_GLIBC           pretend the local glibc version is this (e.g. 2.35)
#   LOL_TEST_MUSL=1          pretend libc is musl (unsupported)
#   LOL_TEST_MANIFEST        path to a local manifest.json (skips download)
#   LOL_TEST_NO_PYTHON=1     force the grep/sed fallback manifest parser
#   LOL_TEST_NO_SUDO=1       pretend passwordless sudo validation succeeded
# Internal API under test: ver_ge, detect_family, check_supported_family,
#   check_arch, check_kernel, check_libc, pick_asset.

LOL_REPO="${LOL_REPO:-SrDicov/lol-on-linux}"
LOL_MANIFEST_URL="${LOL_MANIFEST_URL:-https://github.com/$LOL_REPO/releases/latest/download/manifest.json}"
LOL_VERSION="1.0.0"
LOL_KERNEL_MIN="5.14"
LOL_LAUNCHER="/usr/local/bin/lol-on-linux"
LOL_DISK_MIN_KB=$((10 * 1024 * 1024)) # free-space soft warning: 10 GB
LOGFILE="${TMPDIR:-/tmp}/lol-on-linux-install.log"

# --------------------------------------------------------------- globals
OPT_YES=0
OPT_CHECK=0
OPT_DRY=0
OPT_NO_DRIVERS=0
OS_ID=""
OS_ID_LIKE=""
OS_FAMILY=""
GLIBC_VER=""
SESSION_TYPE=unknown
GPU_VENDOR=none
TARGET_USER=""
TARGET_HOME=""
TEMPDIR=""
MANIFEST_PATH=""
REL_VERSION=""
ASSET_ID=""
ASSET_FILE=""
ASSET_PATH=""
ASSET_SHA=""
ASSET_SIZE=""
ASSET_MGR=""
ASSET_URL=""

# --------------------------------------------------------------- logging
log() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$LOGFILE" 2>/dev/null || :
}
log_w() {
  printf 'WARNING: %s\n' "$*" >&2
  printf 'WARNING: %s\n' "$*" >>"$LOGFILE" 2>/dev/null || :
}
log_err() {
  printf 'ERROR: %s\n' "$*" >&2
  printf 'ERROR: %s\n' "$*" >>"$LOGFILE" 2>/dev/null || :
}
die() {
  log_err "$*"
  exit 1
}
phase() {
  log ""
  log "==> $*"
}

# ------------------------------------------------------------ comparisons
# ver_ge A B : returns 0 when A >= B (numeric, dot-separated components).
ver_ge() {
  _vg_a=$1
  _vg_b=$2
  while :; do
    if [ -n "$_vg_a" ]; then _vg_ca=${_vg_a%%.*}; else _vg_ca=0; fi
    if [ -n "$_vg_b" ]; then _vg_cb=${_vg_b%%.*}; else _vg_cb=0; fi
    if [ "$_vg_ca" -gt "$_vg_cb" ] 2>/dev/null; then return 0; fi
    if [ "$_vg_ca" -lt "$_vg_cb" ] 2>/dev/null; then return 1; fi
    case $_vg_a in *.*) _vg_a=${_vg_a#*.} ;; *) _vg_a="" ;; esac
    case $_vg_b in *.*) _vg_b=${_vg_b#*.} ;; *) _vg_b="" ;; esac
    if [ -z "$_vg_a" ] && [ -z "$_vg_b" ]; then return 0; fi
  done
}

# ------------------------------------------------------------ environment
_or_unquote() {
  _ou_v=$1
  _ou_v=${_ou_v#\"}
  _ou_v=${_ou_v%\"}
  _ou_v=${_ou_v#\'}
  _ou_v=${_ou_v%\'}
  printf '%s\n' "$_ou_v"
}

load_os_release() {
  OS_ID=""
  OS_ID_LIKE=""
  _lo_f=${LOL_TEST_OS_RELEASE:-/etc/os-release}
  if [ ! -f "$_lo_f" ]; then
    log_err "Cannot read os-release info (expected at $_lo_f)."
    return 1
  fi
  while IFS= read -r _lo_l || [ -n "$_lo_l" ]; do
    _lo_k=${_lo_l%%=*}
    case $_lo_k in
      ID) OS_ID=$(_or_unquote "${_lo_l#ID=}") ;;
      ID_LIKE) OS_ID_LIKE=$(_or_unquote "${_lo_l#ID_LIKE=}") ;;
    esac
  done <"$_lo_f"
  [ -n "$OS_ID" ] || return 1
}

# Map one distro id token to a supported family label: deb|rpm|arch|void.
_map_family() {
  case $1 in
    debian | ubuntu | linuxmint | pop | zorin | elementary | neon) printf deb ;;
    fedora | nobara | bazzite | silverblue | bluefin | ultramarine | aurora) printf rpm ;;
    arch | manjaro | endeavouros | artix | cachyos | garuda | arcolinux) printf arch ;;
    void) printf void ;;
    *) printf unknown ;;
  esac
}

# detect_family: prints the supported family label for the current (or
# LOL_TEST_OS_RELEASE) distribution: deb|rpm|arch|void, "rhel" when the
# id/id_like contains RHEL/centos (explicit refusal), or "unknown".
detect_family() {
  if ! load_os_release; then
    printf 'unknown\n'
    return 0
  fi
  _de_m=$(_map_family "$OS_ID")
  if [ "$_de_m" != "unknown" ]; then
    printf '%s\n' "$_de_m"
    return 0
  fi
  for _de_t in $OS_ID_LIKE; do
    case $_de_t in
      rhel | centos) printf 'rhel\n'; return 0 ;;
    esac
    _de_m=$(_map_family "$_de_t")
    if [ "$_de_m" != "unknown" ]; then
      printf '%s\n' "$_de_m"
      return 0
    fi
  done
  printf 'unknown\n'
}

# check_supported_family LABEL [OS_ID] : non-zero for unsupported families.
check_supported_family() {
  case $1 in
    deb | rpm | arch | void) return 0 ;;
    rhel)
      log_err "RHEL/CentOS-family distribution (ID: ${2:-unknown}) is not supported yet."
      log_err "The release build targets glibc >= 2.35; RHEL clones ship an older glibc."
      return 1
      ;;
    *)
      log_err "Unsupported Linux distribution (ID: ${2:-unknown})."
      log_err "Supported: Debian/Ubuntu, Fedora, Arch, Void (glibc). Derivatives resolve via ID_LIKE."
      return 1
      ;;
  esac
}

check_arch() {
  _ar_a=${LOL_TEST_ARCH:-$(uname -m)}
  if [ "$_ar_a" != "x86_64" ]; then
    log_err "Unsupported architecture '$_ar_a': an x86_64 (AMD64) Linux system is required."
    return 1
  fi
}

check_kernel() {
  _ke_r=${LOL_TEST_KERNEL:-$(uname -r 2>/dev/null || printf '')}
  if [ -z "$_ke_r" ]; then
    log_err "Cannot read the kernel version (uname -r)."
    return 1
  fi
  _ke_v=${_ke_r%%-*}
  if ! ver_ge "$_ke_v" "$LOL_KERNEL_MIN"; then
    log_err "Kernel >= $LOL_KERNEL_MIN is required (found $_ke_r)."
    log_err "Please update your kernel first; older kernels lack features Darling needs."
    return 1
  fi
}

check_libc() {
  GLIBC_VER=""
  _li_g=${LOL_TEST_GLIBC:-}
  _li_musl=0
  if [ "${LOL_TEST_MUSL:-0}" = "1" ]; then
    _li_musl=1
  else
    if [ -z "$_li_g" ]; then
      _li_getconf=$(getconf GNU_LIBC_VERSION 2>/dev/null || printf '')
      case $_li_getconf in
        glibc*) _li_g=${_li_getconf#glibc } ;;
      esac
    fi
    if [ -z "$_li_g" ]; then
      ldd --version 2>&1 | grep -qi musl 2>/dev/null && _li_musl=1
      if [ "$_li_musl" = "0" ]; then
        if [ -n "$(find /lib -maxdepth 1 -name 'ld-musl*' 2>/dev/null | head -n 1)" ]; then
          _li_musl=1
        fi
      fi
    fi
  fi
  if [ "$_li_musl" = "1" ]; then
    log_err "musl libc detected: this project requires glibc."
    log_err "Void users: install/reinstall the *glibc* Void variant; Alpine is not supported."
    return 1
  fi
  if [ -z "$_li_g" ]; then
    log_err "Cannot determine the libc version; glibc is required (the runtime needs it)."
    return 1
  fi
  GLIBC_VER=$_li_g
}

# pick_asset MANIFEST FAMILY_LABEL LOCAL_GLIBC
# Prints one line:  ASSET|id|file|sha256|size|manager|url
# Non-zero if no asset matches the family/glibc requirement.
pick_asset() {
  _pi_m=$1
  _pi_fam=$2
  _pi_glibc=$3
  case $_pi_fam in
    deb) _pi_toks="debian ubuntu" ;;
    rpm) _pi_toks="fedora" ;;
    arch) _pi_toks="arch" ;;
    void) _pi_toks="void" ;;
    *)
      log_err "pick_asset: unknown family label '$_pi_fam'."
      return 1
      ;;
  esac
  if command -v python3 >/dev/null 2>&1 && [ "${LOL_TEST_NO_PYTHON:-0}" != "1" ]; then
    _pi_out=$(_pick_asset_py "$_pi_m" "$_pi_toks" "$_pi_glibc")
    if [ -n "$_pi_out" ]; then
      printf '%s\n' "$_pi_out"
      return 0
    fi
    return 1
  fi
  log_w "python3 is not available; using a best-effort fallback manifest parser."
  _pick_asset_fallback "$_pi_m" "$_pi_toks" "$_pi_glibc"
}

_pick_asset_py() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys

path, tokens, glc = sys.argv[1], sys.argv[2].split(), sys.argv[3]


def ver(s):
    try:
        return tuple(int(x) for x in str(s).split("."))
    except Exception:
        return (0,)


try:
    with open(path, "r", encoding="utf-8") as fh:
        manif = json.load(fh)
except OSError as exc:
    sys.stderr.write("Cannot read manifest %s: %s\n" % (path, exc))
    sys.exit(2)
except ValueError as exc:
    sys.stderr.write("Malformed manifest JSON: %s\n" % exc)
    sys.exit(2)

base = manif.get("url_base") or ""
for asset in manif.get("assets") or []:
    fams = asset.get("families") or []
    if not any(tok in fams for tok in tokens):
        continue
    if ver(asset.get("glibc_required") or "0") > ver(glc):
        continue
    url = asset.get("url") or (base + (asset.get("file") or ""))
    print(
        "ASSET|%s|%s|%s|%s|%s|%s"
        % (
            asset.get("id", ""),
            asset.get("file", ""),
            asset.get("sha256", ""),
            asset.get("size", ""),
            asset.get("manager", ""),
            url,
        )
    )
    sys.exit(0)

sys.stderr.write("No matching asset. Offered assets:\n")
for asset in manif.get("assets") or []:
    sys.stderr.write(
        "  id=%s families=%s glibc_required=%s file=%s\n"
        % (
            asset.get("id"),
            ",".join(asset.get("families") or []),
            asset.get("glibc_required", "-"),
            asset.get("file"),
        )
    )
sys.exit(1)
PYEOF
}

_pick_asset_fallback() {
  # Best-effort parser for canonical one-line asset entries (no python3).
  _pf_m=$1
  _pf_toks=$2
  _pf_glc=$3
  _pf_base=""
  while IFS= read -r _pf_l || [ -n "$_pf_l" ]; do
    case $_pf_l in
      *'"url_base"'*)
        _pf_base=$(printf '%s\n' "$_pf_l" | sed -n 's/.*"url_base"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        ;;
    esac
  done <"$_pf_m"

  while IFS= read -r _pf_l || [ -n "$_pf_l" ]; do
    case $_pf_l in *'"file"'*) ;; *) continue ;; esac
    _pf_n=$(printf '%s\n' "$_pf_l" | tr -d ' \t')
    _pf_hit=0
    for _pf_t in $_pf_toks; do
      case $_pf_n in *"\"${_pf_t}\""*) _pf_hit=1 ;; esac
    done
    [ "$_pf_hit" = "1" ] || continue
    _pf_req=$(printf '%s\n' "$_pf_n" | sed -n 's/.*"glibc_required":"\([^"]*\)".*/\1/p')
    if ! ver_ge "${_pf_glc:-0}" "${_pf_req:-0}"; then
      continue # asset needs a newer glibc than the local one
    fi
    _pf_f=$(printf '%s\n' "$_pf_n" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')
    _pf_s=$(printf '%s\n' "$_pf_n" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')
    _pf_sz=$(printf '%s\n' "$_pf_n" | sed -n 's/.*"size":"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p')
    _pf_g=$(printf '%s\n' "$_pf_n" | sed -n 's/.*"manager":"\([^"]*\)".*/\1/p')
    _pf_id=$(printf '%s\n' "$_pf_n" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    printf 'ASSET|%s|%s|%s|%s|%s|%s\n' "${_pf_id:-$_pf_t}" "$_pf_f" "$_pf_s" "$_pf_sz" "$_pf_g" "${_pf_base}${_pf_f}"
    return 0
  done <"$_pf_m"
  return 1
}

# ------------------------------------------------------------- downloading
_fetch() { # URL DEST
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    log_err "Neither curl nor wget is available; please install one and retry."
    return 1
  fi
}

_sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d" " -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    log_err "Neither sha256sum nor shasum is available; cannot verify checksums."
    return 1
  fi
}

_verify_asset() { # FILE EXPECTED_SHA EXPECTED_SIZE
  _va_got=$(_sha256_of "$1") || die "Cannot compute the sha256 of $1."
  if [ "$_va_got" != "$2" ]; then
    log_err "Checksum mismatch for $(basename "$1")."
    log_err "  expected: $2"
    log_err "  actual:   $_va_got"
    log_err "This is suspicious; do not force an install over a bad download."
    exit 1
  fi
  if [ -n "$3" ] && [ "$3" -gt 0 ] 2>/dev/null; then
    _va_size=$(wc -c <"$1")
    if [ "$_va_size" != "$3" ]; then
      log_err "Size mismatch for $(basename "$1"): expected $3 bytes, got $_va_size."
      exit 1
    fi
  fi
  log "Verified: sha256 ok ($(basename "$1"))."
}

# ------------------------------------------------------------ audit pieces
audit_gpu() {
  GPU_VENDOR=none
  if [ -d /dev/dri ]; then
    log "Direct rendering nodes (/dev/dri): present."
  else
    log "WARNING: /dev/dri is missing; GPU acceleration is likely unavailable."
  fi
  if command -v lspci >/dev/null 2>&1; then
    _au_lines=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' || printf '')
    if [ -n "$_au_lines" ]; then
      case $(printf '%s' "$_au_lines" | tr '[:upper:]' '[:lower:]') in
        *nvidia*) GPU_VENDOR=nvidia ;;
        *intel*) GPU_VENDOR=intel ;;
        *radeon* | *amd* | *ati*) GPU_VENDOR=amd ;;
        *) GPU_VENDOR=unknown ;;
      esac
      log "GPU (lspci):"
      printf '%s\n' "$_au_lines" | sed 's/^/    /'
      printf '%s\n' "$_au_lines" | sed 's/^/    /' >>"$LOGFILE" 2>/dev/null || :
    else
      log "lspci found no VGA/3D/Display entries."
    fi
  else
    log "lspci is not installed; cannot detect the GPU vendor (non-fatal)."
  fi
  log "GPU vendor hint: $GPU_VENDOR"

  _au_icd=0
  for _au_d in /usr/share/vulkan/icd.d /etc/vulkan/icd.d; do
    if [ -d "$_au_d" ]; then
      _au_n=$(find "$_au_d" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)
      _au_icd=$((_au_icd + _au_n))
      log "Vulkan ICD json files in $_au_d: $_au_n"
    else
      log "No Vulkan ICD directory at $_au_d (non-fatal)."
    fi
  done
  if [ "$_au_icd" -eq 0 ]; then
    log "WARNING: no Vulkan ICDs installed yet; driver packages below provide them (--no-drivers skips)."
  fi
}

audit_session() {
  SESSION_TYPE=unknown
  _as_t=${XDG_SESSION_TYPE:-}
  if [ -n "${DISPLAY:-}" ] || [ "$_as_t" = "x11" ]; then
    SESSION_TYPE=x11
  elif [ "$_as_t" = "wayland" ]; then
    SESSION_TYPE=wayland
  fi
  if [ "$SESSION_TYPE" = "wayland" ]; then
    log "Session: Wayland. The client runs through Xwayland."
    if command -v Xwayland >/dev/null 2>&1; then
      log "Xwayland: present."
    else
      log "Xwayland: NOT found (it will be installed below)."
    fi
  elif [ "$SESSION_TYPE" = "x11" ]; then
    log "Session: X11 (DISPLAY=${DISPLAY:-not-set-in-this-shell})."
  else
    log "Session type unknown (no XDG_SESSION_TYPE/DISPLAY). Continuing."
  fi
}

audit_disk() {
  _di_k=$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -z "$_di_k" ]; then
    log "WARNING: cannot stat free space for $1."
    return 0
  fi
  _di_gb=$((_di_k / 1048576))
  log "Free space under $1: about $_di_gb GB."
  if [ "$_di_k" -lt "$LOL_DISK_MIN_KB" ]; then
    log "WARNING: less than 10 GB free. The game itself needs about 35 GB later."
  fi
}

audit_pkgmanager() {
  _pk_b=""
  case $OS_FAMILY in
    deb) _pk_b="apt-get" ;;
    rpm) _pk_b="dnf" ;;
    arch) _pk_b="pacman" ;;
    void) _pk_b="xbps-install" ;;
  esac
  if command -v "$_pk_b" >/dev/null 2>&1; then
    log "Package manager: $_pk_b (present)."
  else
    die "Required package manager '$_pk_b' for family '$OS_FAMILY' is missing."
  fi
  if [ "$(id -u)" = "0" ]; then
    return 0
  fi
  if [ "${LOL_TEST_NO_SUDO:-0}" = "1" ]; then
    log "LOL_TEST_NO_SUDO=1: skipping the sudo validation."
    return 0
  fi
  if [ "$OPT_CHECK" = "1" ]; then
    log "sudo privileges: not validated by --check."
    return 0
  fi
  if ! sudo -n true 2>/dev/null; then
    log "Sudo requires a password; running 'sudo -v' (enter it if prompted)."
    if [ -r /dev/tty ]; then
      if ! sudo -v; then
        die "sudo authentication failed; cannot install system packages."
      fi
    else
      die "sudo would ask for a password, but no terminal is attached (piped stdin). Run from a terminal, or pre-authenticate with 'sudo -v'."
    fi
  else
    log "Passwordless sudo available."
  fi
}

audit_environment() {
  phase "Auditing your system"
  if [ -n "$LOL_TEST_OS_RELEASE" ]; then
    log "(hook) LOL_TEST_OS_RELEASE=$LOL_TEST_OS_RELEASE"
  fi
  if ! load_os_release; then
    die "Cannot read the OS identity (os-release)."
  fi
  log "Distribution ID: $OS_ID (ID_LIKE: ${OS_ID_LIKE:-none})"
  OS_FAMILY=$(detect_family)
  log "Resolved family: $OS_FAMILY"
  check_supported_family "$OS_FAMILY" "$OS_ID" || exit 1
  check_arch || exit 1
  log "Architecture: x86_64 (OK)."
  check_kernel || exit 1
  log "Kernel: $(uname -r 2>/dev/null || printf 'unknown') (>= $LOL_KERNEL_MIN OK)."
  check_libc || exit 1
  log "libc: glibc $GLIBC_VER (OK)."
  audit_gpu
  audit_session
  audit_disk "$TARGET_HOME"
  audit_pkgmanager
}

# ------------------------------------------------------------ target user
_home_of() {
  _ho_h=$(getent passwd "$1" 2>/dev/null | cut -d: -f6 | head -n 1)
  if [ -z "$_ho_h" ]; then
    _ho_h=$(grep "^$1:" /etc/passwd 2>/dev/null | cut -d: -f6 | head -n 1)
  fi
  printf '%s\n' "$_ho_h"
}

resolve_target_user() {
  if [ "$(id -u)" = "0" ]; then
    if [ -z "$SUDO_USER" ] || [ "$SUDO_USER" = "root" ]; then
      die "Running as plain root is not supported (root's environment is never configured). Re-run WITHOUT sudo, or via: curl ... | sudo bash (SUDO_USER is then configured)."
    fi
    TARGET_USER=$SUDO_USER
  else
    TARGET_USER=$(id -un)
  fi
  TARGET_HOME=$(_home_of "$TARGET_USER")
  if [ -z "$TARGET_HOME" ]; then
    die "Cannot resolve the home directory of '$TARGET_USER'."
  fi
  log "Target user: $TARGET_USER (home: $TARGET_HOME)"
}

# ---------------------------------------------------------------- prompts
prompt_confirm() {
  if [ "$OPT_YES" = "1" ]; then
    log "Running with --yes: skipping the confirmation prompt."
    return 0
  fi
  if [ ! -r /dev/tty ]; then
    log_err "A confirmation is required, but no terminal is attached (stdin is not a tty)."
    log_err "Run from a terminal, or pass --yes to accept automatically."
    return 1
  fi
  printf '\nProceed with the installation? Type "yes" (anything else aborts): ' >/dev/tty
  _pr_a=""
  if ! read -r _pr_a </dev/tty; then
    log_err "No answer was read from the terminal; aborting."
    return 1
  fi
  case $_pr_a in
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
  esac
  log_err "Not confirmed; aborting (nothing was installed)."
  return 1
}

# ------------------------------------------------------------ privileged
_gpu_install() { # PACKAGES ; executes (or dry-runs) the manager install command
  case $ASSET_MGR in
    apt) _asroot "apt-get install -y $1" ;;
    dnf) _asroot "dnf install -y $1" ;;
    pacman) _asroot "pacman -S --noconfirm $1" ;;
    xbps) _asroot "xbps-install -y $1" ;;
  esac
}

_asroot() { # COMMAND-STRING ; echoes it, then executes it (or dry-runs)
  _as_c=$1
  log "+ $_as_c"
  if [ "$OPT_DRY" = "1" ]; then
    return 0
  fi
  if [ "$(id -u)" = "0" ]; then
    sh -c "$_as_c"
  else
    sudo sh -c "$_as_c"
  fi
}

# --------------------------------------------------------------- manifest
load_manifest() {
  if [ -n "$LOL_TEST_MANIFEST" ]; then
    MANIFEST_PATH=$LOL_TEST_MANIFEST
    log "(hook) LOL_TEST_MANIFEST=$MANIFEST_PATH"
    return 0
  fi
  MANIFEST_PATH="$TEMPDIR/manifest.json"
  log "Fetching the release manifest: $LOL_MANIFEST_URL"
  if ! _fetch "$LOL_MANIFEST_URL" "$MANIFEST_PATH"; then
    log_err "Could not download the release manifest from $LOL_MANIFEST_URL."
    return 1
  fi
  return 0
}

resolve_asset() {
  _re_out=$(pick_asset "$MANIFEST_PATH" "$OS_FAMILY" "$GLIBC_VER")
  if [ -z "$_re_out" ]; then
    log_err "No release asset matches distro family '$OS_FAMILY' for glibc $GLIBC_VER (see the offering above)."
    exit 1
  fi
  ASSET_ID=$(printf '%s\n' "$_re_out" | cut -d'|' -f2)
  ASSET_FILE=$(printf '%s\n' "$_re_out" | cut -d'|' -f3)
  ASSET_SHA=$(printf '%s\n' "$_re_out" | cut -d'|' -f4)
  ASSET_SIZE=$(printf '%s\n' "$_re_out" | cut -d'|' -f5)
  ASSET_MGR=$(printf '%s\n' "$_re_out" | cut -d'|' -f6)
  ASSET_URL=$(printf '%s\n' "$_re_out" | cut -d'|' -f7)
  case $OS_FAMILY in
    deb) _re_dm="apt" ;;
    rpm) _re_dm="dnf" ;;
    arch) _re_dm="pacman" ;;
    void) _re_dm="xbps" ;;
  esac
  log "Resolved asset: id=$ASSET_ID file=$ASSET_FILE"
  log "Download: $ASSET_URL"
  REL_VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST_PATH" 2>/dev/null | head -n 1)
  log "Latest release: ${REL_VERSION:-unknown}"
}

download_asset() {
  ASSET_PATH="$TEMPDIR/$ASSET_FILE"
  if [ "$OPT_DRY" = "1" ]; then
    log "DRY-RUN: would download $ASSET_URL"
    log "DRY-RUN: would verify sha256=$ASSET_SHA (size=$ASSET_SIZE)"
    return 0
  fi
  log "Downloading $ASSET_URL"
  if ! _fetch "$ASSET_URL" "$ASSET_PATH"; then
    log_err "Download failed. Check your connection and retry."
    exit 1
  fi
  _verify_asset "$ASSET_PATH" "$ASSET_SHA" "$ASSET_SIZE"
}

# --------------------------------------------------------------- installer
install_package() {
  if [ "$OPT_DRY" = "1" ]; then
    # fall through: _asroot prints the commands instead of running them
    :
  fi
  case $ASSET_MGR in
    apt)
      _asroot "DEBIAN_FRONTEND=noninteractive apt-get install -y '$ASSET_PATH'"
      ;;
    dnf)
      _asroot "dnf install -y '$ASSET_PATH'"
      ;;
    pacman)
      _asroot "pacman -Sy --noconfirm"
      _asroot "pacman -U --noconfirm '$ASSET_PATH'"
      ;;
    xbps)
      _asroot "xbps-install -S -y"
      if command -v xbps-rindex >/dev/null 2>&1; then
        _asroot "cd '$TEMPDIR' && xbps-rindex -a '$ASSET_FILE'"
      else
        log "xbps-rindex is missing; the repository install below is best effort."
      fi
      if ! _asroot "xbps-install -y --repository='$TEMPDIR' lol-on-linux"; then
        log_err "xbps-install from the local repository failed."
        log_err "Manual steps:"
        log_err "  1) sudo xbps-install -Syu"
        log_err "  2) sudo xbps-rindex -a $ASSET_PATH"
        log_err "  3) sudo xbps-install -y --repository=$TEMPDIR lol-on-linux"
        exit 1
      fi
      ;;
    *)
      die "Unsupported package manager '$ASSET_MGR' for family '$OS_FAMILY'."
      ;;
  esac
  if [ "$OPT_DRY" != "1" ]; then
    log "Installed the lol-on-linux system package."
  fi
}

install_gpu_extras() {
  if [ "$OPT_NO_DRIVERS" = "1" ]; then
    log "Skipping GPU driver packages (--no-drivers)."
  else
    _ge_pkgs=""
    case $GPU_VENDOR in
      intel)
        case $OS_FAMILY in
          deb | rpm) _ge_pkgs="mesa-vulkan-drivers" ;;
          arch) _ge_pkgs="vulkan-intel" ;;
          void) _ge_pkgs="mesa-vulkan-intel" ;;
        esac
        ;;
      amd)
        case $OS_FAMILY in
          deb | rpm) _ge_pkgs="mesa-vulkan-drivers" ;;
          arch) _ge_pkgs="vulkan-radeon" ;;
          void) _ge_pkgs="mesa-vulkan-radeon" ;;
        esac
        ;;
      nvidia)
        case $OS_FAMILY in
          deb) _ge_npkg="nvidia-driver" ;;
          rpm) _ge_npkg="xorg-x11-drv-nvidia" ;;
          arch) _ge_npkg="nvidia-dkms" ;;
          void) _ge_npkg="nvidia" ;;
        esac
        log "NVIDIA detected: the proprietary driver is NOT installed automatically."
        log "Install it yourself if needed (package name on this family: ${_ge_npkg:-<see distro docs>})."
        log "NOTE: NVIDIA is not validated by the upstream project; AMD RADV is."
        ;;
      *)
        log "GPU vendor unknown; no Vulkan ICD package will be auto-installed."
        log "If graphics fail later, install 'mesa-vulkan-drivers' (deb/rpm/void) or 'vulkan-intel'/'vulkan-radeon' (arch)."
        ;;
    esac
    if [ -n "$_ge_pkgs" ]; then
      if ! _gpu_install "$_ge_pkgs"; then
        log_err "Could not install '$_ge_pkgs'; Vulkan/graphics may be incomplete. Install it manually."
      fi
    fi
  fi
  if [ "$SESSION_TYPE" = "wayland" ] && ! command -v Xwayland >/dev/null 2>&1; then
    case $OS_FAMILY in
      deb) _ge_xw="xwayland" ;;
      rpm) _ge_xw="xorg-x11-server-Xwayland" ;;
      arch) _ge_xw="xorg-server-xwayland" ;;
      void) _ge_xw="xorg-server-xwayland" ;;
    esac
    if ! _gpu_install "$_ge_xw"; then
      log "Could not install '$_ge_xw'; Xwayland is required on Wayland sessions."
    fi
  fi
  log "Optional: 'gamemode' can improve performance; consider installing it."
}

warm_up_user() {
  if [ "$OPT_DRY" = "1" ]; then
    log "DRY-RUN: would run as user '$TARGET_USER': $LOL_LAUNCHER --first-run"
    return 0
  fi
  log "Running first-run as '$TARGET_USER' (per-user overlays, rendered templates, desktop entry)..."
  _wa_c="/usr/local/bin/lol-on-linux --first-run"
  _wa_out=""
  _wa_rc=0
  if [ "$TARGET_USER" = "$(id -un)" ] && [ "$(id -u)" != "0" ]; then
    _wa_out=$("$LOL_LAUNCHER" --first-run 2>&1) || _wa_rc=1
  elif command -v runuser >/dev/null 2>&1; then
    _wa_out=$(runuser -u "$TARGET_USER" -- "$LOL_LAUNCHER" --first-run 2>&1) || _wa_rc=1
  else
    _wa_out=$(su -l "$TARGET_USER" -c "$_wa_c" 2>&1) || _wa_rc=1
  fi
  if [ "$_wa_rc" = "0" ]; then
    log "First-run OK."
  else
    log "WARNING: the user-level first-run failed (non-fatal); it will re-run on your first launch."
  fi
  if [ -n "$_wa_out" ]; then
    log "$_wa_out"
  fi
}

final_report() {
  phase "Done"
  log "Installed version: ${REL_VERSION:-unknown} (installer $LOL_VERSION)."
  log "Launcher: $LOL_LAUNCHER (menu + desktop shortcut are created on first run)."
  log ""
  log "NEXT STEP: open 'League of Legends' from your application menu."
  log "The first launch runs Riot's OFFICIAL installer GUI: you need a Riot account"
  log "and about 35 GB of free disk for the game data."
  log ""
  log "UNINSTALL: remove the system package ('apt remove lol-on-linux',"
  log "'dnf remove lol-on-linux', 'pacman -R lol-on-linux', or"
  log "'xbps-remove lol-on-linux'). Game data lives in ~/.darling; remove manually."
  log "Full log: $LOGFILE"
}

# ------------------------------------------------------------------ banner
banner() {
  log "=============================================================="
  log "  lol-on-linux remote installer  v$LOL_VERSION"
  log "  (project repository: $LOL_REPO)"
  log "=============================================================="
  log ""
  log "This installs a Darling-based runtime so that Riot's OFFICIAL macOS"
  log "League of Legends client can run on your x86_64 Linux machine."
  log ""
  log "DISCLAIMER: running the macOS client under Darling is UNOFFICIAL and can get"
  log "your Riot account PERMANENTLY BANNED. Do not use your main account; do not"
  log "cheat; do not play ranked."
  log ""
  log "Downloads now: about 250-600 MB. The GAME DATA (~35 GB) is downloaded later,"
  log "by you, through Riot's official installer on the first launch (no automation)."
  log ""
}

# -------------------------------------------------------------------- main
print_help() {
  cat <<EOF
Usage: install-remote.sh [--yes] [--check] [--dry-run] [--no-drivers] [--help]

Installs the lol-on-linux runtime (Darling-based) to run Riot's official macOS
League of Legends client on an x86_64 Linux system.

Options:
  --yes          Non-interactive: skip the confirmation prompt.
  --check        Audit this system and show what would be installed; installs NOTHING.
  --dry-run      Print every command that would run; installs NOTHING.
  --no-drivers   Skip the GPU driver (Vulkan ICD) packages.
  --help         Show this text.

Project/repository: $LOL_REPO
EOF
}

parse_flags() {
  while [ "$#" -gt 0 ]; do
    case $1 in
      --yes | -y) OPT_YES=1 ;;
      --check) OPT_CHECK=1 ;;
      --dry-run) OPT_DRY=1 ;;
      --no-drivers) OPT_NO_DRIVERS=1 ;;
      --help | -h)
        print_help
        exit 0
        ;;
      *)
        log_err "Unknown option: $1"
        print_help >&2
        exit 2
        ;;
    esac
    shift
  done
}

main() {
  parse_flags "$@"
  log "lol-on-linux remote installer v$LOL_VERSION (log: $LOGFILE)"
  resolve_target_user
  banner
  if [ "$OPT_CHECK" = "1" ]; then
    audit_environment || die "This system does not meet requirements (see above)."
    phase "Manifest resolution (--check: installs nothing)"
    if ! load_manifest; then
      die "The manifest could not be fetched; cannot complete the check."
    fi
    resolve_asset
    log ""
    log "CHECK COMPLETE: this system looks compatible. No packages were installed."
    exit 0
  fi
  if [ "$OPT_DRY" = "1" ]; then
    log "DRY-RUN: nothing will be installed or modified."
  elif ! prompt_confirm; then
    exit 1
  fi
  TEMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/lol-on-linux.XXXXXX") || die "Cannot create a temp directory."
  trap '[ -n "$TEMPDIR" ] && rm -rf "$TEMPDIR"' EXIT
  audit_environment || die "This system does not meet requirements; nothing was installed."
  phase "Step 2/5: selecting the release for your distro"
  load_manifest || die "Cannot fetch the release manifest; check your connection."
  resolve_asset
  phase "Step 3/5: downloading the package"
  download_asset
  phase "Step 4/5: installing (sudo may be used)"
  audit_pkgmanager
  install_package
  install_gpu_extras
  phase "Step 5/5: setting up the user environment"
  warm_up_user
  final_report
}

_entry() {
  if [ "${LOL_TEST_SOURCE_ONLY:-}" = "1" ]; then
    return 0
  fi
  main "$@"
}
_entry "$@"
