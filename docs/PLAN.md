# lol-on-linux — Plan maestro

Repositorio independiente que **extiende** [lucannez64/darling-lol](https://github.com/lucannez64/darling-lol) (se depende 100% de él, sin forkear código): su CI compila el proyecto completo una vez por release, publica paquetes precompilados por familia de distro y un instalador `curl | bash` universal que prepara el entorno, instala todo y deja el lanzador en el menú y en el escritorio.

El juego sigue instalándose **manualmente** por la GUI oficial de Riot con la cuenta del usuario. Este repo nunca distribuye archivos de Riot.

---

## 1. Hallazgos verificados en disco que definen el diseño

Comprobado sobre la instalación real (`/usr/local/libexec/darling`, `~/.darling`, `build/`):

| Hallazgo | Implicación |
|---|---|
| `/usr/local/bin/{darling,darlingserver,darling-coredump}` solo enlazan **libc, libstdc++, libm, libgcc_s** (nada de X11/Vulkan/ffmpeg/FUSE) | El binario base es casi universal; el `libmimalloc.so` que aparecía en `ldd` era un `LD_PRELOAD` del sistema anfitrión — **no es dependencia de Darling** |
| `libdarling-xshm.so` (único shim ELF que toca el host) enlaza `libX11.so.6, libX11-xcb.so.1, libxcb.so.1, libxcb-shm.so.0, libXext.so.6` | SONAMEs universales en todas las distros: **no obligan build por distro** |
| Todo lo gráfico/audio/framework (`RuntimeLibraries`, `RuntimeFrameworks` por usuario, ~28 MB) es **Mach-O** generado por `install-runtime.sh` → produce lo que el árbol `build/` compiló | Es binario distro-independiente; el plan es **precompilarlo en CI y copiarlo en el primer uso** (sin compilar en el PC del usuario) |
| El pipeline de overlays (`install-riot-presentation-runtime.sh`, `install-riot-gpu-runtime.sh`) hace `make`/`clang` sobre `build/darling-src` | En CI se ejecuta completo con un `DPREFIX` de staging; en el usuario solo se **copian** los resultados |
| `tools/*.py` de runtime usan solo **stdlib** (`requirements.txt` es para checks offline) | El paquete solo necesita `python3` |
| `-march=native` aparece en **19 puntos** de `scripts/` y `tools/` | CI debe normalizar flags (`-march=x86-64`) y verificar que no quede ninguno |
| `build.sh` usa `CMAKE_INSTALL_PREFIX=/usr/local`; `riot-desktop-entry.py` ya genera entrada `.desktop` + icono SVG original (y usa el `.icns` real del juego si está instalado) | Se reutiliza todo; el árbol entero queda en `/usr/local` (compatible con sistemas inmutables tipo Silverblue/Bazzite, donde `/usr/local` es la zona mutable) |
| Kernel **≥ 5.14** obligatorio y x86-64 (32-bit ABI descartada por el patch de OpenDirectory) | Corta naturalmente a Ubuntu 20.04 / Debian 11: la base soportada es glibc ≥ 2.35 (Ubuntu 22.04, Debian 12) |

**Consecuencia arquitectónica principal:** un **único build genérico por release** (contenedor `ubuntu:22.04` + LLVM 23, `-march=x86-64`, glibc 2.35, libstdc++ GCC 11) sirve para las 5 familias. Los paquetes por distro son **reempaquetados del mismo payload** con metadata propia — no 8 compiladas completas.

---

## 2. Arquitectura en 3 pilares

### Pilar A — CI: `release.yml` + `check-upstream.yml`

**Job pesado (1 solo):**
1. Contenedor `ubuntu:22.04`; instala deps de upstream + LLVM/Clang 23 (tarball oficial LLVM, fallback `apt.llvm.org`).
2. Clona `darling-lol` en el SHA de `upstream.lock` (git + git-lfs) y ejecuta `prepare.py` (aplica los 30 patches pinneados). Cache de fuentes (`actions/cache`) por SHA upstream.
3. **Normaliza flags**: `sed -i 's/-march=native/-march=x86-64/g'` sobre `scripts/ tools/` + verificación de 0 ocurrencias restantes.
4. `build.sh` con `JOBS` del runner → `cmake --install` a **DESTDIR de staging** (base runtime).
5. Overlays: `install-runtime.sh` con `DPREFIX=/staging/prefix`, `RIOT_GUEST_HOME=/staging/prefix/Users/loluser` (usuario ficticio) → produce `RuntimeLibraries/`, `RuntimeFrameworks/`, overrides del prefix.
6. Recompila `libDarlingXShm.dylib` con la **ruta final** horneada (`/usr/local/lib/lol-on-linux/libdarling-xshm.so`) en vez de la ruta de build.
7. Empaqueta `payload.tar.zst` (base + overlays + plantillas `tools/` + glue) + `sha256` + `build-info.json` (SHA upstream, revisiones pinneadas, versiones de toolchain, digest del contenedor).

Riesgo controlado: techo de **6 h por job**. Mitigación: cache de fuentes + re-run incremental del job si expira (segundo intento retoma con cache del build tree si cabe en los 10 GB de cache del repo; si no, runner más grande puntual o build en 2 jobs encadenados por artifact).

**Jobs ligeros (uno por formato):** descargan el payload y producen:

| Formato | Familia | Smoke test en contenedor limpio |
|---|---|---|
| `.deb` | Debian/Ubuntu (glibc ≥ 2.35) | `debian:12` y `ubuntu:24.04` |
| `.rpm` | Fedora (últimas 2) | `fedora:latest` |
| `.pkg.tar.zst` | Arch (rolling + derivadas) | `archlinux:latest` |
| `.xbps` | Void glibc | `void-linux/void-glibc` |

Smoke test = instalar el paquete → `lol-on-linux --verify` (render de tools + `darling shell /usr/bin/true` headless, con `xvfb-run` si hiciera falta) → validar `.desktop`. **CI nunca descarga nada de Riot ni automatiza el cliente.**

**Job release:** agrega assets + `manifest.json` + `SHA256SUMS`:

```json
{
  "version": "2026.10.18",
  "upstream": { "repo": "lucannez64/darling-lol", "commit": "abc1234" },
  "assets": [
    { "id": "deb", "file": "lol-on-linux_2026.10.18_amd64.deb",
      "sha256": "...", "glibc_required": "2.35", "families": ["debian","ubuntu"] },
    { "id": "rpm", "file": "....rpm", "families": ["fedora"] },
    { "id": "arch", "file": "....pkg.tar.zst", "families": ["arch"] },
    { "id": "void", "file": "....xbps", "families": ["void"] },
    { "id": "portable", "file": "payload-....tar.zst", "families": ["*"] }
  ],
  "mirror_url": null
}
```

El instalador elige asset por **familia + `glibc_required` ≤ glibc local** → derivadas nuevas funcionan sin tocar el script.

**`check-upstream.yml`** (cron diario): compara HEAD de darling-lol con `upstream.lock`; si cambió, abre issue "recompilar" y valida que las suposiciones del build (archivos a normalizar, `build.sh`, `install-runtime.sh`) siguen existiendo. El release se dispara con `workflow_dispatch` (aprobación humana para no publicar a ciegas).

Repo **público** → minutos de Actions gratuitos. Estimación: ~4–8 h de runner por release.

### Pilar B — El paquete (contenido idéntico en los 4 formatos)

```
/usr/local/bin/darling, darlingserver, darling-coredump
/usr/local/libexec/darling/**            (runtime base, ~522 MB)
/usr/local/lib/lol-on-linux/             (payload interno)
    tools/ scripts-glue/                 (plantillas + first-run)
    overlay/{RuntimeLibraries,RuntimeFrameworks}/
    libdarling-xshm.so  libDarlingXShm.dylib
/usr/local/bin/lol-on-linux              (CLI del usuario)
/usr/local/share/applications/lol-on-linux.desktop
/usr/local/share/icons/hicolor/scalable/apps/lol-on-linux.svg
```

- **Nombre del paquete:** `lol-on-linux`. **No** "Riot Games Launcher" (marca + engaño + riesgo legal). Descripción: "Unofficial runtime to run Riot's macOS League client on Linux via Darling".
- **Dependencias declaradas** (nombres por familia, resueltos por el gestor nativo): `libstdc++`, `libX11`, `libxcb`, `libxcb-shm`, `libXext`, `libasound`, `libpulse`, `python3`, `curl`, `unzip`. *A confirmar en CI:* cuál de las dos de audio referencia realmente el overlay de CoreAudio (se detecta con `ld`/strings en el job de payload).
- **Recommends:** `gamemode` (el runner ya usa `gamemoderun` si existe), `xwayland`.
- **Drivers GPU:** no van en el paquete (dependen del hardware) — los resuelve el instalador (sección siguiente).
- **AppImage: descartado** (modelo de instalación/permisos no encaja; se documenta el porqué). **Tarball portable** sí, como asset extra para distros exóticas.
- Sin postinst más allá del aviso de ban/kernel; el trabajo por-usuario ocurre en el **primer uso como usuario real** (no como root).
- **Upgrade** = reinstalar el paquete; `~/.darling` del usuario **nunca se toca** (solo overlays, que se reemplazan con backups `.before-*`).

### Pilar C — `install-remote.sh` + CLI `lol-on-linux`

Comando objetivo: `curl -fsSL https://raw.githubusercontent.com/SrDicov/lol-on-linux/main/install-remote.sh | bash`
(funciona también con `| sudo bash`: detecta `SUDO_USER` y configura **ese** usuario; jamás configura root. Recomendación en README: sin sudo).

**Fases del instalador** (POSIX sh, sin bashismos):

0. Banner + disclaimer de ban (el propio upstream confirma suspensiones y desaconseja usar la cuenta principal) → confirmación; `--yes` para no interactivo; prompts por `/dev/tty` cuando stdin es el script.
1. **Auditoría del entorno:** `os-release` (familia/versión y derivadas por `ID_LIKE`), arquitectura (x86-64 obligatorio), kernel ≥ 5.14, **libc: glibc obligatoria** (musl → mensaje específico para Void-musl/Alpine), GPU (`lspci` + `/dev/dri` + ICDs Vulkan presentes), sesión X11/Xwayland, RAM/disco (juego ≈ 35 GB), sudo disponible.
2. **Resolución de asset:** `releases/latest/download/manifest.json` → familia + glibc → asset + sha256.
3. Descarga + verificación de checksum.
4. **Dependencias y drivers:** instala el paquete con el gestor nativo (`apt`/`dnf`/`pacman -U`/`xbps-install`) → las deps declaradas se resuelven solas; luego extras por hardware: ICD Vulkan (mesa: `vulkan-radeon`/`vulkan-intel`; NVIDIA: paquete propietario + guía, sin validar), `xwayland` si Wayland, `gamemode` opcional.
5. **Warm-up como el usuario real** (`su -l`): crear/inicializar el prefix (`darling shell /usr/bin/true`), **copiar** overlays a `Users/<user>/{RuntimeLibraries,RuntimeFrameworks}` con backups atómicos, **renderizar** las plantillas en `~/.local/share/lol-on-linux/` (mini-repo: `scripts/*.py` + `tools/` → `configure.py --guest-user <user>` ahí dentro, usuario escribible, `$HOME` correcto), y generar entrada `.desktop` + **acceso directo en el escritorio** (`xdg-user-dir DESKTOP`, `gio set metadata::trusted` en GNOME).
6. **Verificación** (`lol-on-linux --verify`) + mensaje final con los siguientes pasos.

Extras: `--dry-run`, `--check` (solo auditoría), `--no-drivers`; log en `/tmp/lol-on-linux-install.log`; e idempotente (re-ejecutable = upgrade limpio).

**CLI `lol-on-linux`** (lo que abren el menú y el escritorio):
1. First-run silencioso si falta algo (render/overlays/entry).
2. Si **no** hay Riot Client en el prefix: guía de instalación — pide región (se guarda en `~/.config/lol-on-linux/config`), descarga el instalador oficial de Riot por región y abre su GUI bajo Darling (mismo flujo del `installer.sh` upstream, sin automatización).
3. Si hay cliente: exec del runner upstream (`run-riot-client.sh` renderizado, con sus fixes de rendimiento intactos).
4. Modos: `--verify`, `--doctor` (reporte de entorno/GPU/ICD), `--help`.

---

## 3. Matriz de soporte v1

| Familia | Paquete | Cubre | Notas |
|---|---|---|---|
| Debian/Ubuntu | `.deb` | Ubuntu 22.04+/24.04/26.04, Debian 12/13, Mint, Pop!, Zorin… | glibc ← 2.35; derivadas por `ID_LIKE` |
| Fedora | `.rpm` | Fedora (últimas 2) + derivadas | clones RHEL: mensaje "no soportado" (glibc vieja) |
| Arch | `.pkg.tar.zst` | Arch rolling + EndeavourOS/Manjaro/CachyOS… | |
| Void | `.xbps` | Void **glibc** | Void-musl: no soportada (el runtime es glibc) |
| Exóticas | tarball portable | cualquier x86-64 con glibc ≥ 2.35 y kernel ≥ 5.14 | instalación manual asistida |

Hardware: cualquier x86-64 (build baseline `-march=x86-64`); GPU con Vulkan hardware. AMD RADV es lo único validado por upstream — Intel/AMD-otras/NVIDIA salen como "no validado" con mensajes honestos.

---

## 4. Estructura del repositorio

```
lol-on-linux/
├── install-remote.sh              # entrypoint curl|bash (POSIX sh)
├── upstream.lock                  # SHA de darling-lol + hash de sus pins
├── LICENSE                        # GPL-3.0 (hereda del tooling upstream)
├── README.md                      # qué es, disclaimer de ban, comando de instalación
├── ci/
│   ├── normalize-flags.sh         # sed -march=x86-64 + verificación
│   ├── build-payload.sh           # pipeline pesado completo → payload.tar.zst
│   └── smoke-test.sh              # instalar + --verify (dentro de contenedor)
├── packaging/
│   ├── deb/make-deb.sh
│   ├── rpm/make-rpm.sh + lol-on-linux.spec
│   ├── arch/make-pkg.sh           # estilo PKGINFO + bsdtar (sin makepkg como root)
│   └── void/make-xbps.sh          # xbps-create
├── runtime/                        # glue del usuario
│   ├── lol-on-linux               # CLI (bash o sh; first-run/game-install/run/doctor)
│   ├── first-run.sh               # overlays + render + desktop
│   └── support-matrix.sh          # detección familia/asset (testeable con fixtures)
├── share/lol-on-linux.desktop
├── .github/workflows/{release.yml,check-upstream.yml,pr-validate.yml}
├── tests/
│   ├── detect-fixtures.sh         # unit del detector (os-release/glibc de mentira)
│   └── ...
└── docs/{PLAN.md (este), INSTALL.md, SUPPORT.md, TROUBLESHOOTING.md}
```

`packaging/` construye todo desde el **mismo payload**; nada de código de Darling vive en este repo (solo el pin + normalización + glue).

---

## 5. Seguridad, legal y operación

- Checksums SHA-256 en manifest + release; TLS. (Futuro opcional: firmar releases con GPG/cosign.)
- **Licencias:** GPL-3.0 propia; `NOTICE.md` del upstream exige auditar cada repo pinneado antes de redistribuir binarios → **checklist pre-primera-release** (bloqueante).
- **Nada de Riot en el repo/paquetes**: instaladores del juego y archivos se descargan del servidor oficial de Riot en la máquina del usuario.
- **Disclaimer de ban** en: consentimiento del instalador, README, primer arranque del CLI y `Comment=` del `.desktop`.
- **Plan anti-takedown** (el upstream lo anticipa): espejo de los assets + campo `mirror_url` en el manifest; el instalador lo usa como fallback.
- Upstream está en modo mantenimiento ("solo merges de PRs"): toda nuestra lógica vive aquí, sin pedirle nada. `check-upstream.yml` evita builds rotas por cambios upstream.

---

## 6. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Job de build > 6 h en runner 4 vCPU | Cache de fuentes por SHA; re-run incremental; dividir en 2 jobs; runner más grande puntual si es necesario |
| LLVM 23 tarball no arranca en glibc 2.35 | Fallback `apt.llvm.org` (jammy) o clang del distro ≥ 22; documentado |
| libstdc++ más nueva que la del target | Build baseline Ubuntu 22.04 (GCC 11) → corre en todas las soportadas; fallback: `-static-libstdc++` solo para `darlingserver`/`coredump` |
| Audio: libasound vs libpulse exacta | Se detecta en el job de payload; se declaran como deps del paquete |
| `libDarlingXShm.dylib` con ruta de build horneada | Se recompila en CI con la ruta final fija `/usr/local/lib/lol-on-linux/` |
| GPU Intel/NVIDIA sin validar | Mensajes honestos + `--doctor`; el instalador nunca promete lo que no está probado |
| Rolling (Arch/Void) rompe el payload | glibc de ambos es actual; smoke test por release y rebuild programado |
| Migración de usuarios del flujo manual (como este PC) | El payload reemplaza overlays manteniendo backups `.before-*`; `~/.darling` nunca se borra |
| RHEL/SUSE/atomic | v1: no soportado explícito (mensaje claro); atomic (Silverblue/Bazzite/SteamOS) best-effort experimental; v3 si hay demanda |

---

## 7. Roadmap por fases

| Fase | Contenido | Criterio de "done" |
|---|---|---|
| **F0** | Esqueleto del repo, `upstream.lock`, `normalize-flags.sh`, `LICENSE`, README con disclaimer, tests del detector | `shellcheck` + tests locales verdes |
| **F1** | `build-payload.sh` en CI + `.deb` + release con manifest + smoke Debian/Ubuntu | Instalación real en un contenedor/distrobox limpio: `--verify` OK |
| **F2** | `.rpm`, `.pkg.tar.zst`, `.xbps` + smokes de sus familias | 4 assets instalables y verificados |
| **F3** | `install-remote.sh` completo (auditoría → deps → drivers → warm-up → desktop) | `curl\|bash` en contenedor limpio de las 5 familias deja el lanzador funcionando |
| **F4** | `check-upstream.yml`, `--doctor`, docs, icono, espejo/manifest mirror | Primera release "para desconocidos" publicada |
| **F5** | Extras: variante optimizada x86-64-v3, atomic best-effort, firma de release | — |

---

## 8. Decisiones abiertas

1. ¿Repo público y bajo `SrDicov/lol-on-linux`? (gh ya autenticado como SrDicov; público = Actions gratis)
2. Icono: ¿reutilizamos el SVG original de `riot-desktop-entry.py` (y el `.icns` real cuando el juego ya está instalado) como icono oficial del paquete?
3. Nombre público: `lol-on-linux` (evitar "Riot Games Launcher" por marca/engaño) — ¿confirmas?
4. ¿Arrancamos F0+F1 (esqueleto + primer .deb automatizado) ya?
