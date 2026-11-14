#!/usr/bin/env bash
# Maintain and back up Citrix Workspace app for Linux (tarball or RPM install).
# Citrix has no dnf repo and the download sits behind a EULA page, so `update`
# takes a package you downloaded yourself.
set -euo pipefail

ROOT=${CITRIX_ROOT:-/opt/Citrix/ICAClient}
USER_CFG=${CITRIX_USER_CFG:-$HOME/.ICAClient}
APPS=${APPS_DIR:-$HOME/.local/share/applications}
SYS_APPS=${SYS_APPS_DIR:-/usr/share/applications}
BACKUPS=${BACKUP_DIR:-$HOME/Backups/citrix-workspace}
KEEP=${KEEP:-3}
SUDO=${SUDO-sudo}
# Launchers that start wfica; wfica segfaults on Wayland unless EGL is forced to X11.
LAUNCHERS=(wfica.desktop selfservice.desktop)

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

version() { sed -n 's/^DISP_VERSION=//p' "$ROOT/pkginf/Ver.core.linuxx64" 2>/dev/null || true; }
install_type() { rpm -qf "$ROOT/wfica" &>/dev/null && echo rpm || echo tarball; }

cmd_status() {
  echo "version:  $(version || true)"
  [[ -d $ROOT ]] && echo "install:  $(install_type) at $ROOT" || echo "install:  not found at $ROOT"
  for f in "${LAUNCHERS[@]}"; do
    grep -qs 'EGL_PLATFORM=x11' "$APPS/$f" && echo "fix:      $f ok" || echo "fix:      $f MISSING (run: $0 fix)"
  done
  echo "backups:  $BACKUPS"
  ls -1t "$BACKUPS"/*.tar.zst 2>/dev/null | sed 's/^/  /' || echo "  (none)"
}

cmd_backup() {
  [[ -d $ROOT ]] || die "no install at $ROOT"
  mkdir -p "$BACKUPS"
  local out
  out="$BACKUPS/citrix-$(version || echo unknown)-$(date +%Y%m%d-%H%M%S).tar.zst"
  local extra=()
  for f in "${LAUNCHERS[@]}"; do [[ -f $APPS/$f ]] && extra+=("${APPS#/}/$f"); done
  [[ -d $USER_CFG ]] && extra+=("${USER_CFG#/}")
  log "backing up to $out"
  # sudo: some files under the install dir are root-only. Sockets, caches and logs are skipped.
  $SUDO tar -C / --zstd -cf "$out" \
    --exclude='*_socket*' --exclude="${USER_CFG#/}/cache" --exclude="${USER_CFG#/}/logs" \
    --exclude="${USER_CFG#/}/.tmp" --exclude="${USER_CFG#/}/launch.ica" \
    "${ROOT#/}" "${extra[@]}"
  [[ -n $SUDO ]] && $SUDO chown "$(id -u):$(id -g)" "$out"
  tar --zstd -tf "$out" >/dev/null || die "backup $out is unreadable"
  ls -1t "$BACKUPS"/*.tar.zst | tail -n +$((KEEP + 1)) | while read -r old; do
    log "pruning $old"; rm -f -- "$old"
  done
  echo "$out"
}

cmd_restore() {
  local b=${1:-$(ls -1t "$BACKUPS"/*.tar.zst 2>/dev/null | head -1)}
  [[ -f $b ]] || die "no backup found (looked in $BACKUPS)"
  tar --zstd -tf "$b" | grep -q "^${ROOT#/}/" || die "$b does not contain ${ROOT#/}"
  read -rp "Replace $ROOT with $b? [y/N] " ok; [[ $ok == [yY] ]] || die "aborted"
  log "restoring $b"
  # Move the current install aside instead of deleting it, so a bad restore is recoverable.
  [[ -d $ROOT ]] && $SUDO mv "$ROOT" "$ROOT.pre-restore.$$"
  $SUDO tar -C / --zstd -xpf "$b" "${ROOT#/}"
  tar -C / --zstd -xpf "$b" --exclude="${ROOT#/}" --exclude="${ROOT#/}/*" 2>/dev/null || true
  $SUDO rm -rf -- "$ROOT.pre-restore.$$"
  log "restored version $(version)"
}

cmd_fix() {
  mkdir -p "$APPS"
  for f in "${LAUNCHERS[@]}"; do
    [[ -f $SYS_APPS/$f ]] || { echo "skip: $SYS_APPS/$f not found"; continue; }
    sed -E '/^Exec=/{/EGL_PLATFORM=x11/!s#^Exec= *#Exec=env EGL_PLATFORM=x11 #}' "$SYS_APPS/$f" > "$APPS/$f"
    log "$f: $(grep -m1 '^Exec=' "$APPS/$f")"
  done
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" 2>/dev/null || true
}

# Starts wfica against a dead local address with the launcher's environment.
# A crash means the EGL/Wayland bug is back; still running after the timeout means it got past the startup GL probe.
cmd_check() {
  [[ -x $ROOT/wfica ]] || die "no wfica at $ROOT"
  local tmp rc=0; tmp=$(mktemp -d)
  printf '[WFClient]\nVersion=2\n[ApplicationServers]\nTest=\n[Test]\nAddress=127.0.0.1:1\nTransportDriver=TCP/IP\n' > "$tmp/t.ica"
  ICAROOT=$ROOT EGL_PLATFORM=x11 timeout 8 "$ROOT/wfica" "$tmp/t.ica" >"$tmp/log" 2>&1 || rc=$?
  pkill -f "$tmp/t.ica" 2>/dev/null || true
  rm -rf -- "$tmp"
  case $rc in
    124|0|1) log "check passed (wfica started, rc=$rc)" ;;
    *) echo "check FAILED: wfica exited with $rc (139 = segfault)" >&2; return 1 ;;
  esac
}

cmd_update() {
  local pkg=${1:-}
  [[ -f $pkg ]] || die "usage: $0 update <linuxx64-*.tar.gz | ICAClient-*.rpm>"
  [[ $pkg == *.rpm || $pkg == *.tar.gz ]] || die "unknown package type: $pkg"
  local before; before=$(version)
  [[ -d $ROOT ]] && cmd_backup
  case $pkg in
    *.rpm) $SUDO dnf install -y "$pkg" ;;
    *.tar.gz)
      local tmp; tmp=$(mktemp -d)
      tar -C "$tmp" -xzf "$pkg"
      [[ -x $tmp/setupwfc ]] || die "no setupwfc in $pkg"
      log "running Citrix installer (choose install/update when asked)"
      (cd "$tmp" && $SUDO ./setupwfc)
      rm -rf -- "$tmp" ;;
    *) die "unknown package type: $pkg" ;;
  esac
  cmd_fix
  log "version: ${before:-none} -> $(version)"
  cmd_check || { echo "The new version fails the check. Roll back with: $0 restore" >&2; return 1; }
}

usage() {
  cat <<EOF
usage: $(basename "$0") <command>
  status              installed version, Wayland fix state, backups
  backup              back up install + user config + launchers (keeps $KEEP)
  update <pkg>        backup, install tarball/rpm, reapply fix, run check
  restore [backup]    restore a backup (default: newest)
  fix                 (re)create launcher overrides with EGL_PLATFORM=x11
  check               start wfica and verify it doesn't crash at startup
Get packages at https://www.citrix.com/downloads/workspace-app/linux/
EOF
}

case ${1:-} in
  status|backup|restore|fix|check|update) c=$1; shift; "cmd_$c" "$@" ;;
  *) usage; [[ -z ${1:-} ]] || exit 1 ;;
esac
