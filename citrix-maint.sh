#!/usr/bin/env bash
# citrix-maint: maintain, fix and back up Citrix Workspace app for Linux (tarball or RPM install).
# Citrix has no dnf repo and the download sits behind a EULA page, so `update`
# takes a package you downloaded yourself.
set -euo pipefail

SCRIPT_VERSION=1.0.0
TESTED_CITRIX=26.08.0.225

ROOT=${CITRIX_ROOT:-/opt/Citrix/ICAClient}
USER_CFG=${CITRIX_USER_CFG:-$HOME/.ICAClient}
APPS=${APPS_DIR:-$HOME/.local/share/applications}
SYS_APPS=${SYS_APPS_DIR:-/usr/share/applications}
BACKUPS=${BACKUP_DIR:-$HOME/Backups/citrix-workspace}
KEEP=${KEEP:-3}
SUDO=${SUDO-sudo}

# Launchers that start wfica and the Citrix UI. On Wayland wfica segfaults in its EGL probe
# (Nobara exports EGL_PLATFORM=wayland session-wide) and the GTK/WebKit windows misbehave natively,
# so both run under XWayland.
LAUNCHERS=(wfica.desktop selfservice.desktop)
CITRIX_ENV=(EGL_PLATFORM=x11 GDK_BACKEND=x11)
# wfclient.ini "section|key|value". Sessions started from a browser bypass the launchers and
# inherit EGL_PLATFORM=wayland; software rendering sidesteps the EGL path whoever starts wfica.
INI_TWEAKS=("Thinwire3.0|OpenGLEnabled|False" "Thinwire3.0|HWAccelerationEnabled|False")
# User daemons that keep their environment/binary until restarted.
DAEMONS=(AuthManagerDaemon ServiceRecord UtilDaemon selfservice)

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

version() { sed -n 's/^DISP_VERSION=//p' "$ROOT/pkginf/Ver.core.linuxx64" 2>/dev/null || true; }
install_type() { rpm -qf "$ROOT/wfica" &>/dev/null && echo rpm || echo tarball; }

# ini_get FILE SECTION KEY -> value or empty
ini_get() {
  awk -v s="[$2]" -v k="$3" '/^\[/{in_s=($0==s); next} in_s && $0 ~ "^"k" *=" {sub(/^[^=]*= */,""); print; exit}' "$1" 2>/dev/null
}

# ini_set FILE SECTION KEY VALUE: replace the key in its section, or add it, creating the section if needed.
ini_set() {
  local f=$1 tmp; tmp=$(mktemp)
  [[ -f $f ]] || : > "$f"
  awk -v s="[$2]" -v k="$3" -v v="$4" '
    $0==s { print; in_s=1; next }
    /^\[/ { if (in_s && !done) { print k"="v; done=1 } in_s=0 }
    in_s && $0 ~ "^"k" *=" { if (!done) { print k"="v; done=1 } next }
    { print }
    END { if (!done) { if (!in_s) print s; print k"="v } }' "$f" > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"   # cat keeps the file's owner and mode
}

cmd_status() {
  echo "citrix:   $(version || true)  (script $SCRIPT_VERSION, tested with $TESTED_CITRIX)"
  [[ -d $ROOT ]] && echo "install:  $(install_type) at $ROOT" || echo "install:  not found at $ROOT"
  for f in "${LAUNCHERS[@]}"; do
    grep -qs "Exec=env ${CITRIX_ENV[*]} " "$APPS/$f" && echo "launcher: $f ok" || echo "launcher: $f MISSING (run: fix)"
  done
  local t sec key val
  for t in "${INI_TWEAKS[@]}"; do
    IFS='|' read -r sec key val <<<"$t"
    [[ $(ini_get "$USER_CFG/wfclient.ini" "$sec" "$key") == "$val" ]] \
      && echo "ini:      $key=$val ok" || echo "ini:      $key MISSING (run: fix)"
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
  # sudo: some files under the install dir are root-only. Sockets, caches, logs and session tickets are skipped.
  $SUDO tar -C / --zstd -cf "$out" --warning=no-file-ignored \
    --exclude='*_socket*' --exclude="${USER_CFG#/}/UDS" --exclude="${USER_CFG#/}/cache" \
    --exclude="${USER_CFG#/}/logs" --exclude="${USER_CFG#/}/.tmp" --exclude="${USER_CFG#/}/launch.ica" \
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
    sed -E "s#^Exec= *(env [A-Z_]+=[^ ]+ +)*#Exec=env ${CITRIX_ENV[*]} #" "$SYS_APPS/$f" > "$APPS/$f"
    log "$f: $(grep -m1 '^Exec=' "$APPS/$f")"
  done
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" 2>/dev/null || true

  local ini=$USER_CFG/wfclient.ini t sec key val
  mkdir -p "$USER_CFG"
  [[ -f $ini ]] && cp -n "$ini" "$ini.bak-before-citrix-maint"
  for t in "${INI_TWEAKS[@]}"; do
    IFS='|' read -r sec key val <<<"$t"
    ini_set "$ini" "$sec" "$key" "$val"
    log "wfclient.ini [$sec] $key=$val"
  done
}

cmd_restart() {
  local d stopped=0
  for d in "${DAEMONS[@]}"; do
    pkill -u "$(id -u)" -f "^$ROOT/$d( |$)" && { log "stopped $d"; stopped=1; } || true
  done
  ((stopped)) && log "Citrix starts them again on demand" || log "no Citrix daemons running"
  pgrep -u "$(id -u)" -x wfica >/dev/null && echo "note: a session (wfica) is still open; it keeps its old settings until you reconnect" || true
}

# Starts wfica against a dead local address with the launcher's environment.
# A crash means the EGL/Wayland bug is back; still running after the timeout means it got past the startup GL probe.
cmd_check() {
  [[ -x $ROOT/wfica ]] || die "no wfica at $ROOT"
  local tmp rc=0; tmp=$(mktemp -d)
  printf '[WFClient]\nVersion=2\n[ApplicationServers]\nTest=\n[Test]\nAddress=127.0.0.1:1\nTransportDriver=TCP/IP\n' > "$tmp/t.ica"
  env ICAROOT="$ROOT" "${CITRIX_ENV[@]}" timeout 8 "$ROOT/wfica" "$tmp/t.ica" >"$tmp/log" 2>&1 || rc=$?
  pkill -f "$tmp/t.ica" 2>/dev/null || true
  rm -rf -- "$tmp"
  case $rc in
    124|0|1) log "check passed (wfica started, rc=$rc)" ;;
    *) echo "check FAILED: wfica exited with $rc (139 = segfault)" >&2; return 1 ;;
  esac
}

