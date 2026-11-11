#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 ENEA
# SPDX-FileContributor: Alberto P
# SPDX-License-Identifier: MPL-2.0
#
# afs-setup.sh
#
# Guides the installation and configuration of ONE of the AFS clients on WSL2 (Debian 13):
#   kafs     in-kernel client (modules from wsl-modules-vhdx.sh) + the kafs-client package
#   openafs  OpenAFS client (modules from wsl-modules-vhdx.sh,
#            userland from openafs-backports-podman.sh)
#
# Runs on the distro (uses sudo). Every step that modifies the system prints the exact command and
# asks for confirmation; -y skips the confirmations, -n is a dry run (only prints). It never loads
# kafs and openafs together: starting one stops and unloads the other. The kernel module is NOT
# built here: it must come from the VHDX (kernel= + kernelModules= in .wslconfig).
#
# It never guesses /etc/krb5.conf (realm and KDC): it warns you if it is missing.
#
# Usage:
#   ./afs-setup.sh check                       # read-only diagnosis
#   ./afs-setup.sh status                      # client status (read-only)
#   ./afs-setup.sh kafs    [options]           # install/configure kafs
#   ./afs-setup.sh openafs [options]           # install/configure OpenAFS
#   ./afs-setup.sh switch kafs|openafs [opt.]  # switch from one client to the other
#
# Options:
#   --cell CELL      default cell (required for kafs/openafs/switch), e.g. example.org
#   --debs DIR       openafs .deb files (default: ./openafs-debs, then next to the script)
#   --sparse         (kafs) /afs lists only the cells in use: removes the include of the
#                    generic cellservdb
#   --no-cache       (kafs) do not install cachefilesd
#   -y               do not ask for confirmation
#   -n               dry run: print the commands without running them

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
CELL=""
DEBS=""
SPARSE=0
NOCACHE=0
YES=0
DRY=0

