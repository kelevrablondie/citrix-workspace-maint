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
grep -qx 'Exec=env EGL_PLATFORM=x11 GDK_BACKEND=x11 /opt/x/adapter %f' "$APPS_DIR/wfica.desktop" || fail "fix wfica"
grep -qx 'Exec=env EGL_PLATFORM=x11 GDK_BACKEND=x11 /opt/x/selfservice --icaroot /opt/x' "$APPS_DIR/selfservice.desktop" || fail "fix selfservice"
[[ $(grep -c EGL_PLATFORM "$APPS_DIR/wfica.desktop") == 1 ]] || fail "fix not idempotent"
# fix: upgrades an older override (EGL only) instead of stacking env prefixes
sed -i 's#^Exec=.*#Exec=env EGL_PLATFORM=x11 /opt/x/adapter %f#' "$SYS_APPS_DIR/wfica.desktop"
"$S" fix >/dev/null
grep -qx 'Exec=env EGL_PLATFORM=x11 GDK_BACKEND=x11 /opt/x/adapter %f' "$APPS_DIR/wfica.desktop" || fail "fix upgrade: $(grep Exec "$APPS_DIR/wfica.desktop")"
ok fix

# fix: wfclient.ini tweaks - replace existing key, add missing key, keep other content, idempotent, backup once
printf '[WFClient]\nVersion=2\n[Thinwire3.0]\nOpenGLEnabled=True\nDesiredColor = 15\n[Other]\nX=1\n' > "$CITRIX_USER_CFG/wfclient.ini"
orig=$(cat "$CITRIX_USER_CFG/wfclient.ini"); rm -f "$CITRIX_USER_CFG/wfclient.ini.bak-before-citrix-maint"
"$S" fix >/dev/null; "$S" fix >/dev/null
ini=$(cat "$CITRIX_USER_CFG/wfclient.ini")
[[ $(sed -n '/^\[Thinwire3.0\]/,/^\[Other\]/p' <<<"$ini" | grep -c '^OpenGLEnabled=False$') == 1 ]] || fail "ini replace: $ini"
[[ $(grep -c '^HWAccelerationEnabled=False$' <<<"$ini") == 1 ]] || fail "ini add: $ini"
sed -n '/^\[Thinwire3.0\]/,/^\[Other\]/p' <<<"$ini" | grep -q '^HWAccelerationEnabled' || fail "ini key in wrong section: $ini"
grep -q '^DesiredColor = 15$' <<<"$ini" && grep -q '^X=1$' <<<"$ini" && grep -q '^Version=2$' <<<"$ini" || fail "ini lost content"
grep -q 'OpenGLEnabled=True' <<<"$ini" && fail "ini old value kept"
[[ $(cat "$CITRIX_USER_CFG/wfclient.ini.bak-before-citrix-maint") == "$orig" ]] || fail "ini backup"
# missing section and missing file
printf '[WFClient]\nVersion=2\n' > "$CITRIX_USER_CFG/wfclient.ini"; "$S" fix >/dev/null
grep -q '^\[Thinwire3.0\]$' "$CITRIX_USER_CFG/wfclient.ini" && grep -q '^OpenGLEnabled=False$' "$CITRIX_USER_CFG/wfclient.ini" || fail "ini new section"
rm "$CITRIX_USER_CFG/wfclient.ini"; "$S" fix >/dev/null
[[ $(grep -c . "$CITRIX_USER_CFG/wfclient.ini") == 3 ]] || fail "ini new file: $(cat "$CITRIX_USER_CFG/wfclient.ini")"
ok "fix ini"

# run: resolves relative paths under CITRIX_ROOT and passes the env
printf '#!/bin/sh\necho "$EGL_PLATFORM $GDK_BACKEND $1"\n' > "$CITRIX_ROOT/tool"; chmod +x "$CITRIX_ROOT/tool"
[[ $("$S" run tool hi) == "x11 x11 hi" ]] || fail "run"
ok run

# status
st=$("$S" status)
grep -q 'citrix:   26.01.0 ' <<<"$st" || fail "status version"
grep -q 'wfica.desktop ok' <<<"$st" || fail "status fix"
grep -q 'OpenGLEnabled=False ok' <<<"$st" || fail "status ini"
ok status

# restart with nothing running, help, version, unknown command
[[ $("$S" restart) == *"no Citrix daemons running"* ]] || fail "restart"
"$S" help | grep -q 'doctor' || fail "help"
"$S" version | grep -q '^citrix-maint 1\.' || fail "version"
"$S" bogus >/dev/null 2>&1 && fail "unknown command should fail"
ok "restart/help/version"

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
