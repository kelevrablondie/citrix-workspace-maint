# Citrix Maintener Script aka citrix-maint

Keep **Citrix Workspace app for Linux** installed, backed up and actually working on a
Wayland desktop with an NVIDIA + AMD hybrid GPU.

Tested with **Citrix Workspace 26.08.0.225** (tarball) on Nobara 44, KDE Plasma (Wayland),
RTX 5070 + Radeon iGPU, three 2560x1440 monitors.

## Quick start

```bash
./citrix-maint.sh fix        # once after installing, and again after any Citrix reinstall
./citrix-maint.sh doctor     # anything wrong? start here
```

| Command | What it does |
|---|---|
| `status` | Citrix version, whether the fixes are in place, list of backups |
| `doctor` | `status` + missing libraries (with notes) + running Citrix daemons + startup check |
| `fix` | Launchers run Citrix under XWayland; `wfclient.ini` graphics tweaks (backup kept once as `wfclient.ini.bak-before-citrix-maint`) |
| `restart` | Stops Citrix background daemons so they pick up new settings or binaries |
| `check` | Starts `wfica` against a dead address and verifies it doesn't crash at startup |
| `backup` | Install dir + `~/.ICAClient` + launchers to `~/Backups/citrix-workspace` (keeps 3, needs sudo) |
| `update <pkg>` | `backup` → Citrix installer → `fix` → `restart` → `check` |
| `restore [file]` | Roll back to a backup (newest by default) |
| `run <cmd>` | Run a Citrix tool under XWayland, e.g. `run util/storebrowse -l` |

Settings via environment: `BACKUP_DIR`, `KEEP`, `CITRIX_ROOT`, `CITRIX_USER_CFG`, `APPS_DIR`,
`SYS_APPS_DIR`, `SUDO`.

## FAQ

### Opening an `.ica` file does nothing; `coredumpctl` shows `wfica` SIGSEGV
`wfica` probes OpenGL at startup. Nobara exports `EGL_PLATFORM=wayland` for the whole session
(`/etc/profile.d/nobara_profile_nvidia.sh`), so EGL takes the Wayland path inside an X11 app and
crashes in `wl_proxy_create_wrapper`, on both NVIDIA and Mesa EGL. Your `.ica` file is fine.
**Fix:** `./citrix-maint.sh fix`. It writes user copies of `wfica.desktop` and `selfservice.desktop`
to `~/.local/share/applications` with `EGL_PLATFORM=x11 GDK_BACKEND=x11`. System files stay untouched.

### How do I keep it up to date?
Citrix has no dnf repo, and the download needs a EULA click. Download the tarball from
<https://www.citrix.com/downloads/workspace-app/linux/>, then:
```bash
./citrix-maint.sh update ~/Downloads/linuxx64-*.tar.gz
```
In the installer: `1` (install), Enter for the default directory, `y` to overwrite, `y` to proceed,
then `3` to quit at the end. If the new version is worse: `./citrix-maint.sh restore`.

### Tarball or RPM?
Tarball. The RHEL RPM tends to miss dependencies on Fedora. The tarball doesn't install
dependencies either, so run `doctor` afterwards to see which libraries are missing.

### `doctor` lists missing libraries. Do I care?
Usually not:
- `libgst*-0.10`: leftover helpers for the old GStreamer 0.10; the 1.0 helpers are used.
- `libgssapi.so.3`: Kerberos single sign-on inside the session. `dnf install heimdal-libs` if you need it.
- `libfuse3.so.3`: mapping your local drives into the session. Fedora 44 ships `.so.4`; don't symlink it.
- `libpcsclite.so` (in the session log): smart cards. `dnf install pcsc-lite-libs` if you use one.

### Adding the store: "Incorrect domain"
The gateway offers two stores. `Main-XE7` as an example name wants a domain password and rejects SAML/FAS logins.
Use the FAS store:
```bash
./citrix-maint.sh run util/storebrowse -a "place the actual FAS discovery here from cr or ica file from your workspace"
```
Remove the other one if it's there (it opens a login window that always fails):
`./citrix-maint.sh run util/storebrowse -d 'place the actual FAS discovery here from cr or ica file from your workspace`

### But `storefront.*` doesn't resolve from outside?
It doesn't need to. The client looks the store up in its service record, sees
`NETWORK_LOCATION_OUTSIDE`, and sends everything through the gateway, for example `cag.domain.com`.

### The login window is glitchy / opens several times / prints `gssapi … SPNEGO` warnings
- Glitchy: the GTK/WebKit login window misbehaves as a native Wayland window. `fix` and `run`
  put it on XWayland. If daemons were started earlier with the old environment: `./citrix-maint.sh restart`.
- Opens several times: one window per configured store. A store that keeps failing (see
  "Incorrect domain") keeps reopening it.
- SPNEGO warnings: harmless. Your machine has no Kerberos ticket for the domain, so the login page
  falls back to its normal form.

### "Cannot connect to server" right after login, before any apps appear
Seen on 26.01, which used an old RHEL 10 `webkit2gtk-4.0` build that kept crashing. 26.08 uses
Fedora's `webkit2gtk4.1`: update. Once it works, the old package can go:
`sudo dnf remove webkit2gtk3 webkit2gtk3-jsc`.

### Browser: "Change Citrix Workspace app" crashes `ctxwebhelper` (SIGABRT)
A Citrix bug. The gateway answers the detection request with `{"status":"Success"}`, and then
`ctxwebhelper` reads a response header that isn't there (`std::out_of_range` in `substr`) and
aborts. Detection is recorded anyway. Easiest: launch from the Workspace app instead of the browser.

### The session starts but the screen is black
Full screen spans **all three monitors** as one 7680x1440 H.264 session, which renders black.
**Press Shift+F2**: the session switches to a window and renders fine. No permanent fix yet.

`fix` also sets `OpenGLEnabled=False` and `HWAccelerationEnabled=False` in `wfclient.ini [Thinwire3.0]`.
Sessions started from Firefox skip the launchers, inherit `EGL_PLATFORM=wayland`, and could
otherwise hit the same EGL problem. To test without the tweaks, delete those two lines (`status`
will then report them missing).

### Where are the logs?
| What | Where |
|---|---|
| Session engine (`wfica`), graphics, monitors | `/var/log/citrix/ICAClient.log` |
| Login, stores, gateway | `~/.ICAClient/logs/AuthManSvr-*.log`, `PrimaryAuthManager-*.log` |
| Crashes | `coredumpctl list wfica ctxwebhelper selfservice` |
| Failure reasons from the server | `grep AuthFailureReason ~/.ICAClient/logs/AuthManSvr-*.log` |

## Tests
```bash
tests/test.sh               # fake install in a temp dir, no sudo, nothing real touched
REAL_CHECK=1 tests/test.sh  # also starts the real wfica
```

## Contributors

- **terra**: owner, tester, and the patient human who kept pasting core dumps until something gave.
  Spotted the multi-monitor span, which was the real cause of the black screen. Pressed Shift+F2 so you don't have to wonder.
- **Claude** (Anthropic): read core dumps, logs and `.ini` files, wrote the script, and was
  told "that's a lie" exactly once. Deserved it.
- **Citrix**: special thanks for turning "show me a remote desktop on a bastion host" into an
  evening of EGL platforms, two WebKit generations, a SAML store vs. a domain store, a URL parser
  that throws on a successful response, and a 7680-pixel black rectangle. Truly a diva. 💅

Plan to spend an afternoon on it the first time.
