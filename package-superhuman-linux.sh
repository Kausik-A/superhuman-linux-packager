#!/usr/bin/env bash
# Repackage Superhuman's Windows Electron installer into Linux packages.
#
# What it does:
#   1. Discovers the Windows installer URL from https://superhuman.com/download.
#   2. Downloads Superhuman.exe.
#   3. Extracts the NSIS installer and the contained app-64.7z.
#   4. Extracts resources/app.asar, applies Linux compatibility patches.
#   5. Combines the patched app.asar with a Linux Electron runtime.
#   6. Builds one or more Linux package formats.
#
# Default output: portable tar.zst. Optional: deb, rpm, arch, appimage, all.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME=$(basename "$0")
DEFAULT_DOWNLOAD_PAGE="https://superhuman.com/download"
DEFAULT_ELECTRON_VERSION="34.5.8"
PKG_NAME="superhuman-linux-unofficial"
BIN_NAME="superhuman"
INSTALL_DIR="/opt/${PKG_NAME}"
DESKTOP_ID="${PKG_NAME}.desktop"
LINUX_ARCH="x86_64"
DEB_ARCH="amd64"

DOWNLOAD_PAGE="$DEFAULT_DOWNLOAD_PAGE"
DOWNLOAD_URL=""
ELECTRON_VERSION="$DEFAULT_ELECTRON_VERSION"
FORMATS="tar"
OUT_DIR="$PWD/dist-superhuman"
WORK_DIR=""
KEEP_WORK=0
FORCE=0
DOWNLOAD_APPIMAGETOOL=0
REQUESTED_ALL=0

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

cleanup() {
  local code=$?
  if [[ $code -ne 0 ]]; then
    err "Failed at line ${BASH_LINENO[0]} while running: ${BASH_COMMAND}"
  fi
  if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" && "$KEEP_WORK" -ne 1 ]]; then
    rm -rf "$WORK_DIR"
  elif [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then
    warn "Keeping work dir: $WORK_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --formats LIST              Comma-separated package formats.
                              Supported: tar,deb,rpm,arch,appimage,all
                              Default: tar
  --out DIR                   Output directory. Default: ./dist-superhuman
  --work DIR                  Work directory. Default: temporary directory
  --keep-work                 Do not delete work directory on exit
  --force                     Overwrite existing output directory contents
  --download-page URL         Page used to discover the installer URL
                              Default: $DEFAULT_DOWNLOAD_PAGE
  --download-url URL          Skip discovery and use this installer URL
  --electron-version VERSION  Linux Electron runtime version
                              Default: $DEFAULT_ELECTRON_VERSION
  --download-appimagetool     If appimagetool is missing, download it automatically
  -h, --help                  Show this help

Examples:
  ./$SCRIPT_NAME --formats tar
  ./$SCRIPT_NAME --formats tar,deb
  ./$SCRIPT_NAME --formats all --download-appimagetool

Notes:
  - rpm requires rpmbuild.
  - deb requires dpkg-deb.
  - arch requires makepkg.
  - appimage requires appimagetool, unless --download-appimagetool is used.
EOF
}

require_arg() {
  local opt=$1
  local val=${2-}
  [[ -n "$val" && "$val" != --* ]] || die "$opt requires a value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --formats) require_arg "$1" "${2-}"; FORMATS="$2"; shift 2 ;;
    --out) require_arg "$1" "${2-}"; OUT_DIR="$2"; shift 2 ;;
    --work) require_arg "$1" "${2-}"; WORK_DIR="$2"; KEEP_WORK=1; shift 2 ;;
    --keep-work) KEEP_WORK=1; shift ;;
    --force) FORCE=1; shift ;;
    --download-page) require_arg "$1" "${2-}"; DOWNLOAD_PAGE="$2"; shift 2 ;;
    --download-url) require_arg "$1" "${2-}"; DOWNLOAD_URL="$2"; shift 2 ;;
    --electron-version) require_arg "$1" "${2-}"; ELECTRON_VERSION="$2"; shift 2 ;;
    --download-appimagetool) DOWNLOAD_APPIMAGETOOL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$FORMATS" ]] || die "--formats cannot be empty"
