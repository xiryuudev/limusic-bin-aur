#!/usr/bin/env bash
# Detect whether upstream SimoHypers/limusic has a release newer than what the
# AUR package (and this repo) already carries.
#
# Reads:  PKGBUILD in the checkout
# Writes: GitHub Actions outputs (update_needed, version, release_tag, reason...)
# Exit:   0 always when the check itself succeeded; non-zero only on API/parse errors.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${UPSTREAM_REPO:=SimoHypers/limusic}"
: "${AUR_PKGNAME:=limusic-bin}"
: "${GITHUB_API:=https://api.github.com}"
: "${USER_AGENT:=limusic-bin-aur-automation}"
: "${WORKDIR_CHECK:=${RUNNER_TEMP:-/tmp}/limusic-check}"

require_cmd curl jq

# ---------------------------------------------------------------------------
# Current version in this repository (the mirror of the AUR PKGBUILD).
# ---------------------------------------------------------------------------
[ -f PKGBUILD ] || die "PKGBUILD not found in $(pwd)"
repo_pkgver="$(pkgbuild_var PKGBUILD pkgver)"
[ -n "$repo_pkgver" ] || die "could not read pkgver from PKGBUILD"

# ---------------------------------------------------------------------------
# Upstream: newest STABLE release (/releases/latest ignores drafts+prereleases).
#
# The unauthenticated GitHub API allows only 60 requests/hour per IP, and shared
# runner IPs often exhaust that. Authenticate when a token is present: inside
# Actions, GITHUB_TOKEN raises the limit to 1000/hour for this repository.
# ---------------------------------------------------------------------------
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

if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
  log "using an authenticated GitHub API request"
else
  warn "no GH_TOKEN/GITHUB_TOKEN set — using the 60/hour unauthenticated API limit"
fi

release_json="$(api_get "${GITHUB_API}/repos/${UPSTREAM_REPO}/releases/latest")" \
  || die "GitHub API request failed for ${UPSTREAM_REPO} (rate limit or network?)"

release_tag="$(jq -r '.tag_name // empty' <<<"$release_json")"
[ -n "$release_tag" ] || die "upstream has no stable release (tag_name missing)"

latest_version="${release_tag#v}"

# The .deb used by the PKGBUILD. Name derived from pkgver, as upstream always
# publishes limusic_<version>_amd64.deb.
deb_name="limusic_${latest_version}_amd64.deb"
deb_json="$(jq -c --arg n "$deb_name" '.assets[]? | select(.name == $n)' <<<"$release_json")"
if [ -z "$deb_json" ]; then
  die "release ${release_tag} has no asset named ${deb_name} (asset naming changed upstream?)"
fi
deb_url="$(jq -r '.browser_download_url' <<<"$deb_json")"
deb_api_digest="$(jq -r '.digest // empty' <<<"$deb_json")"

# ---------------------------------------------------------------------------
# What the AUR currently serves. A failed RPC must NOT be read as "AUR is at 0":
# that would schedule a full 45-minute rebuild every 5 minutes for the whole
# outage. Only a successful response may move this decision, so "RPC failed" and
# "package genuinely absent" are tracked separately.
# ---------------------------------------------------------------------------
aur_version=""
rpc_ok=false

aur_raw="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 30 \
  "https://aur.archlinux.org/rpc/v5/info?arg[]=${AUR_PKGNAME}" 2>/dev/null || true)"

if [ -n "$aur_raw" ] && printf '%s' "$aur_raw" | jq -e '.type == "multiinfo"' >/dev/null 2>&1; then
  rpc_ok=true
  aur_resultcount="$(printf '%s' "$aur_raw" | jq -r '.resultcount // 0')"
  if [ "$aur_resultcount" -gt 0 ]; then
    aur_full="$(printf '%s' "$aur_raw" | jq -r '.results[0].Version // empty')"
    if [ -n "$aur_full" ]; then
      aur_version="${aur_full%-*}"   # 1.3.0-1 -> 1.3.0
    fi
  fi
fi

if [ "$rpc_ok" = false ]; then
  # Without the AUR's current version there is no way to know whether work is
  # needed, so the scheduled path does nothing and the next run retries.
  #
  # The upstream facts are already resolved above (version, deb URL, digest), so
  # they are still published: a manual `force` dispatch must keep working during
  # an AUR blip, and it cannot loop because it is never triggered by the cron.
  annotate warning "AUR RPC unavailable; skipping this run (use force=true to rebuild anyway)"
  set_output update_needed false
  set_output version "$latest_version"
  set_output release_tag "$release_tag"
  set_output deb_url "$deb_url"
  set_output deb_name "$deb_name"
  set_output deb_api_digest "$deb_api_digest"
  set_output repo_pkgver "$repo_pkgver"
  set_output aur_version "unknown"
  set_output checksum_changed false
  set_output reason "AUR RPC unavailable (transient); run skipped"
  summary "### limusic-bin update check"
  summary ""
  summary "AUR RPC did not answer, so the AUR state is unknown — no work scheduled."
  summary "Upstream latest is \`${latest_version}\`; the next scheduled run will retry."
  summary "To rebuild anyway: \`gh workflow run update.yml -f force=true\`"
  exit 0
