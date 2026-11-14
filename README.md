# citrix-workspace-maint

Maintenance and backup for Citrix Workspace app for Linux (tarball or RPM install, Fedora/Nobara).

```
./citrix-maint.sh status              # version, Wayland fix state, backups
./citrix-maint.sh backup              # install + ~/.ICAClient + launchers -> ~/Backups/citrix-workspace (keeps 3)
./citrix-maint.sh update <pkg>        # backup, install tarball/rpm, reapply fix, run check
./citrix-maint.sh restore [backup]    # roll back (default: newest backup)
./citrix-maint.sh fix                 # recreate launcher overrides
./citrix-maint.sh check               # verify wfica doesn't crash at startup
```

Citrix publishes no dnf repo and the download needs a EULA click, so get the package from
https://www.citrix.com/downloads/workspace-app/linux/ and pass it to `update`.

**Wayland fix:** on a Wayland session `wfica` segfaults in its startup OpenGL probe
(`EglWindow::load_egl` -> `wl_proxy_create_wrapper`), with both NVIDIA and Mesa EGL.
`fix` writes user copies of `wfica.desktop` and `selfservice.desktop` to
`~/.local/share/applications` with `EGL_PLATFORM=x11`. System files are untouched.

Env overrides: `BACKUP_DIR`, `KEEP`, `CITRIX_ROOT`, `CITRIX_USER_CFG`, `APPS_DIR`, `SYS_APPS_DIR`, `SUDO`.

Tests: `tests/test.sh` (fake install, no sudo); `REAL_CHECK=1 tests/test.sh` also starts the real `wfica`.