[[ -n "$OUT_DIR" ]] || die "--out cannot be empty"

if [[ "$(uname -s)" != "Linux" ]]; then
  die "This script must run on Linux."
fi
if [[ "$(uname -m)" != "x86_64" ]]; then
  die "Only x86_64 Linux is supported by this script right now. Detected: $(uname -m)"
fi

need() { command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }
have() { command -v "$1" >/dev/null 2>&1; }

need curl
need 7z
need node
need npm
need npx
need tar
need file
need python3

tar_zstd_create() {
  local archive=$1 base_dir=$2 entry=$3
  if tar --help 2>/dev/null | grep -q -- '--zstd'; then
    tar --zstd -cf "$archive" -C "$base_dir" "$entry"
  else
    need zstd
    tar -I zstd -cf "$archive" -C "$base_dir" "$entry"
  fi
}

# Normalize formats.
FORMATS=$(printf '%s' "$FORMATS" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
if [[ "$FORMATS" == "all" ]]; then
  REQUESTED_ALL=1
  FORMATS="tar,deb,rpm,arch,appimage"
fi
IFS=',' read -r -a FORMAT_ARRAY <<< "$FORMATS"
for f in "${FORMAT_ARRAY[@]}"; do
  case "$f" in
    tar|deb|rpm|arch|appimage) ;;
    *) die "Unsupported format: $f" ;;
  esac
done

if [[ -e "$OUT_DIR" && "$FORCE" -eq 1 ]]; then
  rm -rf "$OUT_DIR"
fi
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR=$(mktemp -d -t superhuman-repack.XXXXXXXX)
else
  mkdir -p "$WORK_DIR"
  WORK_DIR=$(cd "$WORK_DIR" && pwd)
fi

run_asar() {
  npx --yes @electron/asar "$@"
}

url_effective() {
  local url=$1
  curl -fsSIL --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' "$url"
}

discover_download_url() {
  if [[ -n "$DOWNLOAD_URL" ]]; then
    printf '%s\n' "$DOWNLOAD_URL"
    return 0
  fi

  local html_file candidate final_url
  log "Discovering download URL from $DOWNLOAD_PAGE"
  html_file="$WORK_DIR/download.html"
  curl -fsSL --retry 3 --retry-delay 2 -A 'Mozilla/5.0 (X11; Linux x86_64)' "$DOWNLOAD_PAGE" -o "$html_file" || \
    die "Could not fetch $DOWNLOAD_PAGE"

  # The Framer page currently references https://superhuman.com/windows; that
  # route redirects to the actual binary at assets.mail.superhuman.com.
  candidate=$(python3 - "$html_file" <<'PY'
import re, sys, html as h, pathlib
text = pathlib.Path(sys.argv[1]).read_text(errors='replace')
urls = []
for pat in [r'https://superhuman\.com/windows', r'https://www\.superhuman\.com/windows', r'(?<![A-Za-z0-9_./:-])/windows(?![A-Za-z0-9_/-])']:
    for m in re.finditer(pat, text, re.I):
        u = h.unescape(m.group(0))
        if u.startswith('/'):
            u = 'https://superhuman.com' + u
        if u not in urls:
            urls.append(u)
if urls:
    print(urls[0])
PY
)

  if [[ -z "$candidate" ]]; then
    log "Looking for download route in linked page scripts"
    candidate=$(python3 - "$html_file" <<'PY'
import html as h, pathlib, re, sys, urllib.request
text = pathlib.Path(sys.argv[1]).read_text(errors='replace')
script_urls = []
for m in re.finditer(r'https://framerusercontent\.com/sites/[^"\']+\.mjs', text):
    u = h.unescape(m.group(0))
    if u not in script_urls:
        script_urls.append(u)
for m in re.finditer(r'<script[^>]+src="([^"]+)"', text):
    u = h.unescape(m.group(1))
    if u.endswith('.mjs') and u not in script_urls:
        script_urls.append(u)
patterns = [r'https://superhuman\.com/windows', r'https://www\.superhuman\.com/windows', r'(?<![A-Za-z0-9_./:-])/windows(?![A-Za-z0-9_/-])']
for u in script_urls[:30]:
    try:
        data = urllib.request.urlopen(urllib.request.Request(u, headers={'User-Agent':'Mozilla/5.0'}), timeout=20).read().decode('utf-8', 'replace')
    except Exception:
        continue
    for pat in patterns:
        m = re.search(pat, data, re.I)
        if not m:
            continue
        found = h.unescape(m.group(0))
        if found.startswith('/'):
            found = 'https://superhuman.com' + found
        print(found)
        raise SystemExit(0)
PY
)
  fi

  if [[ -z "$candidate" ]]; then
    warn "Could not find /windows in page or linked scripts; falling back to https://superhuman.com/windows"
    candidate="https://superhuman.com/windows"
  fi

  final_url=$(url_effective "$candidate") || die "Could not resolve final installer URL from $candidate"
  [[ "$final_url" == http* ]] || die "Resolved installer URL is invalid: $final_url"
  printf '%s\n' "$final_url"
}

