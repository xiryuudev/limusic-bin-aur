#!/usr/bin/env bash
# Render PKGBUILD + .SRCINFO for a given upstream version.
#
# Downloads the release .deb into $WORKDIR/srcdest, computes its sha256,
# cross-checks it against the digest GitHub publishes, rewrites pkgver/pkgrel/
# sha256sums, regenerates .SRCINFO with makepkg, then runs `makepkg
# --verifysource` so pacman itself confirms the checksum against the real file.
#
# Usage: render-pkgbuild.sh <version> <deb-url>
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${WORKDIR:=/tmp/aur-build}"
: "${EXPECTED_DIGEST:=}"   # optional sha256:<hex> published by the GitHub API

version="${1:-}"
deb_url="${2:-}"
[ -n "$version" ] || die "usage: render-pkgbuild.sh <version> <deb-url>"
[ -n "$deb_url" ] || die "usage: render-pkgbuild.sh <version> <deb-url>"
[ -f PKGBUILD ] || die "PKGBUILD not found in $(pwd)"

require_cmd curl sha256sum sed makepkg

deb_name="${deb_url##*/}"
srcdest="${WORKDIR}/srcdest"
mkdir -p "$srcdest"
export SRCDEST="$srcdest"

# ---------------------------------------------------------------------------
# 1. Fetch the upstream artifact.
# ---------------------------------------------------------------------------
deb_path="${srcdest}/${deb_name}"
if [ -s "$deb_path" ] && bsdtar -tf "$deb_path" >/dev/null 2>&1; then
  log "source already present and readable: ${deb_name}"
else
  log "downloading ${deb_name} ..."
  tmp="${deb_path}.part"
  rm -f "$tmp"
  curl -fSL --retry 3 --retry-delay 2 --max-time 900 \
    -H "User-Agent: limusic-bin-aur-automation" \
    -o "$tmp" "$deb_url" || die "failed to download ${deb_url}"
  mv -f "$tmp" "$deb_path"
fi

sha256="$(sha256sum "$deb_path" | cut -d' ' -f1)"
size="$(stat -c %s "$deb_path" 2>/dev/null || echo 0)"
log "sha256: ${sha256} (${size} bytes)"

# A Tauri desktop bundle is tens of megabytes; a few KB means an error page.
if [ "$size" -lt 1000000 ]; then
  die "downloaded source is only ${size} bytes — refusing to continue"
fi

if [ -n "$EXPECTED_DIGEST" ]; then
  expected="${EXPECTED_DIGEST#sha256:}"
  if [ "$expected" != "$sha256" ]; then
    die "checksum mismatch: GitHub API publishes ${expected}, download is ${sha256}"
  fi
  log "checksum matches the GitHub API digest"
else
  warn "GitHub API exposed no digest for this asset — relying on the download only"
fi

# ---------------------------------------------------------------------------
# 2. Rewrite PKGBUILD.
# ---------------------------------------------------------------------------
previous_version="$(pkgbuild_var PKGBUILD pkgver)"
previous_rel="$(pkgbuild_var PKGBUILD pkgrel)"
previous_sha="$(pkgbuild_var PKGBUILD sha256sums)"

sed -i -E "s|^pkgver=.*$|pkgver=${version}|" PKGBUILD
sed -i -E "s|^sha256sums=\(.*\)$|sha256sums=('${sha256}')|" PKGBUILD

if [ "$previous_version" != "$version" ]; then
  # A new upstream version always starts at pkgrel=1.
  new_rel=1
  rel_reason="new upstream version"
else
  # Same version but a different payload (upstream re-uploaded the asset).
  # The AUR only rebuilds for users when pkgver-pkgrel moves, so bump pkgrel.
  if [ "$previous_sha" = "$sha256" ]; then
    new_rel="${previous_rel:-1}"
    rel_reason="no payload change"
  else
    new_rel=$(( ${previous_rel:-1} + 1 ))
    rel_reason="payload changed for the same version"
  fi
fi

sed -i -E "s|^pkgrel=.*$|pkgrel=${new_rel}|" PKGBUILD
log "pkgrel ${previous_rel:-?} -> ${new_rel} (${rel_reason})"

# ---------------------------------------------------------------------------
# 3. Regenerate .SRCINFO from the PKGBUILD (never hand-edited).
# ---------------------------------------------------------------------------
makepkg --printsrcinfo >.SRCINFO.tmp 2>/dev/null || die "makepkg --printsrcinfo failed"
mv -f .SRCINFO.tmp .SRCINFO

# ---------------------------------------------------------------------------
# 4. Verify the manifest actually describes the file we downloaded.
# ---------------------------------------------------------------------------
expected_source="https://github.com/SimoHypers/limusic/releases/download/v${version}/limusic_${version}_amd64.deb"
manifest_source="$(srcinfo_var .SRCINFO source)"
manifest_sha="$(srcinfo_var .SRCINFO sha256sums)"

[ "$manifest_source" = "$expected_source" ] \
  || die "source in .SRCINFO is '${manifest_source}', expected '${expected_source}'"
[ "$manifest_sha" = "$sha256" ] \
  || die ".SRCINFO checksum '${manifest_sha}' != downloaded '${sha256}'"
log "manifest source: ${manifest_source}"

# Let pacman validate the checksum against the real file (uses our SRCDEST).
log "==> makepkg --verifysource"
if ! makepkg --verifysource >"${WORKDIR}/verifysource.log" 2>&1; then
  tail -n 20 "${WORKDIR}/verifysource.log" >&2 || true
  die "makepkg --verifysource rejected the source (bad checksum?)"
fi
log "source verified by makepkg"

set_output rendered_version "$version"
set_output sha256 "$sha256"
set_output previous_version "$previous_version"

summary "### render"
summary ""
summary "- version: \`${version}\` (was \`${previous_version}\`)"
summary "- sha256: \`${sha256}\`"
summary "- source: ${expected_source}"
