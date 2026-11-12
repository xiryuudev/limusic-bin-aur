#!/usr/bin/env bash
# Detect whether upstream has a release newer than the prerelease package.
#
# The prerelease channel tracks the NEWEST upstream release, whether it is an
# rc or a final release: once v1.4.0 ships, this package follows it, so users of
# the prerelease package are never left on an older version than the stable one.
#
# Upstream publishes no .deb for prereleases, but every release (rc and final)
# ships an AppImage, so the AppImage is used for both.
#
# Reads:  PKGBUILD (_tag, pkgver) and _version
# Writes: GitHub Actions outputs
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${UPSTREAM_REPO:=SimoHypers/limusic}"
: "${AUR_PKGNAME:=limusic-bin-prerelease}"
: "${GITHUB_API:=https://api.github.com}"
: "${USER_AGENT:=limusic-bin-prerelease-automation}"
: "${WORKDIR_CHECK:=${RUNNER_TEMP:-/tmp}/limusic-prerelease-check}"

require_cmd curl jq python3

[ -f PKGBUILD ] || die "PKGBUILD not found in $(pwd)"

repo_pkgver="$(pkgbuild_var PKGBUILD pkgver)"
[ -n "$repo_pkgver" ] || die "could not read pkgver from PKGBUILD"
repo_tag="$(pkgbuild_var PKGBUILD _tag)"

# ---------------------------------------------------------------------------
# Version key that understands this upstream's scheme: X.Y.Z and X.Y.Z-rc.N.
# sort -V and vercmp disagree on rc ordering with the sanitized pkgver, so the
# comparison is explicit: an rc sorts before its own final release.
# ---------------------------------------------------------------------------
version_key() {
  python3 - "$1" <<'PY'
import re, sys
v = sys.argv[1].strip().lstrip("v")
m = re.fullmatch(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-?rc\.?(\d+))?", v, re.I)
if not m:
    print("", end="")
    raise SystemExit(1)
major, minor, patch, rc = m.groups()
# A final release outranks any rc of the same X.Y.Z, so rc sorts first.
print(f"{int(major):05d}{int(minor or 0):05d}{int(patch or 0):05d}"
      f"{0 if rc is not None else 1}{(int(rc) if rc else 0):05d}")
PY
}

api_get() {
  local -a auth=()
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -n "$token" ]; then
    auth=(-H "Authorization: Bearer ${token}")
  fi
  curl -fsSL --retry 3 --retry-delay 2 --max-time 60 \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: ${USER_AGENT}" \
    "${auth[@]}" \
    "$1"
}

# ---------------------------------------------------------------------------
# Newest release, rc or final. Drafts have no usable assets yet.
# ---------------------------------------------------------------------------
releases_json="$(api_get "${GITHUB_API}/repos/${UPSTREAM_REPO}/releases?per_page=100")" \
  || die "GitHub API request failed for ${UPSTREAM_REPO}"

# Filter to releases whose tag looks like a version; the repo also has a "deps"
# release for build artifacts that must be ignored.
candidates="$(printf '%s' "$releases_json" | jq -c '
  [ .[]
    | select(.draft == false)
    | select(.tag_name | test("^v?[0-9]+\\.[0-9]+(\\.[0-9]+)?(-rc\\.[0-9]+)?$"))
  ]')"
count="$(printf '%s' "$candidates" | jq 'length')"
[ "$count" -gt 0 ] || die "no versioned upstream releases found"

release_tag="$(printf '%s' "$candidates" | jq -r '.[0].tag_name')"
latest_tag="$release_tag"
newest_key="$(version_key "$release_tag")" || die "cannot parse tag ${release_tag}"

while IFS= read -r tag; do
  key="$(version_key "$tag")" || continue
  if [[ "$key" > "$newest_key" ]]; then
    newest_key="$key"
    latest_tag="$tag"
  fi
done < <(printf '%s' "$candidates" | jq -r '.[].tag_name')

release_json="$(printf '%s' "$candidates" | jq -c --arg t "$latest_tag" '.[] | select(.tag_name == $t)')"
latest_version="${latest_tag#v}"
pkgver_new="${latest_version//-/}"

# The AppImage is published for both rc and final releases.
asset_name="limusic_${latest_version}_amd64.AppImage"
asset_json="$(printf '%s' "$release_json" | jq -c --arg n "$asset_name" '.assets[]? | select(.name == $n)')"
if [ -z "$asset_json" ]; then
  die "release ${latest_tag} has no asset named ${asset_name} (asset naming changed upstream?)"