patch_app_sources() {
  local app_dir=$1
  local main_js="$app_dir/src/main.js"
  local window_js="$app_dir/src/window.js"
  [[ -f "$main_js" ]] || die "Patch target missing: $main_js"
  [[ -f "$window_js" ]] || die "Patch target missing: $window_js"

  log "Applying Linux compatibility patches"
  python3 - "$main_js" "$window_js" <<'PY'
import pathlib, sys
main = pathlib.Path(sys.argv[1])
window = pathlib.Path(sys.argv[2])

def replace(path, old, new, label):
    s = path.read_text()
    if old not in s:
        raise SystemExit(f"Patch context not found for {label} in {path}")
    path.write_text(s.replace(old, new, 1))

# Linux browsers/XDG may call custom protocols as superhuman:/path or
# superhuman:path instead of the Windows/macOS-style superhuman://path.
replace(main,
"""    if (url.startsWith(`${appConfig.nativeScheme}//`)) {
      if (event) {
        event.preventDefault()
      }

      let path = url.slice(`${appConfig.nativeScheme}//`.length)
      // The URL should never have a leading slash, but making sure we don't
      // accidentally put two later
      if (!path.startsWith('/')) {
        path = '/' + path
      }
""",
"""    if (url.startsWith(appConfig.nativeScheme)) {
      if (event) {
        event.preventDefault()
      }

      let path = url.slice(appConfig.nativeScheme.length)
      // Linux/XDG and different browsers may hand custom protocols to the app
      // as superhuman://path, superhuman:/path, or superhuman:path. Normalize
      // all of them to the in-app path form expected below.
      path = path.replace(/^\\/\\//, '/')
      if (!path.startsWith('/')) {
        path = '/' + path
      }
""", "main custom protocol normalization")

replace(window,
"""const OAUTH_URLS_PREFIXES = [
  'https://accounts.google.com/o/oauth2/auth',
  'about:blank',
  'https://login.microsoftonline.com/common/oauth2'
]
""",
"""const OAUTH_URLS_PREFIXES = [
  'about:blank',
  // Google has moved OAuth endpoints over time. The original Windows build only
  // allowed /o/oauth2/auth, which causes newer /o/oauth2/v2/auth login windows
  // to be punted to the external browser and lose the native-app callback.
  'https://accounts.google.com/',
  'https://accounts.superhuman.com/',
  // Microsoft tenant paths can vary (/common, /organizations, /consumers, ...).
  'https://login.microsoftonline.com/',
  'https://login.live.com/'
]
""", "oauth prefix broadening")

replace(window,
"""  _isBackendAuthUrl(url) {
    return url.startsWith(`${appConfig.serverOrigin}/~backend/oauth/init`)
  }

  _onWillNavigate(event, url) {
    if (url.startsWith(appConfig.serverOrigin) && !this._isBackendAuthUrl(url)) {
      // default behavior is fine here, this happens when upgrading the app
      // code
      return
    }

    this.handleLink(event, url)
  }
""",
"""  _isBackendAuthUrl(url) {
    return url.startsWith(`${appConfig.serverOrigin}/~backend/oauth/init`)
  }

  _isOAuthCompletionUrl(url) {
    return url.startsWith(`${appConfig.serverOrigin}/~login`) || url.startsWith(appConfig.nativeScheme)
  }

  _nativeUrlForOAuthCompletion(url) {
    if (url.startsWith(appConfig.nativeScheme)) {
      return url
    }

    if (url.startsWith(appConfig.serverOrigin)) {
      const path = url.slice(appConfig.serverOrigin.length).replace(/^\\//, '')
      return `${appConfig.nativeScheme}//${path}`
    }

    return url
  }

  _openOAuthWindow(url) {
    const authWindow = new BrowserWindow({
      width: 500,
      height: 720,
      parent: this.window,
      modal: false,
      show: true,
      webPreferences: {
        plugins: true,
        spellcheck: false
      }
    })

    const maybeComplete = (event, targetUrl) => {
      if (!this._isOAuthCompletionUrl(targetUrl)) {
        return false
      }

      if (event && event.preventDefault) {
        event.preventDefault()
      }

      const nativeUrl = this._nativeUrlForOAuthCompletion(targetUrl)
      if (this.main && this.main.openUrl) {
        this.main.openUrl(null, nativeUrl)
      } else if (global.main && global.main.openUrl) {
        global.main.openUrl(null, nativeUrl)
      }

      if (!authWindow.isDestroyed()) {
        authWindow.close()
      }
      return true
    }

    authWindow.webContents.setWindowOpenHandler(({ url: targetUrl }) => {
      return maybeComplete(null, targetUrl) ? { action: 'deny' } : { action: 'allow' }
    })
    authWindow.webContents.on('will-navigate', maybeComplete)
    authWindow.webContents.on('did-navigate', (_event, targetUrl) => maybeComplete(null, targetUrl))
    authWindow.webContents.on('did-navigate-in-page', (_event, targetUrl) => maybeComplete(null, targetUrl))
    authWindow.loadURL(url)
  }

  _onWillNavigate(event, url) {
    if (this._isBackendAuthUrl(url)) {
      event.preventDefault()
      this._openOAuthWindow(url)
      return
    }

    if (url.startsWith(appConfig.serverOrigin) && !this._isBackendAuthUrl(url)) {
      // default behavior is fine here, this happens when upgrading the app
      // code
      return
    }

    this.handleLink(event, url)
  }
""", "oauth child window flow")

replace(window,
"""    } else if (url.toLowerCase().startsWith(`${appConfig.nativeScheme}//`)) {
      pathToOpen = url.slice(`${appConfig.nativeScheme}//`.length)
    }
""",
"""    } else if (url.toLowerCase().startsWith(appConfig.nativeScheme)) {
      pathToOpen = url.slice(appConfig.nativeScheme.length).replace(/^\\/\\//, '/')
    }
""", "window custom protocol normalization")
PY
}

