#!/usr/bin/env bash
# CI entry point for the payload build: installs the build dependencies plus
# the LLVM toolchain, then runs the full payload build. Works both on a host
# runner (passwordless sudo) and inside a root container. The dependency list
# below is a superset of the Darling requirements; a failed configure points at
# a missing name.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

unset CDPATH
here=$(cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)

out_dir=${1:?usage: ci-build.sh <out-dir> [version]}
version=${2:-$(date -u +%Y.%m.%d)}

run_root() {
  if [ "$(id -u)" = 0 ]; then
    "$@"
  else
    sudo -n env DEBIAN_FRONTEND=noninteractive "$@"
  fi
}

run_root apt-get update -qq
run_root apt-get install -y -qq --no-install-recommends \
  build-essential cmake make pkg-config file \
  git git-lfs curl unzip zip ca-certificates \
  python3 python3-venv python3-pip \
  zstd xz-utils tar patchelf \
  libx11-dev libx11-xcb-dev libxcb1-dev libxcb-shm0-dev libxext-dev \
  libxcursor-dev libxrandr-dev libxi-dev libxinerama-dev libxfixes-dev \
  libxkbcommon-dev libgl1-mesa-dev libglu1-mesa-dev libegl1-mesa-dev \
  libasound2-dev libpulse-dev libdbus-1-dev \
  libcairo2-dev libfreetype-dev libfontconfig1-dev \
  libssl-dev libgnutls28-dev libxml2-dev libbz2-dev zlib1g-dev liblzma-dev \
  libzstd-dev libicu-dev libsqlite3-dev libcurl4-openssl-dev \
  libavcodec-dev libavformat-dev libavutil-dev libswresample-dev libswscale-dev \
  libjpeg-turbo8-dev libtiff5-dev libdeflate-dev \
  libvulkan-dev libvulkan1 mesa-vulkan-drivers vulkan-tools \
  uuid-dev libbsd-dev libcap-dev libcap2-bin libarchive-dev liblz4-dev \
  libfuse-dev libudev-dev libelf-dev libgif-dev libxkbfile-dev \
  locales \
  libedit2 libz3-4 \
  gcc-multilib
# gcc-multilib is not for a 32-bit build: it is the only jammy package that
# creates /usr/include/asm -> x86_64-linux-gnu/asm. Darling's vendored
# fanotify.h goes through <linux/types.h> to <asm/types.h>, which Arch ships
# directly but Debian/Ubuntu keep under the multiarch dir.

git lfs install --skip-repo >/dev/null 2>&1 || true

"$repo_root/ci/install-toolchain.sh"

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  git config --global --add safe.directory '*'
fi

"$repo_root/ci/build-payload.sh" --out "$out_dir" --version "$version"
