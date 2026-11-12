#!/usr/bin/env bash
# Build pipeline executed as the unprivileged build user inside the container.
#
# Renders PKGBUILD/.SRCINFO for the target version, then builds the package and
# gates it with namcap. Any failure aborts the run, so the caller's publish step
# never sees half-validated files.
#
# Both arguments are optional: a push-triggered run has no check job, so the
# version comes from the PKGBUILD and the URL is derived from it.
#
# Usage: ci-build.sh [version] [deb-url]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

version="${1:-}"
if [ -z "$version" ]; then
  version="$(pkgbuild_var PKGBUILD pkgver)"
fi
[ -n "$version" ] || die "could not determine the version to build"

deb_url="${2:-}"
if [ -z "$deb_url" ]; then
  deb_url="https://github.com/SimoHypers/limusic/releases/download/v${version}/limusic_${version}_amd64.deb"
fi

log "target version: ${version}"
log "target source : ${deb_url}"

# Everything ephemeral lives inside the build user's copy of the tree, which is
# writable by that user.
export WORKDIR="${WORKDIR_OVERRIDE:-${REPO_ROOT}/.aur-build}"
mkdir -p "$WORKDIR"

"${SCRIPT_DIR}/render-pkgbuild.sh" "$version" "$deb_url"
"${SCRIPT_DIR}/validate.sh"
