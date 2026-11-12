#!/usr/bin/env bash
# Run the whole pipeline locally against a version of your choosing, without
# touching the AUR. Useful for reproducing a CI failure or testing a new
# upstream release before the schedule fires.
#
# Usage:
#   ./scripts/local-test.sh                    # current PKGBUILD version (build+namcap only)
#   ./scripts/local-test.sh 1.4.0              # pretend upstream released 1.4.0
#   DRY_RUN=true ./scripts/local-test.sh 1.4.0 # stop right before the AUR push
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

version="${1:-}"
export WORKDIR="${WORKDIR:-${REPO_DIR}/.aur-build}"
mkdir -p "$WORKDIR"

echo "==> working copy: ${WORKDIR}"

if ! command -v makepkg >/dev/null 2>&1; then
  echo "This script needs makepkg/namcap (Arch Linux). Aborting." >&2
  exit 1
fi

if [ -n "$version" ]; then
  echo "==> rendering PKGBUILD for ${version}"
  deb_url="https://github.com/SimoHypers/limusic/releases/download/v${version}/limusic_${version}_amd64.deb"
  ./scripts/render-pkgbuild.sh "$version" "$deb_url"

  echo "==> building and checking"
  ./scripts/validate.sh

  echo
  echo "==> diff"
  git --no-pager diff -- PKGBUILD .SRCINFO || true

  if [ "${DRY_RUN:-false}" = true ]; then
    echo "DRY_RUN=true — stopping before the AUR push"
    exit 0
  fi

  echo
  echo "==> publishing to AUR (requires AUR_SSH_PRIVATE_KEY)"
  ./scripts/publish.sh "$version"
else
  echo "==> building and checking the current PKGBUILD"
  ./scripts/validate.sh
fi
