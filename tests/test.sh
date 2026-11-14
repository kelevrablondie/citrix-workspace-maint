#!/usr/bin/env bash
# Exercises citrix-maint.sh against a fake install in a temp dir (no sudo, nothing real touched).
# `check` runs against the real install only when it exists and REAL_CHECK=1.
set -euo pipefail
S="$(cd "$(dirname "$0")/.." && pwd)/citrix-maint.sh"
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

export CITRIX_ROOT=$T/opt/Citrix/ICAClient CITRIX_USER_CFG=$T/home/.ICAClient \
  APPS_DIR=$T/home/apps SYS_APPS_DIR=$T/usr/apps BACKUP_DIR=$T/backups SUDO="" KEEP=2

mkdir -p "$CITRIX_ROOT/pkginf" "$CITRIX_USER_CFG/cache" "$SYS_APPS_DIR"
echo DISP_VERSION=26.01.0 > "$CITRIX_ROOT/pkginf/Ver.core.linuxx64"
echo original > "$CITRIX_ROOT/payload"
echo cfg > "$CITRIX_USER_CFG/wfclient.ini"; echo junk > "$CITRIX_USER_CFG/cache/x"
printf '[Desktop Entry]\nName=W\nExec=/opt/x/adapter %%f\n' > "$SYS_APPS_DIR/wfica.desktop"
printf '[Desktop Entry]\nName=S\nExec= /opt/x/selfservice --icaroot /opt/x\n' > "$SYS_APPS_DIR/selfservice.desktop"

# fix: adds env once, idempotent
"$S" fix >/dev/null; "$S" fix >/dev/null
grep -qx 'Exec=env EGL_PLATFORM=x11 /opt/x/adapter %f' "$APPS_DIR/wfica.desktop" || fail "fix wfica"
grep -qx 'Exec=env EGL_PLATFORM=x11 /opt/x/selfservice --icaroot /opt/x' "$APPS_DIR/selfservice.desktop" || fail "fix selfservice"
[[ $(grep -c EGL_PLATFORM "$APPS_DIR/wfica.desktop") == 1 ]] || fail "fix not idempotent"
ok fix

# status
st=$("$S" status)
grep -q 'version:  26.01.0' <<<"$st" || fail "status version"
grep -q 'wfica.desktop ok' <<<"$st" || fail "status fix"
ok status

# backup: contents, excludes, pruning to KEEP
b1=$("$S" backup | tail -1); sleep 1
list=$(tar --zstd -tf "$b1")
grep -q "${CITRIX_ROOT#/}/payload" <<<"$list" || fail "backup missing install"
grep -q "wfclient.ini" <<<"$list" || fail "backup missing user cfg"
grep -q "apps/wfica.desktop" <<<"$list" || fail "backup missing launcher"
grep -q "cache/x" <<<"$list" && fail "backup includes cache"
"$S" backup >/dev/null; sleep 1; "$S" backup >/dev/null
[[ $(ls "$BACKUP_DIR" | wc -l) == 2 ]] || fail "prune: $(ls "$BACKUP_DIR")"
[[ -f $b1 ]] && fail "prune kept oldest"
ok backup

# restore: newest backup brings back install + config
echo broken > "$CITRIX_ROOT/payload"; rm "$CITRIX_USER_CFG/wfclient.ini"; touch "$CITRIX_ROOT/stray"
echo y | "$S" restore >/dev/null
[[ $(cat "$CITRIX_ROOT/payload") == original ]] || fail "restore payload"
[[ -f $CITRIX_ROOT/stray ]] && fail "restore left stray file"
[[ -f $CITRIX_USER_CFG/wfclient.ini ]] || fail "restore user cfg"
ls "$CITRIX_ROOT/.." | grep -q pre-restore && fail "restore left aside copy"
ok restore

# restore: declined prompt changes nothing
echo broken > "$CITRIX_ROOT/payload"
echo n | "$S" restore >/dev/null 2>&1 && fail "restore should abort"
[[ $(cat "$CITRIX_ROOT/payload") == broken ]] || fail "abort changed files"
ok "restore abort"

# update: rejects bad input before touching anything
"$S" update >/dev/null 2>&1 && fail "update without pkg"
touch "$T/x.zip"; "$S" update "$T/x.zip" >/dev/null 2>&1 && fail "update bad type"
ok "update input checks"

if [[ ${REAL_CHECK:-0} == 1 && -x /opt/Citrix/ICAClient/wfica ]]; then
  CITRIX_ROOT=/opt/Citrix/ICAClient "$S" check >/dev/null || fail "real check"
  ok "check (real wfica)"
fi
echo "all tests passed"
