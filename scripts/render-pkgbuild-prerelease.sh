#!/usr/bin/env bash
# Render the prerelease PKGBUILD/.SRCINFO for a given upstream tag.
#
# The prerelease channel differs from the stable one in three ways:
#   - upstream publishes no .deb for prereleases, only an AppImage
#   - the tag carries an rc suffix (v1.4.0-rc.6) that Arch cannot use in pkgver
#   - the tag must be kept verbatim in _tag, because that is what the source URL
#     and the AppImage filename are built from
#
# Usage: render-pkgbuild-prerelease.sh <tag> <asset-url> [expected-sha256]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${WORKDIR:=/tmp/aur-build}"
: "${EXPECTED_DIGEST:=}"   # optional sha256:<hex> from the GitHub API

tag="${1:-}"
asset_url="${2:-}"
expected_sha="${3:-}"
[ -n "$tag" ] || die "usage: render-pkgbuild-prerelease.sh <tag> <asset-url> [sha256]"
[ -n "$asset_url" ] || die "usage: render-pkgbuild-prerelease.sh <tag> <asset-url> [sha256]"
[ -f PKGBUILD ] || die "PKGBUILD not found in $(pwd)"

require_cmd curl sha256sum sed makepkg

# v1.4.0-rc.6 -> 1.4.0rc.6
# Arch forbids '-' in pkgver, and dropping it keeps vercmp ordering correct:
# 1.4.0rc.6 sorts before 1.4.0.
raw_version="${tag#v}"
pkgver="${raw_version//-/}"

asset_name="${asset_url##*/}"
srcdest="${WORKDIR}/srcdest"
mkdir -p "$srcdest"
export SRCDEST="$srcdest"

# ---------------------------------------------------------------------------
# 1. Fetch the upstream AppImage.
# ---------------------------------------------------------------------------
asset_path="${srcdest}/${asset_name}"
if [ -s "$asset_path" ]; then
  log "source already present: ${asset_name}"
else
  log "downloading ${asset_name} ..."
  tmp="${asset_path}.part"
  rm -f "$tmp"
  curl -fSL --retry 3 --retry-delay 2 --max-time 1800 \
    -H "User-Agent: limusic-bin-aur-automation" \
    -o "$tmp" "$asset_url" || die "failed to download ${asset_url}"
  mv -f "$tmp" "$asset_path"
fi

sha256="$(sha256sum "$asset_path" | cut -d' ' -f1)"
size="$(stat -c %s "$asset_path" 2>/dev/null || echo 0)"
log "sha256: ${sha256} (${size} bytes)"

if [ "$size" -lt 1000000 ]; then
  die "downloaded source is only ${size} bytes — refusing to continue"
fi

if [ -n "$expected_sha" ]; then
  [ "${expected_sha#sha256:}" = "$sha256" ] \
    || die "checksum mismatch: GitHub API publishes ${expected_sha#sha256:}, download is ${sha256}"
  log "checksum matches the GitHub API digest"
fi

# ---------------------------------------------------------------------------
# 2. Rewrite PKGBUILD.
# ---------------------------------------------------------------------------
previous_version="$(pkgbuild_var PKGBUILD pkgver)"
previous_rel="$(pkgbuild_var PKGBUILD pkgrel)"
previous_sha="$(pkgbuild_var PKGBUILD sha256sums)"

sed -i -E "s|^pkgver=.*$|pkgver=${pkgver}|" PKGBUILD
sed -i -E "s|^_tag=.*$|_tag=${raw_version}|" PKGBUILD
sed -i -E "s|^sha256sums=\(.*\)$|sha256sums=('${sha256}')|" PKGBUILD

if [ "$previous_version" != "$pkgver" ]; then
  # Every new prerelease starts at pkgrel=1.
  new_rel=1
  rel_reason="new upstream prerelease"
elif [ "$previous_sha" != "$sha256" ]; then
  # Same version, re-published asset: users only rebuild when pkgrel moves.
  new_rel=$(( ${previous_rel:-0} + 1 ))
  rel_reason="payload changed for the same version"
else
  new_rel="${previous_rel:-1}"
  rel_reason="no payload change (pkgrel kept)"
fi

sed -i -E "s|^pkgrel=.*$|pkgrel=${new_rel}|" PKGBUILD
log "pkgver ${previous_version:-<unset>} -> ${pkgver}, pkgrel ${previous_rel:-<unset>} -> ${new_rel} (${rel_reason})"

# ---------------------------------------------------------------------------
# 3. Regenerate .SRCINFO from the PKGBUILD (never hand-edited).
# ---------------------------------------------------------------------------
makepkg --printsrcinfo >.SRCINFO.tmp 2>/dev/null || die "makepkg --printsrcinfo failed"
mv -f .SRCINFO.tmp .SRCINFO

# ---------------------------------------------------------------------------
# 4. Verify the manifest describes the file we downloaded.
# ---------------------------------------------------------------------------
expected_source="https://github.com/SimoHypers/limusic/releases/download/v${raw_version}/limusic_${raw_version}_amd64.AppImage"
manifest_source="$(srcinfo_var .SRCINFO source)"
manifest_sha="$(srcinfo_var .SRCINFO sha256sums)"

[ "$manifest_source" = "${asset_name}::${expected_source}" ] \
  || [ "$manifest_source" = "$expected_source" ] \
  || die "source in .SRCINFO is '${manifest_source}', expected '${expected_source}'"
[ "$manifest_sha" = "$sha256" ] \
  || die ".SRCINFO checksum '${manifest_sha}' != downloaded '${sha256}'"
log "manifest source: ${expected_source}"

log "==> makepkg --verifysource"
if ! makepkg --verifysource >"${WORKDIR}/verifysource.log" 2>&1; then
  tail -n 20 "${WORKDIR}/verifysource.log" >&2 || true
  die "makepkg --verifysource rejected the source (bad checksum?)"
fi
log "source verified by makepkg"

set_output rendered_version "$pkgver"
set_output tag "$tag"
set_output sha256 "$sha256"

summary "### render (prerelease)"
summary ""
summary "- tag: \`${tag}\`"
summary "- pkgver: \`${pkgver}\`"
summary "- sha256: \`${sha256}\`"
summary "- source: ${expected_source}"
