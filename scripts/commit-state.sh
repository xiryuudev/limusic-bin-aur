#!/usr/bin/env bash
# Commit the freshly rendered PKGBUILD/.SRCINFO back to this GitHub repository
# so the repo always mirrors what is live on the AUR.
#
# Runs only after publish.sh confirmed the AUR push.
#
# Two invariants this script must never break:
#
#   1. It pushes to the repository's default branch, never to whatever branch a
#      manual `workflow_dispatch` happened to run from. A stale default branch
#      would make check-update.sh believe an update is pending on every run.
#
#   2. It can never publish `.github/` or `scripts/`. The state commit is created
#      directly on top of `origin/<default-branch>` — not on top of the checked
#      out ref — so no unrelated commit can be carried into the push. The pushed
#      range is then verified to contain only the two AUR payload files.
#
# Usage: commit-state.sh <version> [aur-commit-sha]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

version="${1:-}"
aur_commit="${2:-}"
[ -n "$version" ] || die "usage: commit-state.sh <version> [aur-commit-sha]"

[ -f PKGBUILD ] || die "PKGBUILD missing"
[ -f .SRCINFO ] || die ".SRCINFO missing"

target_branch="${TARGET_BRANCH:-main}"
workdir="${WORKDIR:-/tmp}"
mkdir -p "$workdir"

git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

if [ -n "$aur_commit" ]; then
  msg="chore: sync PKGBUILD ${version} (AUR ${aur_commit:0:8})"
else
  msg="chore: sync PKGBUILD ${version}"
fi

# ---------------------------------------------------------------------------
# 1. Park the rendered payload, then move to the target branch.
#    The payload files are uncommitted working-tree edits at this point, so they
#    are copied aside before the checkout that discards local modifications.
# ---------------------------------------------------------------------------
payload_dir="${workdir}/payload"
rm -rf "$payload_dir"
mkdir -p "$payload_dir"
cp -f PKGBUILD "$payload_dir/PKGBUILD"
cp -f .SRCINFO "$payload_dir/.SRCINFO"

# Force the remote-tracking ref: `actions/checkout` uses a shallow clone and the
# ref may be missing or stale.
git fetch --quiet origin "+refs/heads/${target_branch}:refs/remotes/origin/${target_branch}" \
  2>"${workdir}/state-fetch.err" || true

if git rev-parse --verify --quiet "refs/remotes/origin/${target_branch}" >/dev/null; then
  base_ref="refs/remotes/origin/${target_branch}"
elif [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$target_branch" ]; then
  # Local rehearsal without a remote, or a brand new repository.
  base_ref="HEAD"
  warn "no origin/${target_branch} ref; basing the state commit on local HEAD"
else
  die "cannot determine a base for ${target_branch} (fetch failed: $(cat "${workdir}/state-fetch.err" 2>/dev/null))"
fi
log "base ref: ${base_ref}"

# -f discards working-tree modifications, which is safe because the payload is
# parked in ${payload_dir}. This is what keeps the commit parent at base_ref.
git checkout --quiet --force --detach "$base_ref"
git checkout --quiet --force -B "aur-state-${target_branch}"

cp -f "$payload_dir/PKGBUILD" PKGBUILD
cp -f "$payload_dir/.SRCINFO" .SRCINFO

git add -- PKGBUILD .SRCINFO

if git diff --cached --quiet; then
  log "${target_branch} already carries ${version} — no state commit needed"
  set_output state_committed false
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Commit and prove the pushed range is payload-only.
# ---------------------------------------------------------------------------
git commit --quiet -m "$msg"
log "committed: ${msg}"

if [ "${DRY_RUN:-false}" = true ]; then
  log "DRY_RUN=true — state commit not pushed"
  set_output state_committed false
  exit 0
fi

if [ "$base_ref" != "HEAD" ]; then
  non_payload="$(git diff --name-only "${base_ref}..HEAD" | grep -vE '^(PKGBUILD|\.SRCINFO)$' || true)"
  if [ -n "$non_payload" ]; then
    warn "refusing to publish non-payload paths to ${target_branch}: $(printf '%s' "$non_payload" | tr '\n' ' ')"
    summary "### state commit: ⚠️ blocked — the commit range touched files other than PKGBUILD/.SRCINFO"
    set_output state_committed false
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# 3. Push.
# ---------------------------------------------------------------------------
if git push --quiet origin "HEAD:refs/heads/${target_branch}" 2>"${workdir}/state-push.err"; then
  log "state commit pushed to ${target_branch}"
  set_output state_committed true
  summary "### state commit: pushed to \`${target_branch}\`"
else
  # The AUR publish already succeeded; a failed mirror commit must not fail the
  # run. The next update run re-runs this step and repairs the repo.
  warn "could not push the state commit: $(cat "${workdir}/state-push.err" 2>/dev/null)"
  set_output state_committed false
  summary "### state commit: ⚠️ not pushed (see logs)"
fi
