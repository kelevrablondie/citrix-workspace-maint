# citrix-workspace-maint

Maintenance and backup for Citrix Workspace app for Linux (tarball or RPM install, Fedora/Nobara).

```
./citrix-maint.sh status              # version, Wayland fix state, backups
./citrix-maint.sh backup              # install + ~/.ICAClient + launchers -> ~/Backups/citrix-workspace (keeps 3)
./citrix-maint.sh update <pkg>        # backup, install tarball/rpm, reapply fix, run check
./citrix-maint.sh restore [backup]    # roll back (default: newest backup)
./citrix-maint.sh fix                 # recreate launcher overrides
./citrix-maint.sh check               # verify wfica doesn't crash at startup
./citrix-maint.sh run <cmd> [args]    # run a Citrix tool (relative to the install dir) under XWayland
```

Citrix publishes no dnf repo and the download needs a EULA click, so get the package from
https://www.citrix.com/downloads/workspace-app/linux/ and pass it to `update`.

**Wayland fix:** on a Wayland session `wfica` segfaults in its startup OpenGL probe
(`EglWindow::load_egl` -> `wl_proxy_create_wrapper`), with both NVIDIA and Mesa EGL.
`fix` writes user copies of `wfica.desktop` and `selfservice.desktop` to
`~/.local/share/applications` with `EGL_PLATFORM=x11 GDK_BACKEND=x11` (Nobara exports `EGL_PLATFORM=wayland`
session-wide; the GTK/WebKit login window is also glitchy as a native Wayland client).
System files are untouched. For terminal use: `./citrix-maint.sh run util/storebrowse -l`.

Env overrides: `BACKUP_DIR`, `KEEP`, `CITRIX_ROOT`, `CITRIX_USER_CFG`, `APPS_DIR`, `SYS_APPS_DIR`, `SUDO`.

Tests: `tests/test.sh` (fake install, no sudo); `REAL_CHECK=1 tests/test.sh` also starts the real `wfica`.

## Known issues on this machine (Nobara 44, KDE Wayland, NVIDIA + AMD iGPU, 3x 2560x1440)

Found 2026-11-14 on 26.01 -> 26.08:

- **Login: "Incorrect domain"** - use the FAS store, not `BTC-XA7` (domain auth only, rejects SAML users):
  `./citrix-maint.sh run util/storebrowse -a "https://storefront.btcnet.btc-ag.com/Citrix/BTC-XA7-FAS/discovery"`.
  The internal URL is fine from outside; the client routes it through `cag.btc-ag.com`.
- **Black session screen** - full screen spans all 3 monitors (7680x1440 H.264) and renders black.
  Press **Shift+F2** to switch to a window; that renders fine. No persistent fix found yet
  (toolbar monitor selection / `MultiMonitorPnPEnabled` untested).
- **Browser "Change Citrix Workspace app" crashes `ctxwebhelper`** (`std::out_of_range` in `substr`
  after the gateway returns `{"status":"Success"}`). Citrix bug; detection is recorded anyway.
- **26.01 store window "Cannot connect to server"** - came from an old EL10 `webkit2gtk-4.0` build.
  26.08 uses Fedora's `webkit2gtk4.1`.
- Sessions launched from Firefox inherit Nobara's `EGL_PLATFORM=wayland`
  (`/etc/profile.d/nobara_profile_nvidia.sh`), bypassing the launcher overrides. Currently
  `~/.ICAClient/wfclient.ini [Thinwire3.0]` has `OpenGLEnabled=False` and `HWAccelerationEnabled=False`
  (backup: `wfclient.ini.bak-before-gl`). Possibly unnecessary now that the span was the real cause.
- Missing libs that are safe to ignore: gstreamer-0.10 helpers, `libgssapi.so.3` (Kerberos SSO,
  `heimdal-libs`), `libfuse3.so.3` (drive mapping; Fedora 44 ships `.so.4`), `libpcsclite.so` (smart cards).