fi
asset_url="$(printf '%s' "$asset_json" | jq -r '.browser_download_url')"
asset_digest="$(printf '%s' "$asset_json" | jq -r '.digest // empty')"
is_prerelease="$(printf '%s' "$release_json" | jq -r '.prerelease')"

# ---------------------------------------------------------------------------
# Decide: is the newest release actually newer than what we package?
# ---------------------------------------------------------------------------
current_key="$(version_key "$repo_pkgver")" || die "cannot parse pkgver ${repo_pkgver}"

# ---------------------------------------------------------------------------
# Recipe drift: the repo's PKGBUILD can be correct while the AUR's copy is stale
# at the same pkgver — adding a provides/conflicts or fixing a dependency does
# not change upstream's version, so version comparison alone would never publish
# it. The AUR git repository is authoritative and reflects a push immediately;
# its cgit view is not used because it lags by minutes and produced false drift.
# ---------------------------------------------------------------------------
aur_git_pkgbuild() {
  local dir="${WORKDIR_CHECK}/aur-git"
  rm -rf "$dir"
  if command -v git >/dev/null 2>&1; then
    if GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --filter=blob:none --no-checkout \
      "https://aur.archlinux.org/${AUR_PKGNAME}.git" "$dir" >/dev/null 2>&1; then
      git -C "$dir" show HEAD:PKGBUILD 2>/dev/null && return 0
    fi
  fi
  curl -fsSL --retry 2 --max-time 30 -H "User-Agent: ${USER_AGENT}" \
    "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=${AUR_PKGNAME}" 2>/dev/null
}

recipe_drift=false
mkdir -p "${WORKDIR_CHECK}"
aur_pkgbuild_text="$(aur_git_pkgbuild 2>/dev/null || true)"

if [ -n "$aur_pkgbuild_text" ]; then
  printf '%s\n' "$aur_pkgbuild_text" >"${WORKDIR_CHECK}/aur.PKGBUILD"
  normalize_pkgbuild_file "${WORKDIR_CHECK}/aur.PKGBUILD" >"${WORKDIR_CHECK}/aur.norm"
  normalize_pkgbuild_file PKGBUILD >"${WORKDIR_CHECK}/local.norm"
  if ! diff -q "${WORKDIR_CHECK}/aur.norm" "${WORKDIR_CHECK}/local.norm" >/dev/null 2>&1; then
    recipe_drift=true
    log "repo PKGBUILD differs from the AUR git copy:"
    diff -u "${WORKDIR_CHECK}/aur.norm" "${WORKDIR_CHECK}/local.norm" >&2 || true
  fi
else
  log "AUR git copy unavailable; skipping the recipe-drift comparison"
fi

update_needed=false
reason="already up to date"

if [[ "$newest_key" > "$current_key" ]]; then
  update_needed=true
  reason="upstream ${latest_tag} is newer than packaged ${repo_pkgver}"
elif [ "$latest_tag" != "v${repo_tag}" ] && [ "$pkgver_new" = "$repo_pkgver" ]; then
  # Same version, re-tagged or re-uploaded: rebuild so the checksum matches.
  update_needed=true
  reason="upstream ${latest_tag} republished the payload for ${repo_pkgver}"
elif [ "$recipe_drift" = true ]; then
  update_needed=true
  reason="PKGBUILD differs from the AUR copy at ${repo_pkgver} (recipe-only change)"
elif [[ "$newest_key" < "$current_key" ]]; then
  reason="packaged ${repo_pkgver} is ahead of upstream ${latest_tag}"
fi

log "upstream newest : ${latest_tag} (prerelease=${is_prerelease})"
log "packaged        : ${repo_pkgver} (_tag=${repo_tag:-<unset>})"
log "decision        : ${reason}"

set_output update_needed "$update_needed"
set_output tag "$latest_tag"
set_output version "$latest_version"
set_output pkgver "$pkgver_new"
set_output asset_url "$asset_url"
set_output asset_name "$asset_name"
set_output asset_digest "$asset_digest"
set_output is_prerelease "$is_prerelease"
set_output repo_pkgver "$repo_pkgver"
set_output reason "$reason"

summary "### limusic-bin-prerelease update check"
summary ""
summary "| item | value |"
summary "| --- | --- |"
summary "| upstream newest | \`${latest_tag}\` |"
summary "| upstream is prerelease | ${is_prerelease} |"
summary "| packaged | \`${repo_pkgver}\` |"
summary "| decision | ${update_needed} — ${reason} |"
