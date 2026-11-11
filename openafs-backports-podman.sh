#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 ENEA
# SPDX-FileContributor: Alberto P
# SPDX-License-Identifier: MPL-2.0
#
# openafs-backports-podman.sh
#
# Builds the OpenAFS .deb packages (backport to Debian 13 "trixie") compatible with the running
# WSL2 kernel, inside a throwaway rootless Podman container. NOTHING is installed on your distro:
# the .deb files end up in ./openafs-debs/ under the directory you run the script from.
#
# What it produces (in ./openafs-debs/):
#   - openafs-client, openafs-krb5, libafsauthent*, libafsrpc*, libkopenafs*
#                              (userland, for afs-setup.sh)
#   - openafs-modules-dkms     (ONLY an input for wsl-modules-vhdx.sh: the kernel module is built
#                               there; do NOT install it on the distro)
#   - BUILD-INFO, SHA256SUMS
#
# Choosing the "kernel-compatible" version: among the available Debian sources (trixie and sid)
# it takes the newest one whose NEWS claims support for the running kernel major.minor; if none
# does, it takes the newest one with a warning (the real test is building the module in
# wsl-modules-vhdx.sh). The version number gets the ~bpo13+1 suffix, so it sorts above trixie's
# 1.8.13.x and below sid's version.
#
# Usage:
#   ./openafs-backports-podman.sh [build] [--force]   # builds the .deb files in ./openafs-debs/
#   ./openafs-backports-podman.sh list                # lists ./openafs-debs and BUILD-INFO
#   ./openafs-backports-podman.sh clean [-y]          # removes image and cache (not ./openafs-debs)
#   ./openafs-backports-podman.sh emit-containerfile | emit-inner
#                                                     # prints the generated files (debug)
#
# Options: --force overwrites ./openafs-debs if it already exists.
#
# Environment variables (all optional):
#   OPENAFS_SRC_VERSION  force the Debian source version (e.g. 1.8.17~pre1-1)
#   BPO_BUMP=0           do not add the ~bpo13+1 suffix to the changelog (default: 1)
#   AFS_WSL_WORK         work/cache directory (default: ~/.cache/openafs-backports)
#   AFS_WSL_IMAGE        image name (default: localhost/openafs-backports-builder:trixie)
#   AFS_WSL_NET          e.g. "host" -> --network=host (if DNS inside the container does not work)

set -euo pipefail

LAUNCH_DIR="$PWD"                         # results go here, not in the script's directory
WORK="${AFS_WSL_WORK:-$HOME/.cache/openafs-backports}"
IMAGE="${AFS_WSL_IMAGE:-localhost/openafs-backports-builder:trixie}"
KVER="$(uname -r)"
DEBS_DIR="$LAUNCH_DIR/openafs-debs"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

need_podman() {
  command -v podman >/dev/null ||
    die "podman is not installed. Install it with: sudo apt install podman"
  if ! podman info >/dev/null 2>&1; then
    podman info 2>&1 | tail -15 >&2 || true
    die "podman does not work in rootless mode" \
        "(see the error above; check /etc/subuid, uidmap, passt)."
  fi
}

