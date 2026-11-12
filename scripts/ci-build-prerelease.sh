#!/usr/bin/env bash
# Build pipeline for the prerelease channel, executed as the unprivileged build
# user inside the container.
#
# Renders the AppImage-based PKGBUILD/.SRCINFO, builds the package and gates it
# with namcap. Any failure aborts the run, so publish.sh never sees
# half-validated files.
#
# Both arguments are optional: a push-triggered run has no check job, so the tag
# comes from the PKGBUILD and the URL is derived from it.
#
# Usage: ci-build-prerelease.sh [tag] [asset-url]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

tag="${1:-}"
if [ -z "$tag" ]; then
  tag="$(pkgbuild_var PKGBUILD _tag)"
  [ -n "$tag" ] || die "could not determine the upstream tag from PKGBUILD"
fi

asset_url="${2:-}"
if [ -z "$asset_url" ]; then
  asset_url="https://github.com/SimoHypers/limusic/releases/download/v${tag}/limusic_${tag}_amd64.AppImage"
fi

log "target tag   : ${tag}"
log "target source: ${asset_url}"

export WORKDIR="${WORKDIR_OVERRIDE:-${REPO_ROOT}/.aur-build}"
mkdir -p "$WORKDIR"

"${SCRIPT_DIR}/render-pkgbuild-prerelease.sh" "$tag" "$asset_url"
"${SCRIPT_DIR}/validate.sh"
