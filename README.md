# Superhuman Linux Packager

Unofficial script to repackage the official Superhuman Windows Electron installer into Linux packages.

The script downloads Superhuman from the official site, extracts the Electron app, patches the Linux login flow, bundles it with a Linux Electron runtime, and creates Linux package formats.

## Quick start

```bash
./package-superhuman-linux.sh --formats tar
```

Output will be written to:

```text
./dist-superhuman/
```

## Supported formats

- `tar` — portable `.tar.zst`
- `arch` — Arch Linux `.pkg.tar.zst`, requires `makepkg`
- `deb` — Debian/Ubuntu `.deb`, requires `dpkg-deb`
- `rpm` — Fedora/RHEL/openSUSE `.rpm`, requires `rpmbuild`
- `appimage` — AppImage, requires `appimagetool` or `--download-appimagetool`

## Useful options

```text
--formats LIST              tar, deb, rpm, arch, appimage, or all
--out DIR                   output directory
--work DIR                  custom work directory
--keep-work                 keep temporary work files for debugging
--force                     overwrite output directory
--download-url URL          use a specific Superhuman.exe URL or local file:// path
--electron-version VERSION  Linux Electron version, default 34.5.8
```

See all options:

```bash
./package-superhuman-linux.sh --help
```

## Using a local installer

If you already have `Superhuman.exe`:

```bash
./package-superhuman-linux.sh \
  --formats tar,arch \
  --download-url file:///absolute/path/to/Superhuman.exe
```

## Installing the portable tarball

Extract it:

```bash
tar --zstd -xf Superhuman-linux-x64-*.tar.zst
cd Superhuman-linux-x64
./superhuman
```

Install desktop launcher and protocol handler:

```bash
./install-desktop-entry.sh
```

Then search for **Superhuman** in your launcher.

## Runtime environment variables

Force XWayland instead of native Wayland:

```bash
SUPERHUMAN_USE_X11=1 ./superhuman
```

Disable Chromium sandbox if your system needs it:

```bash
SUPERHUMAN_NO_SANDBOX=1 ./superhuman
```

## Notes

- This is unofficial and not supported by Superhuman.
- The script currently supports x86_64 Linux only.
- Superhuman may change their Electron app internals. If that happens, the script should fail loudly during patching instead of producing a silently broken package.
- Native app auto-updates may not behave like an official Linux build.
- If something doesn't work as expected, just ask your agent to fix it.