create_wrapper() {
  local dir=$1
  cat > "$dir/$BIN_NAME" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

flags=()
if [[ -n "${WAYLAND_DISPLAY:-}" && "${SUPERHUMAN_USE_X11:-}" != "1" ]]; then
  flags+=(--enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland)
fi

if [[ "${SUPERHUMAN_NO_SANDBOX:-}" == "1" ]]; then
  flags+=(--no-sandbox)
fi

exec "$HERE/superhuman-bin" "${flags[@]}" "$@"
EOF
  chmod 0755 "$dir/$BIN_NAME"
}

create_desktop_file() {
  local path=$1 exec_cmd=$2 icon_name=$3
  cat > "$path" <<EOF
[Desktop Entry]
Name=Superhuman
Comment=Superhuman email client
Exec=$exec_cmd %U
Icon=$icon_name
Terminal=false
Type=Application
Categories=Network;Email;
MimeType=x-scheme-handler/superhuman;x-scheme-handler/mailto;
StartupWMClass=superhuman-bin
EOF
}

build_install_root() {
  local portable_dir=$1 root_dir=$2
  rm -rf "$root_dir"
  mkdir -p "$root_dir$INSTALL_DIR" "$root_dir/usr/bin" "$root_dir/usr/share/applications" "$root_dir/usr/share/icons/hicolor/256x256/apps"
  cp -a "$portable_dir/." "$root_dir$INSTALL_DIR/"
  ln -s "$INSTALL_DIR/$BIN_NAME" "$root_dir/usr/bin/$BIN_NAME"
  cp "$portable_dir/resources/icon.png" "$root_dir/usr/share/icons/hicolor/256x256/apps/superhuman.png"
  create_desktop_file "$root_dir/usr/share/applications/$DESKTOP_ID" "/usr/bin/$BIN_NAME" "superhuman"
}

