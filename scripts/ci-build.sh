#!/usr/bin/env bash
# Build pipeline executed as the unprivileged build user inside the container.
#
# Renders PKGBUILD/.SRCINFO for the new upstream version, then builds the
# package and gates it with namcap. Any failure aborts the run, so the caller's
# publish step never sees half-validated files.
#
# Usage: ci-build.sh <version> <deb-url>
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

version="${1:-}"
deb_url="${2:-}"
[ -n "$version" ] || die "usage: ci-build.sh <version> <deb-url>"
[ -n "$deb_url" ] || die "usage: ci-build.sh <version> <deb-url>"

# Everything ephemeral lives inside the build user's copy of the tree, which is
# writable by that user.
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"
export WORKDIR="${WORKDIR_OVERRIDE:-${REPO_ROOT}/.aur-build}"
mkdir -p "$WORKDIR"

"${SCRIPT_DIR}/render-pkgbuild.sh" "$version" "$deb_url"
"${SCRIPT_DIR}/validate.sh"
