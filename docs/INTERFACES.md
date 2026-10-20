# Interfaces — contract between components

Everything in this repo hangs off three interfaces: the **payload**, the **packages**
wrapping it, and the **release manifest** consumed by the installer.

## 1. Payload (`payload.tar.zst`)

Built by `ci/build-payload.sh` inside the build container. Single top-level directory
`payload/`. The tree is the complete installation with final absolute paths:

    payload/usr/local/bin/darling
    payload/usr/local/bin/darlingserver
    payload/usr/local/bin/darling-coredump
    payload/usr/local/bin/lol-on-linux                     # CLI (from runtime/lol-on-linux)
    payload/usr/local/libexec/darling/**                   # base runtime (cmake --install)
    payload/usr/local/lib/lol-on-linux/libdarling-xshm.so
    payload/usr/local/lib/lol-on-linux/libDarlingXShm.dylib
    payload/etc/ld.so.conf.d/lol-on-linux.conf             # puts the bundled libLLVM on the loader path
    payload/usr/local/lib/lol-on-linux/llvm/**                # bundled shared libLLVM (basename from llvm-config) + libedit.so.2 + libz3.so.4
    payload/usr/local/lib/lol-on-linux/payload-info.json
    payload/usr/local/lib/lol-on-linux/first-run.sh
    payload/usr/local/lib/lol-on-linux/install-remote.sh
    payload/usr/local/lib/lol-on-linux/tools/**            # upstream templates, NOT rendered
    payload/usr/local/lib/lol-on-linux/scripts/**          # common.py, configure.py, run.sh
    payload/usr/local/lib/lol-on-linux/overlay/prefix/**   # copied into $DPREFIX at first run
    payload/usr/local/lib/lol-on-linux/overlay/home/**     # copied into $DPREFIX/Users/<user> at first run
    payload/usr/local/share/applications/lol-on-linux.desktop
    payload/usr/local/share/icons/hicolor/scalable/apps/lol-on-linux.svg
    payload/usr/local/share/doc/lol-on-linux/LICENSE
    payload/usr/local/share/doc/lol-on-linux/README.md

Rules:

- No Riot content, no game files, no secrets.
- File permissions and symlinks preserved.
- `payload-info.json`: `{"version": "...", "upstream": {"repo": "...", "commit": "..."}, "llvm": {"version": "...", "library": "libLLVM-XX.so"}, "built_at": "...", "arch": "x86_64"}`
- `llvm/`: the shared libLLVM iridium `dlopen()`s at runtime (headers and library come
  from the same toolchain; no distribution ships the matching major), plus the two
  libraries it links against whose sonames are not portable: jammy's `libedit.so.2`
  (upstream and Fedora ship `libedit.so.0`) and `libz3.so.4`. Darling strips
  `LD_LIBRARY_PATH` from the guest environment, so the library is resolved through the
  loader cache: the payload ships `etc/ld.so.conf.d/lol-on-linux.conf` and every package
  runs `ldconfig` after (un)install (pacman/void triggers cover their own). `ldconfig`
  files a library under its SONAME and `dlopen()` looks names up in that cache, so the
  libLLVM copy is `patchelf --set-soname`'d to the exact name indium asks for.

## 2. Packages

Name `lol-on-linux`; version `YYYY.MM.DD` (release date); architecture `x86_64`.
File names:

- deb:  `lol-on-linux_<VER>_amd64.deb`
- rpm:  `lol-on-linux-<VER>-1.x86_64.rpm`
- arch: `lol-on-linux-<VER>-1-x86_64.pkg.tar.zst`
- void: `lol-on-linux_<VER>_1.x86_64.xbps`

Each wrapper receives `--payload <payload.tar.zst> --version <VER> --out <dir>` and
repackage the tree as-is (no file modification). The package path is printed as the
last line of stdout.

Dependencies (distro names; xbps rejects bare names, so the void wrapper spells them
as `name>=1`):

| family | runtime deps |
|---|---|
| deb  | libstdc++6, libx11-6, libxcb1, libxcb-shm0, libxext6, libasound2 \| libasound2t64, libpulse0, python3, curl, unzip, libxml2, libzstd1, zlib1g, libffi8, libbsd0 — Recommends: gamemode, xwayland |
| rpm  | libstdc++, libX11, libxcb, libXext, alsa-lib, pulseaudio-libs, python3, curl, unzip, libxml2, libzstd, zlib, libffi, libbsd — Recommends: gamemode |
| arch | gcc-libs, libx11, libxcb, libxext, alsa-lib, libpulse, python, bash, curl, unzip, libxml2, zstd, zlib, libffi, libbsd — optdepend: gamemode |
| void | libstdc++>=1, libX11>=1, libxcb>=1, libXext>=1, alsa-lib>=1, pulseaudio>=1, python3>=1, bash>=1, curl>=1, unzip>=1, libxml2>=1, libzstd>=1, zlib>=1, libffi>=1, libbsd>=1 |

(`libxcb-shm` ships inside the `libxcb` package on rpm/arch/void; Void's `pulseaudio`
package carries the libs, hence the different name there; Arch names the libzstd
package `zstd`. libbsd is what the bundled `libedit.so.2` itself links against.)

## 3. Release manifest (`manifest.json`)

Published as a release asset; the installer reads
`https://github.com/SrDicov/lol-on-linux/releases/latest/download/manifest.json`:

```json
{
  "schema": 1,
  "version": "2026.10.18",
  "released": "2026-10-18T12:00:00Z",
  "upstream": { "repo": "https://github.com/lucannez64/darling-lol", "commit": "<sha>" },
  "url_base": "https://github.com/SrDicov/lol-on-linux/releases/download/v2026.10.18/",
  "mirror_url": null,
  "assets": [
    { "id": "deb", "file": "lol-on-linux_<VER>_amd64.deb", "sha256": "...", "size": 0,
      "glibc_required": "2.35", "families": ["debian", "ubuntu"], "manager": "apt" }
  ]
}
```

Family detection: `/etc/os-release` `ID`/`ID_LIKE` → `debian|ubuntu|fedora|arch|void`.
`manager` selects the install command (`apt`, `dnf`, `pacman`, `xbps`).

## 4. Runtime layout (after installation)

- base runtime: `/usr/local/libexec/darling`
- payload dir: `/usr/local/lib/lol-on-linux`
- CLI: `/usr/local/bin/lol-on-linux`
- per-user mini-repo (rendered templates): `${XDG_DATA_HOME:-$HOME/.local/share}/lol-on-linux`
- prefix: `~/.darling` (overridable via `DPREFIX`); guest home `~/.darling/Users/<user>`
- config: `~/.config/lol-on-linux/config`

## 5. Code rules

- User-facing shell = POSIX sh (no bashisms), must pass `shellcheck -s sh`.
- CI/packaging shell = bash with `set -euo pipefail`, must pass `shellcheck -s bash`.
- English messages. No developer-machine paths. GPL-3.0. No Riot assets.