build_tar() {
  local portable_dir=$1 version=$2
  local archive="$OUT_DIR/Superhuman-linux-x64-${version}.tar.zst"
  log "Building portable tarball: $archive"
  tar_zstd_create "$archive" "$(dirname "$portable_dir")" "$(basename "$portable_dir")"
}

build_deb() {
  local root_dir=$1 version=$2 explicit=$3
  if ! have dpkg-deb; then
    [[ "$explicit" == 1 ]] && die "dpkg-deb is required for deb output"
    warn "Skipping deb: dpkg-deb not found"
    return 0
  fi
  local debroot="$WORK_DIR/debroot"
  rm -rf "$debroot"
  cp -a "$root_dir" "$debroot"
  mkdir -p "$debroot/DEBIAN"
  local installed_size
  installed_size=$(du -sk "$debroot" | awk '{print $1}')
  cat > "$debroot/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $version
Section: mail
Priority: optional
Architecture: $DEB_ARCH
Installed-Size: $installed_size
Maintainer: local <root@localhost>
Description: Superhuman Mail unofficial Linux repackaging
 Repackages Superhuman's Electron app from the official Windows installer
 with a Linux Electron runtime.
EOF
  cat > "$debroot/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
exit 0
EOF
  chmod 0755 "$debroot/DEBIAN/postinst"
  local out="$OUT_DIR/${PKG_NAME}_${version}_${DEB_ARCH}.deb"
  log "Building deb: $out"
  dpkg-deb --root-owner-group --build "$debroot" "$out" >/dev/null
}

build_rpm() {
  local root_dir=$1 version=$2 explicit=$3
  if ! have rpmbuild; then
    [[ "$explicit" == 1 ]] && die "rpmbuild is required for rpm output"
    warn "Skipping rpm: rpmbuild not found"
    return 0
  fi
  local rpmdir="$WORK_DIR/rpmbuild"
  mkdir -p "$rpmdir/BUILD" "$rpmdir/RPMS" "$rpmdir/SOURCES/root" "$rpmdir/SPECS" "$rpmdir/SRPMS"
  cp -a "$root_dir/." "$rpmdir/SOURCES/root/"
  cat > "$rpmdir/SPECS/$PKG_NAME.spec" <<EOF
Name: $PKG_NAME
Version: $version
Release: 1%{?dist}
Summary: Superhuman Mail unofficial Linux repackaging
License: Proprietary
URL: https://superhuman.com/
BuildArch: x86_64
AutoReqProv: no

%description
Repackages Superhuman's Electron app from the official Windows installer with a Linux Electron runtime.

%install
mkdir -p %{buildroot}
cp -a %{_sourcedir}/root/. %{buildroot}/

%post
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi

%files
$INSTALL_DIR
/usr/bin/$BIN_NAME
/usr/share/applications/$DESKTOP_ID
/usr/share/icons/hicolor/256x256/apps/superhuman.png
EOF
  log "Building rpm"
  rpmbuild --define "_topdir $rpmdir" -bb "$rpmdir/SPECS/$PKG_NAME.spec" >/dev/null
  find "$rpmdir/RPMS" -type f -name '*.rpm' -exec cp {} "$OUT_DIR/" \;
}