cmd_doctor() {
  cmd_status
  echo; log "missing libraries"
  local libs
  # find/ldd fail on root-only files; a partial list is still useful.
  libs=$(find "$ROOT" -type f -perm -u+x -exec ldd {} + 2>/dev/null | awk '/not found/{print $1}' | sort -u || true)
  if [[ -z $libs ]]; then echo "  none"; else
    while read -r l; do
      case $l in
        libgst*-0.10*)     echo "  $l  (ignore: legacy GStreamer 0.10 helpers)" ;;
        libgssapi.so.3)    echo "  $l  (Kerberos SSO in session only: dnf install heimdal-libs)" ;;
        libfuse3.so.3)     echo "  $l  (client drive mapping only; Fedora 44 ships .so.4)" ;;
        *)                 echo "  $l" ;;
      esac
    done <<<"$libs"
  fi
  echo; log "running Citrix daemons"
  pgrep -u "$(id -u)" -a -f "^$ROOT/" | sed "s#$ROOT/##" | cut -c1-80 | sed 's/^/  /' || echo "  none"
  echo; cmd_check
}

cmd_update() {
  local pkg=${1:-}
  [[ -f $pkg ]] || die "usage: $(basename "$0") update <linuxx64-*.tar.gz | ICAClient-*.rpm>"
  [[ $pkg == *.rpm || $pkg == *.tar.gz ]] || die "unknown package type: $pkg"
  local before; before=$(version)
  [[ -d $ROOT ]] && cmd_backup
  case $pkg in
    *.rpm) $SUDO dnf install -y "$pkg" ;;
    *.tar.gz)
      local tmp; tmp=$(mktemp -d)
      tar -C "$tmp" -xzf "$pkg"
      [[ -x $tmp/setupwfc ]] || die "no setupwfc in $pkg"
      log "running Citrix installer: choose 1 (install), confirm the overwrite with y, quit with 3 at the end"
      (cd "$tmp" && $SUDO ./setupwfc)
      rm -rf -- "$tmp" ;;
  esac
  cmd_fix
  cmd_restart
  log "version: ${before:-none} -> $(version)"
  cmd_check || { echo "The new version fails the check. Roll back with: $(basename "$0") restore" >&2; return 1; }
}

usage() {
  cat <<EOF
citrix-maint $SCRIPT_VERSION - keep Citrix Workspace app for Linux working (tested with $TESTED_CITRIX)

usage: $(basename "$0") <command>
  status              version, fix state, backups
  doctor              status + missing libraries + running daemons + startup check
  fix                 launchers with ${CITRIX_ENV[*]}, wfclient.ini graphics tweaks
  restart             stop Citrix daemons so they pick up new settings/binaries
  check               start wfica and verify it doesn't crash at startup
  backup              back up install + ~/.ICAClient + launchers (keeps $KEEP)
  update <pkg>        backup, install tarball/rpm, fix, restart, check
  restore [backup]    restore a backup (default: newest)
  run <cmd> [args]    run a Citrix tool under XWayland, e.g. run util/storebrowse -l
  version             print script version

Packages: https://www.citrix.com/downloads/workspace-app/linux/
EOF
}

case ${1:-} in
  status|backup|restore|fix|check|update|doctor|restart) c=$1; shift; "cmd_$c" "$@" ;;
  run) shift; [[ -n ${1:-} ]] || die "usage: $(basename "$0") run <cmd> [args]"
       c=$1; shift; [[ $c == /* ]] || c=$ROOT/$c; exec env "${CITRIX_ENV[@]}" "$c" "$@" ;;
  version|--version|-V) echo "citrix-maint $SCRIPT_VERSION (tested with Citrix Workspace $TESTED_CITRIX)" ;;
  help|-h|--help|"") usage ;;
  *) usage >&2; exit 1 ;;
esac