# ---------------------------------------------------------------------------------------------
# Generated files
# ---------------------------------------------------------------------------------------------
emit_containerfile() {
cat <<'CFEOF'
FROM docker.io/library/debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
# deb-src for trixie and sid: only needed inside the container, to download the openafs sources.
RUN printf 'deb-src http://deb.debian.org/debian %s main\n' trixie sid \
      > /etc/apt/sources.list.d/src.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential devscripts fakeroot ca-certificates dpkg-dev \
 && rm -rf /var/lib/apt/lists/*
CFEOF
}

emit_inner() {
cat <<'INNEREOF'
#!/usr/bin/env bash
# Runs INSIDE the container. uname -r matches the host's WSL2 kernel.
set -euo pipefail
: "${KVER:?KVER is not set}"

MM="$(cut -d. -f1,2 <<<"$KVER")"          # 6.18
SRC=/work/src
OUTD=/out/openafs-debs
NPROC="$(nproc)"

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(uname -r)" == "$KVER" ]] || die "uname -r in the container ('$(uname -r)') != KVER ('$KVER')."
[[ -d /out ]] || die "/out is not mounted."
if [[ -e "$OUTD" && "${FORCE:-0}" != 1 ]]; then
  die "$OUTD already exists (--force to overwrite)."
fi

rm -rf "$SRC"; mkdir -p "$SRC"
apt-get update >/dev/null

# --- Debian (dpkg) version sorting, highest first ---------------------------------------------
vsort_desc() {
  local -a v=("$@") out=()
  local x i placed
  for x in "${v[@]}"; do
    placed=0
    for i in "${!out[@]}"; do
      if dpkg --compare-versions "$x" gt "${out[$i]}"; then
        out=("${out[@]:0:$i}" "$x" "${out[@]:$i}"); placed=1; break
      fi
    done
    ((placed)) || out+=("$x")
  done
  printf '%s\n' "${out[@]}"
}

# highest kernel declared in NEWS: only numbers right after "Linux"/"kernel" (major <= 8),
# excluding lines about other distributions (e.g. "Red Hat Enterprise Linux 9.0"). The lines
# used are printed in the log, so the result can be checked by eye.
news_max() {
  local news="$1" lines
  lines="$(grep -iE '(linux|kernel)[ a-z]*[ ]+[3-8]\.[0-9]{1,2}' "$news" |
           grep -viE 'rhel|red hat|enterprise|fedora|ubuntu|debian|suse|solaris|sun ' || true)"
  if [[ -n "$lines" ]]; then
    echo "    NEWS lines used:" >&2; head -6 <<<"$lines" | sed 's/^/      /' >&2
  fi
  grep -oiE '(linux|kernel)[ a-z]*[ ]+[3-8]\.[0-9]{1,2}' <<<"$lines" |
    grep -oE '[3-8]\.[0-9]{1,2}$' | sort -uV | tail -1 || true
}

# --- version selection ------------------------------------------------------------------------
fetch_version() {            # downloads and unpacks the source of version $1 into $SRC/$1
  local ver="$1" d="$SRC/$1"
  mkdir -p "$d"
  ( cd "$d" &&
    apt-get source --download-only "openafs=$ver" >/dev/null 2>&1 &&
    dpkg-source -x ./openafs_*.dsc >/dev/null )
  find "$d" -maxdepth 1 -type d -name 'openafs-*' | head -1
}

CHOSEN="" CHOSEN_DIR="" CHOSEN_NEWS=""
if [[ -n "${OPENAFS_SRC_VERSION:-}" ]]; then
  CHOSEN="$OPENAFS_SRC_VERSION"
  CHOSEN_DIR="$(fetch_version "$CHOSEN")"
  [[ -n "$CHOSEN_DIR" ]] || die "cannot download source openafs=$CHOSEN."
  CHOSEN_NEWS="$(news_max "$CHOSEN_DIR/NEWS")"
  log "Forced version: $CHOSEN" \
      "(NEWS claims up to kernel ${CHOSEN_NEWS:-<not found>}; running kernel: $MM)"
else
  mapfile -t ALL < <(apt-cache showsrc openafs | awk '/^Version:/{print $2}' | sort -u)
  ((${#ALL[@]})) || die "no openafs source found (deb-src unreachable?)."
  mapfile -t ORDERED < <(vsort_desc "${ALL[@]}")
  log "Available versions: ${ORDERED[*]}  (running kernel: $MM)"
  first=""; first_dir=""; first_news=""
  for v in "${ORDERED[@]}"; do
    d="$(fetch_version "$v")"
    [[ -n "$d" ]] || { warn "source $v cannot be downloaded, skipping."; continue; }
    mx="$(news_max "$d/NEWS")"
    log "  $v: NEWS claims kernel up to ${mx:-<not found>}"
    if [[ -z "$first" ]]; then first="$v"; first_dir="$d"; first_news="$mx"; fi
    if [[ -n "$mx" ]] && [[ "$(printf '%s\n%s\n' "$mx" "$MM" | sort -V | tail -1)" == "$mx" ]]; then
      CHOSEN="$v"; CHOSEN_DIR="$d"; CHOSEN_NEWS="$mx"; break
    fi
  done
  if [[ -z "$CHOSEN" ]]; then
    [[ -n "$first" ]] || die "no usable version."
    warn "no version claims support for Linux $MM in NEWS: using the newest one ($first)."
    warn "the real test is building the module (wsl-modules-vhdx.sh)."
    CHOSEN="$first"; CHOSEN_DIR="$first_dir"; CHOSEN_NEWS="$first_news"
  fi
fi
log "Chosen version: $CHOSEN ($(basename "$CHOSEN_DIR"))"

# --- build ------------------------------------------------------------------------------------
cd "$CHOSEN_DIR"
log "Installing build dependencies (including documentation: heavy, but it stays in the container)"
apt-get build-dep -y ./

BPO_VERSION="$CHOSEN"
if [[ "${BPO_BUMP:-1}" == 1 ]]; then
  BPO_VERSION="${CHOSEN}~bpo13+1"
  export DEBFULLNAME="WSL2 local backport" DEBEMAIL="nobody@localhost"
  dch -v "$BPO_VERSION" -D trixie-backports --force-distribution --force-bad-version \
      "Rebuild for Debian 13 (trixie) against WSL2 kernel $KVER."
  log "Backport version: $BPO_VERSION"
fi

log "Building the packages (parallel=$NPROC)"
DEB_BUILD_OPTIONS="nocheck nodoc parallel=$NPROC" dpkg-buildpackage -us -uc -b

# --- collection -------------------------------------------------------------------------------
log "Collecting the needed .deb files into $OUTD"
rm -rf "$OUTD"; mkdir -p "$OUTD"
shopt -s nullglob
got=()
for pat in openafs-client_ openafs-krb5_ libafsauthent libafsrpc libkopenafs \
           openafs-modules-dkms_; do
  found=0
  for f in ../"${pat}"*.deb; do
    case "$f" in *-dev_*|*dbgsym*) continue ;; esac
    cp "$f" "$OUTD/"; got+=("$(basename "$f")"); found=1
  done
  ((found)) || warn "no .deb for '${pat}*'"
done
((${#got[@]} >= 4)) || die "too few packages produced (${#got[@]})."
ls "$OUTD"/openafs-modules-dkms_*.deb >/dev/null 2>&1 ||
  die "openafs-modules-dkms was not produced."

( cd "$OUTD" && sha256sum ./*.deb > SHA256SUMS )
{
  echo "source:               $CHOSEN"
  echo "backport version:     $BPO_VERSION"
  echo "kernel checked:       $KVER"
  echo "NEWS claims up to:    ${CHOSEN_NEWS:-<not found>} (running kernel: $MM)"
  echo "date:                 $(date -u +%FT%TZ)"
  echo "packages:"
  printf '  %s\n' "${got[@]}"
} > "$OUTD/BUILD-INFO"
log "Done."
cat "$OUTD/BUILD-INFO"
INNEREOF
}

# ---------------------------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------------------------
cmd_build() {
  local force=0
  while (($#)); do
    case "$1" in
      --force) force=1 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  need_podman
  if [[ -e "$DEBS_DIR" && $force != 1 ]]; then
    die "$DEBS_DIR already exists (--force to overwrite)."
  fi
  mkdir -p "$WORK"/{ctx,src}
  emit_containerfile > "$WORK/ctx/Containerfile"
  emit_inner > "$WORK/inner.sh"

  local netarg=()
  [[ -n "${AFS_WSL_NET:-}" ]] && netarg=("--network=${AFS_WSL_NET}")

  log "Building image $IMAGE"
  podman build "${netarg[@]}" -t "$IMAGE" -f "$WORK/ctx/Containerfile" "$WORK/ctx"

  log "Starting the build container (kernel $KVER); results in $DEBS_DIR"
  podman run --rm "${netarg[@]}" \
    -e KVER="$KVER" \
    -e OPENAFS_SRC_VERSION="${OPENAFS_SRC_VERSION:-}" \
    -e BPO_BUMP="${BPO_BUMP:-1}" \
    -e FORCE="$force" \
    -v "$WORK:/work" \
    -v "$LAUNCH_DIR:/out" \
    "$IMAGE" bash /work/inner.sh

  cat <<EOF

Packages in $DEBS_DIR. Next steps (not run):
  1. ./wsl-modules-vhdx.sh --debs "$DEBS_DIR"      # builds the VHDX with kafs + openafs
  2. ./afs-setup.sh openafs --debs "$DEBS_DIR"     # installs the userland client on the distro
EOF
}

cmd_list() {
  [[ -d "$DEBS_DIR" ]] || die "$DEBS_DIR does not exist: run '$0 build' first."
  ls -l "$DEBS_DIR"
  if [[ -f "$DEBS_DIR/BUILD-INFO" ]]; then echo "--- BUILD-INFO"; cat "$DEBS_DIR/BUILD-INFO"; fi
}

cmd_clean() {
  [[ "$WORK" == "$HOME"/* ]] || die "refusing to delete '$WORK' (outside \$HOME)."
  if [[ "${1:-}" != "-y" ]]; then
    read -r -p "Remove image $IMAGE and $WORK? [y/N] " a
    [[ "$a" == [yY] ]] || { echo "cancelled"; return 0; }
  fi
  if command -v podman >/dev/null; then
    podman rmi -f "$IMAGE" 2>/dev/null || true
    podman unshare rm -rf "$WORK"
  else
    rm -rf "$WORK"
  fi
  log "Cleaned (the .deb files in $DEBS_DIR were not touched)."
}

usage() { sed -n '/^# [a-z-]*\.sh$/,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

case "${1:-build}" in
  build)               shift || true; cmd_build "$@" ;;
  --force)             cmd_build "$@" ;;
  list)                cmd_list ;;
  clean)               shift; cmd_clean "${1:-}" ;;
  emit-containerfile)  emit_containerfile ;;
  emit-inner)          emit_inner ;;
  -h|--help|help)      usage ;;
  *)                   usage; exit 1 ;;
esac