build_arch() {
  local root_dir=$1 version=$2 explicit=$3
  if ! have makepkg; then
    [[ "$explicit" == 1 ]] && die "makepkg is required for arch output"
    warn "Skipping arch: makepkg not found"
    return 0
  fi
  local archdir="$WORK_DIR/archpkg"
  rm -rf "$archdir"
  mkdir -p "$archdir/root"
  cp -a "$root_dir/." "$archdir/root/"
  cat > "$archdir/PKGBUILD" <<EOF
pkgname=$PKG_NAME
pkgver=$version
pkgrel=1
pkgdesc="Superhuman Mail unofficial Linux repackaging"
arch=('x86_64')
url='https://superhuman.com/'
license=('custom:proprietary')
options=('!strip')
package() {
  cp -a "\$srcdir/../root/." "\$pkgdir/"
}
EOF
  log "Building Arch package"
  (cd "$archdir" && makepkg -f --nodeps --skipchecksums --noconfirm >/dev/null)
  find "$archdir" -maxdepth 1 -type f -name '*.pkg.tar.*' -exec cp {} "$OUT_DIR/" \;
}

get_appimagetool() {
  if have appimagetool; then
    command -v appimagetool
    return 0
  fi
  if [[ "$DOWNLOAD_APPIMAGETOOL" -ne 1 ]]; then
    return 1
  fi
  local tool="$WORK_DIR/appimagetool-x86_64.AppImage"
  log "Downloading appimagetool"
  curl -fL --retry 3 --retry-delay 2 \
    -o "$tool" \
    "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
  chmod 0755 "$tool"
  printf '%s\n' "$tool"
}

build_appimage() {
  local portable_dir=$1 version=$2 explicit=$3
  local tool
  if ! tool=$(get_appimagetool); then
    [[ "$explicit" == 1 ]] && die "appimagetool is required for appimage output (or use --download-appimagetool)"
    warn "Skipping appimage: appimagetool not found"
    return 0
  fi
  local appdir="$WORK_DIR/Superhuman.AppDir"
  rm -rf "$appdir"
  mkdir -p "$appdir/usr/lib/superhuman" "$appdir/usr/share/applications" "$appdir/usr/share/icons/hicolor/256x256/apps"
  cp -a "$portable_dir/." "$appdir/usr/lib/superhuman/"
  cp "$portable_dir/resources/icon.png" "$appdir/superhuman.png"
  cp "$portable_dir/resources/icon.png" "$appdir/usr/share/icons/hicolor/256x256/apps/superhuman.png"
  create_desktop_file "$appdir/$DESKTOP_ID" "AppRun" "superhuman"
  cp "$appdir/$DESKTOP_ID" "$appdir/usr/share/applications/$DESKTOP_ID"
  cat > "$appdir/AppRun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/usr/lib/superhuman/superhuman" "$@"
EOF
  chmod 0755 "$appdir/AppRun"
  local out="$OUT_DIR/Superhuman-${version}-${LINUX_ARCH}.AppImage"
  log "Building AppImage: $out"
  ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool" "$appdir" "$out" >/dev/null
  chmod 0755 "$out"
}

