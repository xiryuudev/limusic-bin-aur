#!/usr/bin/env bash
# Commit the freshly rendered PKGBUILD/.SRCINFO back to this GitHub repository
# so the repo always mirrors what is live on the AUR.
#
# Runs only after publish.sh confirmed the AUR push. Touches nothing except the
# two AUR payload files: `.github/` and `scripts/` are never staged, so a state
# commit cannot clobber the workflow.
#
# The push always targets the repository's default branch. Using
# GITHUB_REF_NAME would send the state commit to whatever branch a manual
# dispatch was started from, leaving `main` stale — and a stale `main` makes
# check-update.sh see an update on every single run.
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
mkdir -p "${WORKDIR:-/tmp}"

git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

git add -- PKGBUILD .SRCINFO

if git diff --cached --quiet; then
  log "repo already carries ${version} — no state commit needed"
  set_output state_committed false
  exit 0
fi

if [ -n "$aur_commit" ]; then
  msg="chore: sync PKGBUILD ${version} (AUR ${aur_commit:0:8})"
else
  msg="chore: sync PKGBUILD ${version}"
fi

git commit --quiet -m "$msg"
log "committed locally: ${msg}"

if [ "${DRY_RUN:-false}" = true ]; then
  log "DRY_RUN=true — state commit not pushed"
  set_output state_committed false
  exit 0
fi

# Another run (or the monthly keepalive) may have moved the branch since the
# checkout; rebase before pushing so a harmless race does not look like a failure.
git fetch --quiet origin "$target_branch" 2>/dev/null || true
if git rev-parse --verify --quiet "origin/${target_branch}" >/dev/null; then
  if ! git rebase --quiet "origin/${target_branch}" 2>"${WORKDIR:-/tmp}/state-rebase.err"; then
    git rebase --abort >/dev/null 2>&1 || true
    warn "could not rebase onto origin/${target_branch}: $(cat "${WORKDIR:-/tmp}/state-rebase.err" 2>/dev/null)"
    summary "### state commit: ⚠️ rebase failed; PKGBUILD mirrors the AUR but the repo is behind"
    set_output state_committed false
    exit 0
  fi
fi

if git push --quiet origin "HEAD:${target_branch}" 2>"${WORKDIR:-/tmp}/state-push.err"; then
  log "state commit pushed to ${target_branch}"
  set_output state_committed true
  summary "### state commit: pushed to \`${target_branch}\`"
else
  # The AUR publish already succeeded; a failed mirror commit must not fail the
  # run. The next update run re-runs this step and repairs the repo.
  warn "could not push the state commit: $(cat "${WORKDIR:-/tmp}/state-push.err" 2>/dev/null)"
  set_output state_committed false
  summary "### state commit: ⚠️ not pushed (see logs)"
fi