fi

if [ -z "$aur_full" ]; then
  # RPC answered and the package is not on the AUR yet: a publish is wanted.
  log "AUR reports no such package — treating as not yet published"
  aur_version="0"
  aur_pkgrel=""
else
  aur_pkgrel="${aur_full#*-}"   # 1.3.0-2 -> 2
fi

# ---------------------------------------------------------------------------
# Decide. vercmp comes from pacman; absent locally we fall back to sort -V.
# ---------------------------------------------------------------------------
vcmp() {
  if command -v vercmp >/dev/null 2>&1; then
    local r
    r="$(vercmp "$1" "$2")"
    if [ "$r" -lt 0 ]; then echo -1; elif [ "$r" -gt 0 ]; then echo 1; else echo 0; fi
  else
    local hi lo
    hi="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)"
    lo="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
    if [ "$hi" = "$lo" ]; then echo 0; elif [ "$hi" = "$1" ]; then echo 1; else echo -1; fi
  fi
}

vs_repo="$(vcmp "$latest_version" "$repo_pkgver")"
vs_aur="$(vcmp "$latest_version" "$aur_version")"

# Upstream has re-uploaded assets for an existing tag before (a fixed checksum
# without a version bump). If the release still advertises our version, compare
# the API digest against the checksum we already publish and refresh if it moved.
repo_sha="$(pkgbuild_var PKGBUILD sha256sums)"
api_sha="${deb_api_digest#sha256:}"
checksum_changed=false
if [ "$vs_repo" -eq 0 ] && [ -n "$repo_sha" ] && [ -n "$api_sha" ] && [ "$repo_sha" != "$api_sha" ]; then
  checksum_changed=true
fi

# ---------------------------------------------------------------------------
# Recipe drift: the repo's PKGBUILD can be correct while the AUR's copy is stale
# at the same pkgver — a dependency or install-script fix does not change
# upstream's version. Without this check such a fix would never be published.
#
# The AUR's git repository is authoritative and reflects a push immediately. Its
# cgit plain-text view is deliberately NOT used: it lags the git repo by
# minutes, which produced a false "drift" after every publish and therefore a
# full rebuild on every scheduled run.
# ---------------------------------------------------------------------------
aur_git_pkgbuild() {
  # Shallow fetch of just the PKGBUILD. Falls back to the cgit view (last
  # resort) when git is not available on the check runner.
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
local_rel="$(pkgbuild_var PKGBUILD pkgrel)"
if [ -n "${WORKDIR_CHECK:-}" ]; then
  mkdir -p "$WORKDIR_CHECK"
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
  elif [ -n "$aur_pkgrel" ] && [ -n "$local_rel" ] && [ "$aur_pkgrel" != "$local_rel" ]; then
    # Git copy unavailable but the RPC already tells us the published pkgrel
    # differs, which can only mean our recipe has not been pushed yet.
    recipe_drift=true
    log "AUR pkgrel ${aur_pkgrel} differs from local pkgrel ${local_rel}"
  else
    log "AUR git copy unavailable; skipping the recipe-drift comparison"
  fi
fi

update_needed=false
reason="already up to date"

if [ "$vs_repo" -gt 0 ]; then
  update_needed=true
  reason="upstream ${latest_version} is newer than repo pkgver ${repo_pkgver}"
elif [ "$checksum_changed" = true ]; then
  update_needed=true
  reason="upstream re-uploaded ${latest_version}: checksum ${repo_sha:0:16}… -> ${api_sha:0:16}…"
elif [ "$recipe_drift" = true ]; then
  # Same version upstream and here, but the AUR copy of the recipe is stale:
  # a dependency or script fix has to be published without a version bump.
  update_needed=true
  reason="repo PKGBUILD differs from the AUR copy at ${latest_version}"
elif [ "$vs_aur" -gt 0 ]; then
  # Repo is current but the AUR is behind: re-publish without re-rendering.
  update_needed=true
  reason="repo is current (${repo_pkgver}) but AUR is behind (${aur_version})"
elif [ "$vs_repo" -lt 0 ]; then
  reason="repo pkgver ${repo_pkgver} is ahead of upstream ${latest_version}"
fi

log "upstream : ${latest_version} (${release_tag})"
log "repo     : ${repo_pkgver}"
log "aur      : ${aur_version}"
log "decision : ${reason}"

set_output update_needed "$update_needed"
set_output version "$latest_version"
set_output release_tag "$release_tag"
set_output deb_url "$deb_url"
set_output deb_name "$deb_name"
set_output deb_api_digest "$deb_api_digest"
set_output repo_pkgver "$repo_pkgver"
set_output aur_version "$aur_version"
set_output checksum_changed "$checksum_changed"
set_output reason "$reason"

summary "### limusic-bin update check"
summary ""
summary "| item | value |"
summary "| --- | --- |"
summary "| upstream latest (stable) | \`${latest_version}\` |"
summary "| repo PKGBUILD | \`${repo_pkgver}\` |"
summary "| AUR | \`${aur_version}\` |"
summary "| checksum changed upstream | ${checksum_changed} |"
summary "| decision | ${update_needed} — ${reason} |"