die()  { echo "ERROR: $*" >&2; exit 1; }
log()  { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
ok()   { echo "  [ok]   $*"; }
bad()  { echo "  [FAIL] $*"; }
note() { echo "  [..]   $*"; }

SUDO=sudo; [[ $EUID -eq 0 ]] && SUDO=""

# ---------------------------------------------------------------------------------------------
# Running steps with confirmation
# ---------------------------------------------------------------------------------------------
confirm() {
  ((YES)) && return 0
  # read from the terminal: stdin may be a heredoc (write_file) and would answer "no"
  local a=""
  { exec 3</dev/tty; } 2>/dev/null || { echo "    no terminal to ask on (use -y)"; return 1; }
  read -r -p "    proceed? [y/N] " a <&3 || true
  exec 3<&-
  [[ "$a" == [yY] ]]
}

# run "description" command...   (the command is run with $SUDO if needed: pass it without sudo)
run() {
  local desc="$1"; shift
  log "$desc"
  printf '    $ %s' "${SUDO:+$SUDO }"; printf '%q ' "$@"; echo
  if ((DRY)); then return 0; fi
  confirm || { echo "    skipped"; return 0; }
  # shellcheck disable=SC2086
  $SUDO "$@"
}

# run_soft: like run, but a failure does not abort the script
run_soft() { run "$@" || warn "the step failed (continuing)."; }

# write_file "description" destination mode   (content from stdin)
write_file() {
  local desc="$1" dest="$2" mode="${3:-0644}" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  log "$desc"
  echo "    writing $dest:"; sed 's/^/      | /' "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    echo "    already up to date"; rm -f "$tmp"; return 0
  fi
  if ((DRY)); then rm -f "$tmp"; return 0; fi
  if confirm; then
    if [[ -f "$dest" && ! -f "$dest.wslbak" ]]; then
      $SUDO cp -a "$dest" "$dest.wslbak"; echo "    backup: $dest.wslbak"
    fi
    $SUDO install -D -m "$mode" "$tmp" "$dest"
  else
    echo "    skipped"
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------------------------
# State detection
# ---------------------------------------------------------------------------------------------
have_systemd()  { [[ -d /run/systemd/system ]]; }
mod_available() { modinfo "$1" >/dev/null 2>&1; }
mod_loaded()    { lsmod | awk '{print $1}' | grep -qx "$1"; }
svc_active()    { have_systemd && systemctl is-active --quiet "$1" 2>/dev/null; }
svc_state()     { systemctl is-active "$1" 2>/dev/null || true; }
# version only if the package is really installed (not "rc"/"deinstall" with leftover conffiles)
pkg_ver() {
  local s; s="$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' "$1" 2>/dev/null || true)"
  if [[ -n "$s" && "${s:1:1}" == i ]]; then echo "${s#*|}"; fi
}
afs_mounted()   { grep -qE ' /afs .* afs ' /proc/mounts 2>/dev/null; }

need_wsl() {
  [[ "$KVER" == *-microsoft-standard-WSL2 ]] ||
    die "kernel '$KVER' is not a stock Microsoft WSL2 kernel."
}

krb5_hint() {
  if [[ ! -s /etc/krb5.conf ]] || ! grep -q 'default_realm' /etc/krb5.conf 2>/dev/null; then
    warn "/etc/krb5.conf is missing or has no default_realm: get the realm/KDC from the cell" \
         "administrators (or from the configuration of a host that already uses the cell)" \
         "before running kinit."
  fi
}

cmd_check() {
  local rc=0 m vm p v
  echo "kernel: $KVER"
  if [[ "$KVER" == *-microsoft-standard-WSL2 ]]; then
    ok "stock WSL2 kernel"
  else
    bad "not a stock WSL2 kernel"; rc=1
  fi
  if have_systemd; then
    ok "systemd active"
  else
    bad "systemd not active: enable [boot] systemd=true in /etc/wsl.conf and run wsl --shutdown"
    rc=1
  fi

  echo "available modules (is the VHDX with kernelModules= active?):"
  for m in kafs rxrpc openafs; do
    if mod_available "$m"; then
      vm="$(modinfo -F vermagic "$m" 2>/dev/null | awk '{print $1}')"
      if [[ "$vm" == "$KVER" ]]; then
        ok "$m.ko found (vermagic matches the kernel)"
      else
        bad "$m.ko has vermagic '$vm' != running kernel '$KVER':" \
            "VHDX not updated after wsl --update?"
        rc=1
      fi
    else
      note "$m.ko not found"
    fi
  done
  if ! mod_available kafs && ! mod_available openafs; then
    bad "no AFS module: build the VHDX with ./wsl-modules-vhdx.sh, set kernel= and" \
        "kernelModules= in .wslconfig and run wsl --shutdown (see README)"
    rc=1
  fi

  echo "loaded modules / mounts:"
  for m in kafs rxrpc openafs; do
    if mod_loaded "$m"; then ok "$m loaded"; else note "$m not loaded"; fi
  done
  if grep -qw afs /proc/filesystems; then
    ok "filesystem 'afs' registered"
  else
    note "filesystem 'afs' not registered"
  fi
  if afs_mounted; then ok "/afs mounted"; else note "/afs not mounted"; fi
  if mod_loaded kafs && mod_loaded openafs; then
    bad "kafs AND openafs are loaded together: unload one"; rc=1
  fi

  echo "packages and configuration:"
  for p in kafs-client keyutils cachefilesd krb5-user \
           openafs-client openafs-krb5 openafs-modules-dkms; do
    v="$(pkg_ver "$p")"
    if [[ -n "$v" ]]; then note "$p $v"; else note "$p not installed"; fi
  done
  if [[ -n "$(pkg_ver openafs-modules-dkms)" ]]; then
    warn "openafs-modules-dkms is installed: it is not needed (the module comes from the VHDX)" \
         "and would fail without headers."
  fi
  local kconf=(/etc/kafs/client.d/*.conf)
  if [[ -e "${kconf[0]}" ]]; then
    note "kafs: ${kconf[*]}"
  else
    note "kafs: no file in /etc/kafs/client.d"
  fi
  if [[ -f /etc/openafs/ThisCell ]]; then
    note "openafs ThisCell: $(cat /etc/openafs/ThisCell)"
  else
    note "openafs: ThisCell missing"
  fi
  if [[ -r /proc/net/afs/rootcell ]]; then
    note "kafs rootcell (kernel): '$(cat /proc/net/afs/rootcell 2>/dev/null)'"
  fi
  krb5_hint
  return $rc
}

cmd_status() {
  local kmod omod kpkg opkg
  kpkg="$(pkg_ver kafs-client)"; opkg="$(pkg_ver openafs-client)"
  kmod="$(mod_available kafs && echo available || echo missing)"
  kmod+=", $(mod_loaded kafs && echo LOADED || echo not loaded)"
  omod="$(mod_available openafs && echo available || echo missing)"
  omod+=", $(mod_loaded openafs && echo LOADED || echo not loaded)"
  echo "kafs    : module $kmod; kafs-client ${kpkg:-not installed}"
  echo "          services: kafs-client=$(svc_state kafs-client) afs.mount=$(svc_state afs.mount)"
  echo "openafs : module $omod; openafs-client ${opkg:-not installed}"
  echo "          service: openafs-client=$(svc_state openafs-client)"
  echo "/afs    : $(afs_mounted && echo mounted || echo not mounted)"
  if [[ -r /proc/net/afs/cells ]]; then
    echo "kafs cells:"; head -8 /proc/net/afs/cells | sed 's/^/  /'
  fi
  if command -v tokens >/dev/null; then
    echo "openafs tokens:"; { tokens 2>&1 | sed 's/^/  /' | head -5; } || true
  fi
  if command -v keyctl >/dev/null; then
    echo "rxrpc keys in the session keyring:"
    keyctl list @s 2>/dev/null | grep -i rxrpc | sed 's/^/  /' || true
  fi
}

# ---------------------------------------------------------------------------------------------
# Stopping the other client
# ---------------------------------------------------------------------------------------------
stop_kafs() {
  if have_systemd && { svc_active afs.mount || svc_active kafs-client; }; then
    run_soft "Stopping and disabling kafs (afs.mount, kafs-client)" \
             systemctl disable --now afs.mount kafs-client
  fi
  if afs_mounted && ! svc_active openafs-client; then run_soft "Unmounting /afs" umount /afs; fi
  if mod_loaded kafs; then run_soft "Unloading the kafs module" modprobe -r kafs; fi
}

stop_openafs() {
  if svc_active openafs-client; then
    run_soft "Stopping and disabling openafs-client" systemctl disable --now openafs-client
  fi
  if mod_loaded openafs; then run_soft "Unloading the openafs module" modprobe -r openafs; fi
}

# ---------------------------------------------------------------------------------------------
# kafs
# ---------------------------------------------------------------------------------------------
setup_kafs() {
  local include_re='^[[:space:]]*include[[:space:]]+/usr/share/kafs/cellservdb.conf'
  need_wsl
  mod_available kafs ||
    die "kafs module not available: build the VHDX with ./wsl-modules-vhdx.sh and enable it" \
        "with kernel= + kernelModules= (see README)."
  have_systemd ||
    die "systemd not active: afs.mount and kafs-client are systemd units" \
        "(enable [boot] systemd=true in /etc/wsl.conf)."

  stop_openafs

  local pkgs=(kafs-client keyutils krb5-user)
  ((NOCACHE)) || pkgs+=(cachefilesd)
  run "Installing packages: ${pkgs[*]}" apt-get install -y "${pkgs[@]}"

  write_file "Default cell for kafs" "/etc/kafs/client.d/${CELL%%.*}.conf" 0644 <<EOF
[defaults]
thiscell = $CELL
EOF

  if ((SPARSE)); then
    if grep -qE "$include_re" /etc/kafs/client.conf 2>/dev/null; then
      if [[ ! -f /etc/kafs/client.conf.wslbak ]]; then
        run "Backing up /etc/kafs/client.conf" \
            cp -a /etc/kafs/client.conf /etc/kafs/client.conf.wslbak
      fi
      run "Sparse /afs: removing the generic cellservdb include (cells found via AFSDB/DNS)" \
          sed -i 's|^\([[:space:]]*include[[:space:]]\+/usr/share/kafs/cellservdb.conf\)|#\1|' \
          /etc/kafs/client.conf
      note "with --sparse '$CELL' is resolved via DNS (AFSDB); if DNS does not provide it," \
           "add a [cells] block in client.d."
    else
      note "generic cellservdb include already absent: /afs is already sparse."
    fi
  fi

  run "Loading the configuration into the kernel and starting kafs-client" \
      systemctl enable --now kafs-client
  run "Mounting the dynamic root on /afs" systemctl enable --now afs.mount
  if command -v kafs-check-config >/dev/null && ((! DRY)); then
    log "kafs-check-config"; kafs-check-config || warn "kafs-check-config reported problems."
  fi
  krb5_hint
  cat <<EOF

Next steps (manual):
  kinit user@REALM
  aklog-kafs $CELL
  keyctl show @s            # an rxrpc key must appear
  ls /afs/$CELL
  cat /proc/net/afs/cells
EOF
}

# ---------------------------------------------------------------------------------------------
# openafs
# ---------------------------------------------------------------------------------------------
find_debs() {
  local d="$DEBS"
  if [[ -z "$d" ]]; then
    for d in "$PWD/openafs-debs" "$SCRIPT_DIR/openafs-debs"; do [[ -d "$d" ]] && break; done
  fi
  [[ -d "$d" ]] ||
    die ".deb directory not found: run ./openafs-backports-podman.sh or use --debs DIR."
  DEBS="$(cd "$d" && pwd)"
}

setup_openafs() {
  need_wsl
  mod_available openafs ||
    die "openafs module not available: build the VHDX with ./wsl-modules-vhdx.sh --debs <dir>" \
        "and enable it with kernel= + kernelModules= (see README)."
  have_systemd ||
    die "systemd not active: openafs-client is a systemd unit" \
        "(enable [boot] systemd=true in /etc/wsl.conf)."
  find_debs

  # userland only: the module comes from the VHDX, so no -dkms, -source, -dev, dbgsym
  local files=() pkgs=() f
  shopt -s nullglob
  for f in "$DEBS"/openafs-client_*.deb "$DEBS"/openafs-krb5_*.deb "$DEBS"/libafsauthent*.deb \
           "$DEBS"/libafsrpc*.deb "$DEBS"/libkopenafs*.deb; do
    case "$f" in *-dev_*|*dbgsym*|*dkms*|*modules-source*) continue ;; esac
    files+=("$f"); pkgs+=("$(dpkg-deb -f "$f" Package)")
  done
  shopt -u nullglob
  ((${#files[@]} >= 2)) || die "too few runtime .deb files in $DEBS."
  if [[ -f "$DEBS/BUILD-INFO" ]]; then
    log "BUILD-INFO of the .deb files:"; sed 's/^/    /' "$DEBS/BUILD-INFO"
  fi

  stop_kafs

  # the backport has version ~bpo13+1, so it may be LOWER than an already installed 1.8.17~pre1-1
  local downgrade=0 p v new
  for f in "${files[@]}"; do
    p="$(dpkg-deb -f "$f" Package)"; new="$(dpkg-deb -f "$f" Version)"; v="$(pkg_ver "$p")"
    if [[ -n "$v" ]] && dpkg --compare-versions "$v" gt "$new"; then downgrade=1; fi
  done
  local held
  held="$(apt-mark showhold 2>/dev/null | grep -E '^(openafs|libafs|libkopenafs)' |
          tr '\n' ' ' || true)"
  if [[ -n "$held" ]]; then
    # shellcheck disable=SC2086  # $held is a space-separated package list: splitting is intended
    run_soft "Removing the hold from the OpenAFS packages (${held% })" apt-mark unhold $held
  fi

  local aptargs=(install -y)
  if ((downgrade)); then
    aptargs+=(--allow-downgrades)
    note "installed versions are higher than the backport: using --allow-downgrades"
  fi
  run "Installing the OpenAFS userland from the local .deb files (+ krb5-user)" \
      env DEBIAN_FRONTEND=noninteractive apt-get "${aptargs[@]}" "${files[@]}" krb5-user
  run_soft "Stopping the service started by the postinst (configure first)" \
           systemctl stop openafs-client
  run_soft "Putting the OpenAFS packages on hold" apt-mark hold "${pkgs[@]}"

  write_file "Default cell for OpenAFS" /etc/openafs/ThisCell 0644 <<< "$CELL"
  write_file "Client options" /etc/openafs/afs.conf.client 0644 <<'EOF'
AFS_CLIENT=true
AFS_AFSDB=true
AFS_CRYPT=true
AFS_DYNROOT=Sparse
AFS_FAKESTAT=true
EOF
  write_file "Disk cache (500 MB)" /etc/openafs/cacheinfo 0644 \
             <<< "/afs:/var/cache/openafs:500000"

  run "Starting openafs-client" systemctl enable --now openafs-client
  krb5_hint
  cat <<EOF

Next steps (manual):
  kinit user@REALM
  aklog -d
  tokens
  ls /afs/$CELL
EOF
}

# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------
usage() { sed -n '/^# [a-z-]*\.sh$/,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

[[ $# -ge 1 ]] || { usage; exit 1; }
CMD="$1"; shift
TARGET=""
if [[ "$CMD" == switch ]]; then TARGET="${1:-}"; shift || true; fi
while (($#)); do
  case "$1" in
    --cell)     CELL="${2:?}"; shift ;;
    --debs)     DEBS="${2:?}"; shift ;;
    --sparse)   SPARSE=1 ;;
    --no-cache) NOCACHE=1 ;;
    -y)         YES=1 ;;
    -n)         DRY=1 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

case "$CMD" in
  kafs|openafs|switch)
    [[ -n "$CELL" ]] || die "specify the cell with --cell (e.g. --cell example.org)." ;;
esac

case "$CMD" in
  check)     cmd_check ;;
  status)    cmd_status ;;
  kafs)      setup_kafs ;;
  openafs)   setup_openafs ;;
  switch)
    case "$TARGET" in
      kafs)    setup_kafs ;;
      openafs) setup_openafs ;;
      *) die "switch requires 'kafs' or 'openafs'." ;;
    esac ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