main() {
  local final_url installer nsis_dir plugin_dir app_archive app64_dir app_asar app_src electron_prefix electron_dist portable_dir version root_dir

  final_url=$(discover_download_url)
  log "Installer URL: $final_url"

  installer="$WORK_DIR/Superhuman.exe"
  log "Downloading installer"
  curl -fL --retry 3 --retry-delay 2 -C - -o "$installer" "$final_url"
  file "$installer" | grep -qiE 'PE32|MS Windows|Nullsoft|executable' || die "Downloaded file does not look like a Windows installer: $(file "$installer")"

  nsis_dir="$WORK_DIR/nsis"
  mkdir -p "$nsis_dir"
  log "Extracting NSIS installer"
  7z x -y -o"$nsis_dir" "$installer" >/dev/null

  plugin_dir=$(find "$nsis_dir" -type d -name '\$PLUGINSDIR' -print -quit)
  [[ -n "$plugin_dir" ]] || die "Could not find NSIS \$PLUGINSDIR after extraction"
  app_archive="$plugin_dir/app-64.7z"
  [[ -f "$app_archive" ]] || die "Could not find $app_archive"

  app64_dir="$WORK_DIR/app64"
  mkdir -p "$app64_dir"
  log "Extracting embedded app-64.7z"
  7z x -y -o"$app64_dir" "$app_archive" >/dev/null

  app_asar="$app64_dir/resources/app.asar"
  [[ -f "$app_asar" ]] || die "Could not find resources/app.asar"

  app_src="$WORK_DIR/app-src"
  log "Extracting app.asar"
  run_asar extract "$app_asar" "$app_src"
  [[ -f "$app_src/package.json" ]] || die "app.asar extraction did not produce package.json"

  version=$(node -e "console.log(require(process.argv[1]).version)" "$app_src/package.json")
  [[ "$version" =~ ^[0-9][A-Za-z0-9._+-]*$ ]] || die "Invalid package version discovered: $version"
  log "Superhuman version: $version"

  patch_app_sources "$app_src"

  log "Repacking patched app.asar"
  run_asar pack "$app_src" "$WORK_DIR/app.patched.asar"

  electron_prefix="$WORK_DIR/electron"
  log "Installing Linux Electron runtime $ELECTRON_VERSION"
  npm install --prefix "$electron_prefix" --no-audit --no-fund "electron@$ELECTRON_VERSION" >/dev/null
  electron_dist="$electron_prefix/node_modules/electron/dist"
  [[ -x "$electron_dist/electron" ]] || die "Electron runtime install failed"

  portable_dir="$WORK_DIR/Superhuman-linux-x64"
  log "Creating portable Linux app"
  rm -rf "$portable_dir"
  mkdir -p "$portable_dir"
  cp -a "$electron_dist/." "$portable_dir/"
  rm -f "$portable_dir/resources/default_app.asar"
  cp "$WORK_DIR/app.patched.asar" "$portable_dir/resources/app.asar"
  [[ -f "$app64_dir/resources/app-update.yml" ]] && cp "$app64_dir/resources/app-update.yml" "$portable_dir/resources/app-update.yml"
  cp "$app_src/assets/app.png" "$portable_dir/resources/icon.png"
  [[ -f "$app_src/assets/app.icns" ]] && cp "$app_src/assets/app.icns" "$portable_dir/resources/icon.icns"
  mv "$portable_dir/electron" "$portable_dir/superhuman-bin"
  chmod 0755 "$portable_dir/superhuman-bin"
  create_wrapper "$portable_dir"
  create_desktop_file "$portable_dir/$DESKTOP_ID" "./$BIN_NAME" "./resources/icon.png"
  cat > "$portable_dir/install-desktop-entry.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
HERE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "\$HOME/.local/share/applications"
sed "s#Exec=./$BIN_NAME#Exec=\$HERE/$BIN_NAME#; s#Icon=./resources/icon.png#Icon=\$HERE/resources/icon.png#" \
  "\$HERE/$DESKTOP_ID" > "\$HOME/.local/share/applications/$DESKTOP_ID"
update-desktop-database "\$HOME/.local/share/applications" >/dev/null 2>&1 || true
xdg-mime default "$DESKTOP_ID" x-scheme-handler/superhuman || true
xdg-settings set default-url-scheme-handler superhuman "$DESKTOP_ID" >/dev/null 2>&1 || true
printf 'Installed desktop entry: %s\n' "\$HOME/.local/share/applications/$DESKTOP_ID"
EOF
  chmod 0755 "$portable_dir/install-desktop-entry.sh"

  root_dir="$WORK_DIR/install-root"
  build_install_root "$portable_dir" "$root_dir"

  local strict_optional=1
  [[ "$REQUESTED_ALL" -eq 1 ]] && strict_optional=0
  for fmt in "${FORMAT_ARRAY[@]}"; do
    case "$fmt" in
      tar) build_tar "$portable_dir" "$version" ;;
      deb) build_deb "$root_dir" "$version" "$strict_optional" ;;
      rpm) build_rpm "$root_dir" "$version" "$strict_optional" ;;
      arch) build_arch "$root_dir" "$version" "$strict_optional" ;;
      appimage) build_appimage "$portable_dir" "$version" "$strict_optional" ;;
    esac
  done

  log "Done. Outputs:"
  find "$OUT_DIR" -maxdepth 1 -type f -printf '  %p\n' | sort >&2
}

main "$@"
